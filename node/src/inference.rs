//! HTTP-proxy backend for llama-server / mnn-llm subprocesses.
//!
//! Concurrency: the backend itself is thread-safe; per-node concurrency is
//! gated by `NodeRuntimeState.semaphore` in cluster.rs.
//!
//! Channels use a bounded mpsc so that a slow relay path back-pressures the
//! SSE-reader task instead of growing unboundedly.

use serde_json::Value;
use std::process::Stdio;
use tokio::io::{AsyncBufReadExt, BufReader};
use tokio::process::{Child, Command};
use tokio::sync::mpsc;
use tracing::{debug, error, info};

use teale_protocol::openai::ChatCompletionRequest;

use crate::config::{LlamaConfig, MnnConfig};

/// Bounded channel capacity for streaming chunks back to the dispatcher.
/// Chosen so a 2048-token response can buffer without blocking, but fast
/// enough that a stalled consumer observable backpressure within ~100ms.
pub const CHUNK_CHANNEL_CAPACITY: usize = 64;

fn is_mobile_environment() -> bool {
    cfg!(target_os = "android")
        || std::env::var("ANDROID_ROOT").is_ok()
        || std::path::Path::new("/system/build.prop").exists()
}

/// HTTP proxy to llama-server / mnn-llm subprocess running on localhost.
#[derive(Clone)]
pub struct InferenceProxy {
    base_url: String,
    model_id: String,
    client: reqwest::Client,
}

impl InferenceProxy {
    pub fn new(port: u16, model_id: &str) -> Self {
        Self {
            base_url: format!("http://127.0.0.1:{}", port),
            model_id: model_id.to_string(),
            client: reqwest::Client::builder()
                .timeout(std::time::Duration::from_secs(300))
                .build()
                .expect("reqwest client build failed"),
        }
    }

    pub fn loaded_models(&self) -> Vec<String> {
        vec![self.model_id.clone()]
    }

    /// Wait for backend to become healthy (up to timeout_secs).
    pub async fn wait_for_health(&self, timeout_secs: u64) -> anyhow::Result<()> {
        let health_url = format!("{}/health", self.base_url);
        let deadline = tokio::time::Instant::now() + tokio::time::Duration::from_secs(timeout_secs);

        loop {
            if tokio::time::Instant::now() > deadline {
                anyhow::bail!("backend health check timed out after {}s", timeout_secs);
            }
            match self.client.get(&health_url).send().await {
                Ok(resp) if resp.status().is_success() => {
                    info!("backend is healthy at {}", self.base_url);
                    return Ok(());
                }
                _ => {
                    tokio::time::sleep(tokio::time::Duration::from_secs(2)).await;
                }
            }
        }
    }

    /// Stream a chat completion. Returns a **bounded** receiver — back-pressure
    /// propagates to the SSE reader task when the consumer is slow.
    pub async fn stream_completion(
        &self,
        request: &ChatCompletionRequest,
    ) -> anyhow::Result<mpsc::Receiver<Value>> {
        let url = format!("{}/v1/chat/completions", self.base_url);

        let mut body = serde_json::to_value(request)?;
        body["stream"] = Value::Bool(true);

        let response = self
            .client
            .post(&url)
            .json(&body)
            .send()
            .await
            .map_err(|e| anyhow::anyhow!("backend request failed: {}", e))?;

        if !response.status().is_success() {
            let status = response.status();
            let text = response.text().await.unwrap_or_default();
            anyhow::bail!("backend returned {}: {}", status, text);
        }

        let (tx, rx) = mpsc::channel::<Value>(CHUNK_CHANNEL_CAPACITY);

        tokio::spawn(async move {
            let mut stream = response.bytes_stream();
            let mut buffer = String::new();

            use futures_util::StreamExt;
            while let Some(chunk) = stream.next().await {
                match chunk {
                    Ok(bytes) => {
                        buffer.push_str(&String::from_utf8_lossy(&bytes));

                        while let Some(line_end) = buffer.find('\n') {
                            let line = buffer[..line_end].trim().to_string();
                            buffer = buffer[line_end + 1..].to_string();

                            if let Some(data) = line.strip_prefix("data: ") {
                                if data == "[DONE]" {
                                    return;
                                }
                                if let Ok(parsed) = serde_json::from_str::<Value>(data) {
                                    // `.send().await` is the backpressure point:
                                    // if the relay consumer is slow, we stall here
                                    // instead of growing an unbounded buffer.
                                    if tx.send(parsed).await.is_err() {
                                        debug!("chunk receiver dropped — stopping SSE reader");
                                        return;
                                    }
                                }
                            }
                        }
                    }
                    Err(e) => {
                        error!("SSE stream error: {}", e);
                        break;
                    }
                }
            }
        });

        Ok(rx)
    }
}

