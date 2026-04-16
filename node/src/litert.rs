//! LiteRT-LM in-process inference backend via FFI.
//!
//! This module provides direct integration with Google's LiteRT-LM runtime
//! for on-device inference, optimized for Tensor chips (Pixel devices).
//! It calls the C API from `c/engine.h` via FFI — no subprocess needed.

#![cfg(feature = "litert")]

use std::ffi::{CStr, CString};
use std::os::raw::{c_char, c_int, c_void};
use std::sync::Arc;

use serde_json::Value;
use tokio::sync::mpsc;
use tracing::{error, info};

use crate::cluster::ChatCompletionRequest;
use crate::config::LiteRtConfig;

// ---------------------------------------------------------------------------
// FFI declarations from c/engine.h
// ---------------------------------------------------------------------------

#[repr(C)]
struct LiteRtLmEngine {
    _opaque: [u8; 0],
}
#[repr(C)]
struct LiteRtLmSession {
    _opaque: [u8; 0],
}
#[repr(C)]
struct LiteRtLmEngineSettings {
    _opaque: [u8; 0],
}
#[repr(C)]
struct LiteRtLmSessionConfig {
    _opaque: [u8; 0],
}

#[repr(C)]
#[allow(dead_code)]
enum InputDataType {
    Text = 0,
    Image = 1,
    ImageEnd = 2,
    Audio = 3,
    AudioEnd = 4,
}

#[repr(C)]
struct InputData {
    data_type: InputDataType,
    data: *const c_void,
    size: usize,
}

type StreamCallback =
    extern "C" fn(callback_data: *mut c_void, chunk: *const c_char, is_final: bool, error_msg: *const c_char);

extern "C" {
    fn litert_lm_engine_settings_create(
        model_path: *const c_char,
        backend_str: *const c_char,
        vision_backend_str: *const c_char,
        audio_backend_str: *const c_char,
    ) -> *mut LiteRtLmEngineSettings;

    fn litert_lm_engine_settings_set_max_num_tokens(
        settings: *mut LiteRtLmEngineSettings,
        max_num_tokens: c_int,
    );

    fn litert_lm_engine_settings_set_cache_dir(
        settings: *mut LiteRtLmEngineSettings,
        cache_dir: *const c_char,
    );

    fn litert_lm_engine_settings_delete(settings: *mut LiteRtLmEngineSettings);

    fn litert_lm_engine_create(settings: *const LiteRtLmEngineSettings) -> *mut LiteRtLmEngine;
    fn litert_lm_engine_delete(engine: *mut LiteRtLmEngine);

    fn litert_lm_engine_create_session(
        engine: *mut LiteRtLmEngine,
        config: *const LiteRtLmSessionConfig,
    ) -> *mut LiteRtLmSession;

    fn litert_lm_session_delete(session: *mut LiteRtLmSession);

    fn litert_lm_session_config_create() -> *mut LiteRtLmSessionConfig;
    fn litert_lm_session_config_set_max_output_tokens(
        config: *mut LiteRtLmSessionConfig,
        max_output_tokens: c_int,
    );
    fn litert_lm_session_config_delete(config: *mut LiteRtLmSessionConfig);

    fn litert_lm_session_generate_content_stream(
        session: *mut LiteRtLmSession,
        inputs: *const InputData,
        num_inputs: usize,
        callback: StreamCallback,
        callback_data: *mut c_void,
    ) -> c_int;

    fn litert_lm_set_min_log_level(level: c_int);
}

// ---------------------------------------------------------------------------
// Safe Rust wrapper
// ---------------------------------------------------------------------------

/// Thread-safe handle to a loaded LiteRT-LM engine.
/// Engine is Send + Sync per the C API docs. Sessions are created per-request.
pub struct LiteRtEngine {
    engine: *mut LiteRtLmEngine,
    model_id: String,
    max_tokens: i32,
}

// Safety: LiteRtLmEngine is documented as thread-safe.
unsafe impl Send for LiteRtEngine {}
unsafe impl Sync for LiteRtEngine {}

