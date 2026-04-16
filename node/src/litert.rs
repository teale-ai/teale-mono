//! LiteRT-LM inference backend via subprocess.
//!
//! Spawns `litert_lm_main` as a subprocess and communicates via stdin/stdout.
//! Each inference request creates a fresh process to avoid session state issues.
//! This keeps teale-node as a single thin binary while leveraging Google's
//! on-device runtime with GPU/NPU acceleration for Tensor chips.

use std::process::Stdio;

use serde_json::Value;
use tokio::io::{AsyncBufReadExt, BufReader};
use tokio::process::Command;
use tokio::sync::mpsc;
use tracing::info;

use crate::cluster::{ApiMessage, ChatCompletionRequest};
use crate::config::LiteRtConfig;

/// LiteRT-LM engine that spawns litert_lm_main for each inference request.
pub struct LiteRtEngine {
    binary: String,
    model: String,
    model_id: String,
    backend_type: String,
    context_size: u32,
    cache_dir: Option<String>,
}

impl LiteRtEngine {
    pub fn new(config: &LiteRtConfig) -> anyhow::Result<Self> {
        let binary = config
            .binary
            .clone()
            .unwrap_or_else(|| "litert_lm_main".to_string());

        // Verify the binary exists
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
    pub async fn stream_completion(
        &self,
        request: &ChatCompletionRequest,
    ) -> anyhow::Result<mpsc::UnboundedReceiver<Value>> {
        let prompt = format_chat_prompt(&request.messages);
        let max_tokens = request.max_tokens.unwrap_or(self.context_size);

        let mut cmd = Command::new(&self.binary);
        cmd.arg("--model_path").arg(&self.model)
            .arg("--backend").arg(&self.backend_type)
            .arg("--max_tokens").arg(max_tokens.to_string())
            .arg("--prompt").arg(&prompt);

        if let Some(ref cache_dir) = self.cache_dir {
            cmd.arg("--cache_dir").arg(cache_dir);
        }

        cmd.stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .stdin(Stdio::null());

        let mut child = cmd.spawn().map_err(|e| {
            anyhow::anyhow!("Failed to spawn litert_lm_main at '{}': {}", self.binary, e)
        })?;

        let (tx, rx) = mpsc::unbounded_channel();
        let model_id = self.model_id.clone();

        // Log stderr in background
        if let Some(stderr) = child.stderr.take() {
            tokio::spawn(async move {
                let reader = BufReader::new(stderr);
                let mut lines = reader.lines();
                while let Ok(Some(line)) = lines.next_line().await {
                    info!("[litert_lm] {}", line);
                }
            });
        }

        // Stream stdout as token chunks
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
                            "delta": {
                                "content": text
                            },
                            "finish_reason": null
                        }]
                    });

                    chunk_idx += 1;
                    if tx.send(chunk_json).is_err() {
                        break;
                    }
                }

                // Send final chunk with finish_reason
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
                let _ = tx.send(final_json);

                // Wait for process to finish
                let _ = child.wait().await;
            });
        }

        Ok(rx)
    }
}

/// Format chat messages into a prompt for Gemma models.
fn format_chat_prompt(messages: &[ApiMessage]) -> String {
    let mut prompt = String::new();
    for msg in messages {
        match msg.role.as_str() {
            "system" => {
                prompt.push_str(&format!(
                    "<start_of_turn>system\n{}<end_of_turn>\n",
                    msg.content
                ));
            }
            "user" => {
                prompt.push_str(&format!(
                    "<start_of_turn>user\n{}<end_of_turn>\n",
                    msg.content
                ));
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
    prompt.push_str("<start_of_turn>model\n");
    prompt
}