/// Build the `Command` for llama-server (does not spawn).
pub fn build_llama_command(config: &LlamaConfig) -> anyhow::Result<Command> {
    if config.context_size > 4096 && is_mobile_environment() {
        tracing::warn!(
            "Context size {} may cause memory pressure on mobile. Consider 2048-4096 for Android devices.",
            config.context_size
        );
    }

    let mut cmd = Command::new(&config.binary);
    cmd.arg("--model")
        .arg(&config.model)
        .arg("--port")
        .arg(config.port.to_string())
        .arg("--n-gpu-layers")
        .arg(config.gpu_layers.to_string())
        .arg("--ctx-size")
        .arg(config.context_size.to_string())
        .arg("--host")
        .arg("127.0.0.1");

    for arg in &config.extra_args {
        cmd.arg(arg);
    }

    cmd.stdout(Stdio::piped()).stderr(Stdio::piped());
    Ok(cmd)
}

/// Spawn llama-server once; intended for direct use (tests). Prefer
/// `Supervisor::spawn` in production for restart-on-crash.
pub fn spawn_llama_server(config: &LlamaConfig) -> anyhow::Result<Child> {
    info!(
        "Starting llama-server: binary={}, model={}, port={}, gpu_layers={}",
        config.binary, config.model, config.port, config.gpu_layers
    );
    let mut cmd = build_llama_command(config)?;
    let mut child = cmd.spawn().map_err(|e| {
        anyhow::anyhow!("Failed to spawn llama-server at '{}': {}", config.binary, e)
    })?;

    if let Some(stderr) = child.stderr.take() {
        tokio::spawn(async move {
            let reader = BufReader::new(stderr);
            let mut lines = reader.lines();
            while let Ok(Some(line)) = lines.next_line().await {
                info!("[llama-server] {}", line);
            }
        });
    }

    Ok(child)
}

pub fn build_mnn_command(config: &MnnConfig) -> anyhow::Result<Command> {
    if config.context_size > 4096 && is_mobile_environment() {
        tracing::warn!(
            "Context size {} may cause memory pressure on mobile. Consider 1024-2048 for MNN on Android devices.",
            config.context_size
        );
    }

    let mut cmd = Command::new(&config.binary);
    cmd.arg("--model_dir")
        .arg(&config.model_dir)
        .arg("--port")
        .arg(config.port.to_string())
        .arg("--max_length")
        .arg(config.context_size.to_string());

    if let Some(ref backend_type) = config.backend_type {
        cmd.arg("--backend_type").arg(backend_type);
    }

    for arg in &config.extra_args {
        cmd.arg(arg);
    }

    cmd.stdout(Stdio::piped()).stderr(Stdio::piped());
    Ok(cmd)
}

pub fn spawn_mnn_server(config: &MnnConfig) -> anyhow::Result<Child> {
    info!(
        "Starting mnn_llm: binary={}, model_dir={}, port={}",
        config.binary, config.model_dir, config.port
    );
    let mut cmd = build_mnn_command(config)?;
    let mut child = cmd
        .spawn()
        .map_err(|e| anyhow::anyhow!("Failed to spawn mnn_llm at '{}': {}", config.binary, e))?;

    if let Some(stderr) = child.stderr.take() {
        tokio::spawn(async move {
            let reader = BufReader::new(stderr);
            let mut lines = reader.lines();
            while let Ok(Some(line)) = lines.next_line().await {
                info!("[mnn_llm] {}", line);
            }
        });
    }

    Ok(child)
}
