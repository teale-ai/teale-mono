//! LiteRT-LM inference backend via subprocess.
//!
//! Spawns `litert_lm_main` as a subprocess per request. Keeps teale-node as a
//! single thin binary while leveraging Google's on-device runtime with GPU/NPU
//! acceleration for Tensor chips.

use std::process::Stdio;

use serde_json::Value;
use tokio::io::{AsyncBufReadExt, BufReader};
use tokio::process::Command;
use tokio::sync::mpsc;
use tracing::info;

use teale_protocol::openai::{ApiMessage, ChatCompletionRequest};

use crate::config::LiteRtConfig;
use crate::inference::CHUNK_CHANNEL_CAPACITY;

pub struct LiteRtEngine {
    binary: String,
    model: String,
    model_id: String,
    backend_type: String,
    #[allow(dead_code)]
    context_size: u32,
    #[allow(dead_code)]
    cache_dir: Option<String>,
}

impl LiteRtEngine {
    pub fn new(config: &LiteRtConfig) -> anyhow::Result<Self> {
        let binary = config.binary.clone().unwrap_or_else(|| "litert_lm_main".to_string());

        if !std::path::Path::new(&binary).exists() && which::which(&binary).is_err() {
            anyhow::bail!(
                "litert_lm_main not found at '{}'. Build from LiteRT-LM repo or download.",
                binary
            );
        }

        let model_id = config.model_id.clone().unwrap_or_else(|| {
            std::path::Path::new(&config.model)
                .file_stem()
                .map(|s| s.to_string_lossy().to_string())
                .unwrap_or_else(|| config.model.clone())
        });

        info!(
            "LiteRT-LM configured: binary={}, model={}, backend={}",
            binary,
            config.model,
            config.backend_type.as_deref().unwrap_or("cpu")
        );

        Ok(Self {
            binary,
            model: config.model.clone(),
            model_id,
            backend_type: config.backend_type.clone().unwrap_or_else(|| "cpu".to_string()),
            context_size: config.context_size,
            cache_dir: config.cache_dir.clone(),
        })
    }

    pub fn loaded_models(&self) -> Vec<String> {
        vec![self.model_id.clone()]
    }

    /// Stream a chat completion by spawning litert_lm_main and reading its output.
    /// Returns a bounded receiver — the per-request subprocess blocks on the
    /// channel, which provides natural backpressure if the relay stalls.
    pub async fn stream_completion(
        &self,
        request: &ChatCompletionRequest,
    ) -> anyhow::Result<mpsc::Receiver<Value>> {
        let prompt = format_chat_prompt(&request.messages);

        let mut cmd = Command::new(&self.binary);
        cmd.arg("--model_path")
            .arg(&self.model)
            .arg("--backend")
            .arg(&self.backend_type)
            .arg("--input_prompt")
            .arg(&prompt);

        let binary_dir = std::path::Path::new(&self.binary)
            .parent()
            .map(|p| p.to_string_lossy().to_string())
            .unwrap_or_default();
        let lib_path = format!("{}/lib:{}", binary_dir, binary_dir);
        cmd.env("LD_LIBRARY_PATH", &lib_path);

        cmd.stdout(Stdio::piped()).stderr(Stdio::piped()).stdin(Stdio::null());

        let mut child = cmd.spawn().map_err(|e| {
            anyhow::anyhow!("Failed to spawn litert_lm_main at '{}': {}", self.binary, e)
        })?;

        let (tx, rx) = mpsc::channel::<Value>(CHUNK_CHANNEL_CAPACITY);
        let model_id = self.model_id.clone();

        if let Some(stderr) = child.stderr.take() {
            tokio::spawn(async move {
                let reader = BufReader::new(stderr);
                let mut lines = reader.lines();
                while let Ok(Some(line)) = lines.next_line().await {
                    info!("[litert_lm] {}", line);
                }
            });
        }

        if let Some(stdout) = child.stdout.take() {
            tokio::spawn(async move {
                let reader = BufReader::new(stdout);
                let mut lines = reader.lines();
                let mut chunk_idx: u32 = 0;

                while let Ok(Some(line)) = lines.next_line().await {
                    let text = line.trim().to_string();
                    if text.is_empty() {
                        continue;
                    }

                    let chunk_json = serde_json::json!({
                        "id": format!("chatcmpl-litert-{}", chunk_idx),
                        "object": "chat.completion.chunk",
                        "model": model_id,
                        "choices": [{
                            "index": 0,
                            "delta": { "content": text },
                            "finish_reason": null
                        }]
                    });

                    chunk_idx += 1;
                    if tx.send(chunk_json).await.is_err() {
                        break;
                    }
                }

                let final_json = serde_json::json!({
                    "id": format!("chatcmpl-litert-{}", chunk_idx),
                    "object": "chat.completion.chunk",
                    "model": model_id,
                    "choices": [{
                        "index": 0,
                        "delta": {},
                        "finish_reason": "stop"
                    }]
                });
                let _ = tx.send(final_json).await;

                let _ = child.wait().await;
            });
        }

        Ok(rx)
    }
}

fn format_chat_prompt(messages: &[ApiMessage]) -> String {
    let mut prompt = String::new();
    for msg in messages {
        let text = extract_text_content(&msg.content);
        match msg.role.as_str() {
            "system" => prompt.push_str(&format!("<start_of_turn>system\n{}<end_of_turn>\n", text)),
            "user" => prompt.push_str(&format!("<start_of_turn>user\n{}<end_of_turn>\n", text)),
            "assistant" => prompt.push_str(&format!("<start_of_turn>model\n{}<end_of_turn>\n", text)),
            other => prompt.push_str(&format!("<start_of_turn>{}\n{}<end_of_turn>\n", other, text)),
        }
    }
    prompt.push_str("<start_of_turn>model\n");
    prompt
}

/// Flatten an OpenAI `content` value (string or array of parts) into plain text.
/// For multimodal parts with `type: "text"` we concatenate the text fields.
/// Non-text parts (image_url, etc.) are ignored in this text-only path.
fn extract_text_content(content: &Value) -> String {
    match content {
        Value::String(s) => s.clone(),
        Value::Array(parts) => parts
            .iter()
            .filter_map(|p| {
                let obj = p.as_object()?;
                if obj.get("type").and_then(|v| v.as_str()) == Some("text") {
                    obj.get("text").and_then(|v| v.as_str()).map(str::to_owned)
                } else {
                    None
                }
            })
            .collect::<Vec<_>>()
            .join("\n"),
        other => other.to_string(),
    }
}
