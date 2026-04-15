use serde_json::Value;
use std::process::Stdio;
use tokio::io::{AsyncBufReadExt, BufReader};
use tokio::process::{Child, Command};
use tokio::sync::mpsc;
use tracing::{error, info};

use crate::cluster::ChatCompletionRequest;
use crate::config::LlamaConfig;

/// Manages a llama-server subprocess and proxies inference requests to it.
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
            client: reqwest::Client::new(),
        }
    }

    pub fn loaded_models(&self) -> Vec<String> {
        vec![self.model_id.clone()]
    }

    /// Wait for llama-server to become healthy (up to timeout_secs).
    pub async fn wait_for_health(&self, timeout_secs: u64) -> anyhow::Result<()> {
        let health_url = format!("{}/health", self.base_url);
        let deadline = tokio::time::Instant::now() + tokio::time::Duration::from_secs(timeout_secs);

        loop {
            if tokio::time::Instant::now() > deadline {
                anyhow::bail!("llama-server health check timed out after {}s", timeout_secs);
            }

            match self.client.get(&health_url).send().await {
                Ok(resp) if resp.status().is_success() => {
                    info!("llama-server is healthy");
                    return Ok(());
                }
                Ok(_resp) => {
                    tokio::time::sleep(tokio::time::Duration::from_secs(2)).await;
                }
                Err(_) => {
                    tokio::time::sleep(tokio::time::Duration::from_secs(2)).await;
                }
            }
        }
    }

    /// Stream a chat completion, returning a channel of SSE chunks (parsed JSON).
    pub async fn stream_completion(
        &self,
        request: &ChatCompletionRequest,
    ) -> anyhow::Result<mpsc::UnboundedReceiver<Value>> {
        let url = format!("{}/v1/chat/completions", self.base_url);

        // Build the request body for llama-server
        let mut body = serde_json::to_value(request)?;
        body["stream"] = Value::Bool(true);

        let response = self.client
            .post(&url)
            .json(&body)
            .send()
            .await
            .map_err(|e| anyhow::anyhow!("llama-server request failed: {}", e))?;

        if !response.status().is_success() {
            let status = response.status();
            let text = response.text().await.unwrap_or_default();
            anyhow::bail!("llama-server returned {}: {}", status, text);
        }

        let (tx, rx) = mpsc::unbounded_channel();

        // Stream SSE response
        tokio::spawn(async move {
            let mut stream = response.bytes_stream();
            let mut buffer = String::new();

            use futures_util::StreamExt;
            while let Some(chunk) = stream.next().await {
                match chunk {
                    Ok(bytes) => {
                        buffer.push_str(&String::from_utf8_lossy(&bytes));

                        // Process complete SSE lines
                        while let Some(line_end) = buffer.find('\n') {
                            let line = buffer[..line_end].trim().to_string();
                            buffer = buffer[line_end + 1..].to_string();

                            if line.starts_with("data: ") {
                                let data = &line[6..];
                                if data == "[DONE]" {
                                    return;
                                }
                                if let Ok(parsed) = serde_json::from_str::<Value>(data) {
                                    if tx.send(parsed).is_err() {
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

/// Spawn llama-server as a subprocess.
pub fn spawn_llama_server(config: &LlamaConfig) -> anyhow::Result<Child> {
    info!(
        "Starting llama-server: binary={}, model={}, port={}, gpu_layers={}",
        config.binary, config.model, config.port, config.gpu_layers
    );

    let mut cmd = Command::new(&config.binary);
    cmd.arg("--model").arg(&config.model)
        .arg("--port").arg(config.port.to_string())
        .arg("--n-gpu-layers").arg(config.gpu_layers.to_string())
        .arg("--ctx-size").arg(config.context_size.to_string())
        .arg("--host").arg("127.0.0.1");

    for arg in &config.extra_args {
        cmd.arg(arg);
    }

    cmd.stdout(Stdio::piped())
        .stderr(Stdio::piped());

    let mut child = cmd.spawn()
        .map_err(|e| anyhow::anyhow!("Failed to spawn llama-server at '{}': {}", config.binary, e))?;

    // Log stderr in background
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