impl LiteRtEngine {
    /// Load a LiteRT-LM model and create an engine.
    pub fn new(config: &LiteRtConfig) -> anyhow::Result<Self> {
        let model_path = CString::new(config.model.as_str())?;
        let backend = CString::new(
            config.backend_type.as_deref().unwrap_or("cpu"),
        )?;

        info!(
            "Loading LiteRT-LM model: {}, backend: {}",
            config.model,
            config.backend_type.as_deref().unwrap_or("cpu")
        );

        // Suppress verbose LiteRT logs (WARNING and above only)
        unsafe { litert_lm_set_min_log_level(1) };

        let settings = unsafe {
            litert_lm_engine_settings_create(
                model_path.as_ptr(),
                backend.as_ptr(),
                std::ptr::null(),
                std::ptr::null(),
            )
        };
        if settings.is_null() {
            anyhow::bail!("Failed to create LiteRT-LM engine settings");
        }

        unsafe {
            litert_lm_engine_settings_set_max_num_tokens(settings, config.context_size as c_int);
        }

        if let Some(ref cache_dir) = config.cache_dir {
            let dir = CString::new(cache_dir.as_str())?;
            unsafe { litert_lm_engine_settings_set_cache_dir(settings, dir.as_ptr()) };
        }

        let engine = unsafe { litert_lm_engine_create(settings) };
        unsafe { litert_lm_engine_settings_delete(settings) };

        if engine.is_null() {
            anyhow::bail!(
                "Failed to create LiteRT-LM engine from model '{}'",
                config.model
            );
        }

        let model_id = config.model_id.clone().unwrap_or_else(|| {
            std::path::Path::new(&config.model)
                .file_stem()
                .map(|s| s.to_string_lossy().to_string())
                .unwrap_or_else(|| config.model.clone())
        });

        info!("LiteRT-LM engine loaded: {}", model_id);

        Ok(Self {
            engine,
            model_id,
            max_tokens: config.context_size as i32,
        })
    }

    pub fn loaded_models(&self) -> Vec<String> {
        vec![self.model_id.clone()]
    }

    /// Stream a chat completion by calling the C API's streaming function.
    /// Returns a channel of OpenAI-format chunk JSONs.
    pub async fn stream_completion(
        &self,
        request: &ChatCompletionRequest,
    ) -> anyhow::Result<mpsc::UnboundedReceiver<Value>> {
        // Format messages into a single prompt string
        let prompt = format_chat_prompt(&request.messages);
        let prompt_c = CString::new(prompt.as_str())?;

        let max_output = request.max_tokens.unwrap_or(self.max_tokens as u64) as c_int;

        // Create session config with max output tokens
        let session_config = unsafe { litert_lm_session_config_create() };
        if !session_config.is_null() {
            unsafe {
                litert_lm_session_config_set_max_output_tokens(session_config, max_output);
            }
        }

        // Create a session for this request
        let session = unsafe {
            litert_lm_engine_create_session(
                self.engine,
                if session_config.is_null() {
                    std::ptr::null()
                } else {
                    session_config as *const _
                },
            )
        };

        if !session_config.is_null() {
            unsafe { litert_lm_session_config_delete(session_config) };
        }

        if session.is_null() {
            anyhow::bail!("Failed to create LiteRT-LM session");
        }

        let (tx, rx) = mpsc::unbounded_channel();
        let request_model = request.model.clone().unwrap_or_else(|| self.model_id.clone());

        // Spawn blocking work on a dedicated thread (FFI callback comes from C++ thread)
        let session_ptr = session as usize; // Send as usize to cross thread boundary
        let prompt_bytes = prompt_c.into_bytes_with_nul();

        tokio::task::spawn_blocking(move || {
            let session = session_ptr as *mut LiteRtLmSession;

            // Build input
            let input = InputData {
                data_type: InputDataType::Text,
                data: prompt_bytes.as_ptr() as *const c_void,
                size: prompt_bytes.len() - 1, // exclude null terminator
            };

            // Build callback state
            let state = Box::new(CallbackState {
                tx,
                model: request_model,
                chunk_index: std::sync::atomic::AtomicU32::new(0),
            });
            let state_ptr = Box::into_raw(state) as *mut c_void;

            let rc = unsafe {
                litert_lm_session_generate_content_stream(
                    session,
                    &input,
                    1,
                    stream_callback,
                    state_ptr,
                )
            };

            if rc != 0 {
                // Clean up state on failure
                let state = unsafe { Box::from_raw(state_ptr as *mut CallbackState) };
                let _ = state.tx; // dropped
                error!("litert_lm_session_generate_content_stream failed with code {}", rc);
            }
            // Note: state is cleaned up by the callback when is_final=true

            // Clean up session
            unsafe { litert_lm_session_delete(session) };
        });

        Ok(rx)
    }
}

impl Drop for LiteRtEngine {
    fn drop(&mut self) {
        if !self.engine.is_null() {
            unsafe { litert_lm_engine_delete(self.engine) };
        }
    }
}

// ---------------------------------------------------------------------------
// Streaming callback bridge
// ---------------------------------------------------------------------------

struct CallbackState {
    tx: mpsc::UnboundedSender<Value>,
    model: String,
    chunk_index: std::sync::atomic::AtomicU32,
}

/// C callback invoked by LiteRT-LM from a background thread for each token chunk.
extern "C" fn stream_callback(
    callback_data: *mut c_void,
    chunk: *const c_char,
    is_final: bool,
    error_msg: *const c_char,
) {
    let state = unsafe { &*(callback_data as *const CallbackState) };

    // Handle errors
    if !error_msg.is_null() {
        let msg = unsafe { CStr::from_ptr(error_msg) }
            .to_string_lossy()
            .to_string();
        error!("LiteRT-LM stream error: {}", msg);
        // Clean up — take ownership and drop
        let _ = unsafe { Box::from_raw(callback_data as *mut CallbackState) };
        return;
    }

    // Send chunk as OpenAI-format JSON
    if !chunk.is_null() {
        let text = unsafe { CStr::from_ptr(chunk) }
            .to_string_lossy()
            .to_string();

        if !text.is_empty() {
            let idx = state
                .chunk_index
                .fetch_add(1, std::sync::atomic::Ordering::Relaxed);

            let chunk_json = serde_json::json!({
                "id": format!("chatcmpl-litert-{}", idx),
                "object": "chat.completion.chunk",
                "model": state.model,
                "choices": [{
                    "index": 0,
                    "delta": {
                        "content": text
                    },
                    "finish_reason": null
                }]
            });

            let _ = state.tx.send(chunk_json);
        }
    }

    // Final chunk — send finish_reason and clean up
    if is_final {
        let idx = state
            .chunk_index
            .fetch_add(1, std::sync::atomic::Ordering::Relaxed);

        let final_json = serde_json::json!({
            "id": format!("chatcmpl-litert-{}", idx),
            "object": "chat.completion.chunk",
            "model": state.model,
            "choices": [{
                "index": 0,
                "delta": {},
                "finish_reason": "stop"
            }]
        });

        let _ = state.tx.send(final_json);

        // Take ownership back and drop (cleans up the sender)
        let _ = unsafe { Box::from_raw(callback_data as *mut CallbackState) };
    }
}

// ---------------------------------------------------------------------------
// Prompt formatting
// ---------------------------------------------------------------------------

use crate::cluster::ApiMessage;

/// Format chat messages into a single prompt string.
/// Uses a simple ChatML-like format that works with most instruction-tuned models.
fn format_chat_prompt(messages: &[ApiMessage]) -> String {
    let mut prompt = String::new();
    for msg in messages {
        match msg.role.as_str() {
            "system" => {
                prompt.push_str(&format!("<start_of_turn>system\n{}<end_of_turn>\n", msg.content));
            }
            "user" => {
                prompt.push_str(&format!("<start_of_turn>user\n{}<end_of_turn>\n", msg.content));
            }
            "assistant" => {
                prompt.push_str(&format!(
                    "<start_of_turn>model\n{}<end_of_turn>\n",
                    msg.content
                ));
            }
            _ => {
                prompt.push_str(&format!(
                    "<start_of_turn>{}\n{}<end_of_turn>\n",
                    msg.role, msg.content
                ));
            }
        }
    }
    // Signal the model to generate
    prompt.push_str("<start_of_turn>model\n");
    prompt
}
