//! HTTP-proxy backend for llama-server / mnn-llm subprocesses.
//!
//! Concurrency: the backend itself is thread-safe; per-node concurrency is
//! gated by `NodeRuntimeState.semaphore` in cluster.rs.
//!
//! Channels use a bounded mpsc so that a slow relay path back-pressures the
//! SSE-reader task instead of growing unboundedly.

use serde_json::Value;
use std::process::Stdio;
use std::sync::{
    atomic::{AtomicBool, Ordering},
    Arc,
};
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
    advertised_model_id: String,
    backend_model_id: String,
    client: reqwest::Client,
    ready: Arc<AtomicBool>,
}

impl InferenceProxy {
    pub fn new(port: u16, advertised_model_id: &str, backend_model_id: &str) -> Self {
        Self {
            base_url: format!("http://127.0.0.1:{}", port),
            advertised_model_id: advertised_model_id.to_string(),
            backend_model_id: backend_model_id.to_string(),
            client: reqwest::Client::builder()
                .timeout(std::time::Duration::from_secs(300))
                .build()
                .expect("reqwest client build failed"),
            ready: Arc::new(AtomicBool::new(false)),
        }
    }

    pub fn loaded_models(&self) -> Vec<String> {
        if self.is_ready() {
            vec![self.advertised_model_id.clone()]
        } else {
            vec![]
        }
    }

    pub fn is_ready(&self) -> bool {
        self.ready.load(Ordering::Relaxed)
    }

    fn set_ready(&self, ready: bool) {
        self.ready.store(ready, Ordering::Relaxed);
    }

    #[cfg(test)]
    pub fn mark_ready_for_tests(&self, ready: bool) {
        self.set_ready(ready);
    }

    /// Wait for backend to become healthy (up to timeout_secs).
    pub async fn wait_for_health(&self, timeout_secs: u64) -> anyhow::Result<()> {
        let deadline = tokio::time::Instant::now() + tokio::time::Duration::from_secs(timeout_secs);

        loop {
            if tokio::time::Instant::now() > deadline {
                self.set_ready(false);
                anyhow::bail!("backend health check timed out after {}s", timeout_secs);
            }
            match self.backend_model_is_ready().await {
                Ok(true) => {
                    self.set_ready(true);
                    info!(
                        "backend is healthy at {} with model {}",
                        self.base_url, self.backend_model_id
                    );
                    return Ok(());
                }
                Ok(false) => {}
                Err(err) => debug!("backend health probe failed: {}", err),
            }
            tokio::time::sleep(tokio::time::Duration::from_secs(2)).await;
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
        body["model"] = Value::String(self.backend_model_id.clone());
        body["stream"] = Value::Bool(true);

        let response = self
            .client
            .post(&url)
            .json(&body)
            .send()
            .await
            .map_err(|e| {
                self.set_ready(false);
                anyhow::anyhow!("backend request failed: {}", e)
            })?;

        if !response.status().is_success() {
            let status = response.status();
            let text = response.text().await.unwrap_or_default();
            anyhow::bail!("backend returned {}: {}", status, text);
        }
        self.set_ready(true);

        let (tx, rx) = mpsc::channel::<Value>(CHUNK_CHANNEL_CAPACITY);
        let ready = self.ready.clone();

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
                        ready.store(false, Ordering::Relaxed);
                        error!("SSE stream error: {}", e);
                        break;
                    }
                }
            }
        });

        Ok(rx)
    }

    async fn backend_model_is_ready(&self) -> anyhow::Result<bool> {
        if let Some(loaded) = self.backend_model_ready_via_ollama_ps().await? {
            return Ok(loaded);
        }
        if let Some(loaded) = self.backend_model_ready_via_openai_models().await? {
            return Ok(loaded);
        }
        if let Some(healthy) = self.backend_healthy_via_health().await? {
            return Ok(healthy);
        }
        Ok(false)
    }

    async fn backend_model_ready_via_ollama_ps(&self) -> anyhow::Result<Option<bool>> {
        let url = format!("{}/ollama/api/ps", self.base_url);
        let response = self.client.get(&url).send().await?;
        match response.status() {
            reqwest::StatusCode::NOT_FOUND | reqwest::StatusCode::METHOD_NOT_ALLOWED => Ok(None),
            status if !status.is_success() => Ok(Some(false)),
            _ => {
                let payload = response.json::<Value>().await?;
                Ok(Some(model_id_in_ollama_ps(
                    &payload,
                    &self.backend_model_id,
                )))
            }
        }
    }

    async fn backend_model_ready_via_openai_models(&self) -> anyhow::Result<Option<bool>> {
        let url = format!("{}/v1/models", self.base_url);
        let response = self.client.get(&url).send().await?;
        match response.status() {
            reqwest::StatusCode::NOT_FOUND | reqwest::StatusCode::METHOD_NOT_ALLOWED => Ok(None),
            status if !status.is_success() => Ok(Some(false)),
            _ => {
                let payload = response.json::<Value>().await?;
                Ok(Some(model_id_in_openai_models(
                    &payload,
                    &[
                        self.backend_model_id.as_str(),
                        self.advertised_model_id.as_str(),
                    ],
                )))
            }
        }
    }

    async fn backend_healthy_via_health(&self) -> anyhow::Result<Option<bool>> {
        let url = format!("{}/health", self.base_url);
        let response = self.client.get(&url).send().await?;
        match response.status() {
            reqwest::StatusCode::NOT_FOUND | reqwest::StatusCode::METHOD_NOT_ALLOWED => Ok(None),
            status => Ok(Some(status.is_success())),
        }
    }
}

fn model_id_in_ollama_ps(payload: &Value, expected_model_id: &str) -> bool {
    payload
        .get("models")
        .and_then(Value::as_array)
        .or_else(|| payload.as_array())
        .into_iter()
        .flatten()
        .filter_map(Value::as_object)
        .filter_map(|model| {
            model
                .get("model")
                .or_else(|| model.get("name"))
                .and_then(Value::as_str)
        })
        .any(|model_id| model_id == expected_model_id)
}

fn model_id_in_openai_models(payload: &Value, expected_model_ids: &[&str]) -> bool {
    payload
        .get("data")
        .and_then(Value::as_array)
        .or_else(|| payload.as_array())
        .into_iter()
        .flatten()
        .filter_map(Value::as_object)
        .filter_map(|model| model.get("id").and_then(Value::as_str))
        .any(|model_id| expected_model_ids.contains(&model_id))
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

#[cfg(test)]
mod tests {
    use super::{model_id_in_ollama_ps, model_id_in_openai_models, InferenceProxy};

    #[test]
    fn loaded_models_require_ready_backend() {
        let proxy = InferenceProxy::new(11436, "moonshotai/kimi-k2.6", "unsloth/Kimi-K2.6");
        assert!(proxy.loaded_models().is_empty());

        proxy.mark_ready_for_tests(true);
        assert_eq!(
            proxy.loaded_models(),
            vec!["moonshotai/kimi-k2.6".to_string()]
        );
        assert!(proxy.is_ready());
    }

    #[test]
    fn ollama_ps_probe_requires_expected_backend_model() {
        let payload = serde_json::json!({
            "models": [
                { "model": "unsloth/Kimi-K2.6" },
                { "model": "other/model" }
            ]
        });
        assert!(model_id_in_ollama_ps(&payload, "unsloth/Kimi-K2.6"));
        assert!(!model_id_in_ollama_ps(&payload, "moonshotai/kimi-k2.6"));
    }

    #[test]
    fn openai_models_probe_matches_backend_or_advertised_model() {
        let payload = serde_json::json!({
            "data": [
                { "id": "moonshotai/kimi-k2.6" },
                { "id": "qwen/qwen3.6-35b-a3b" }
            ]
        });
        assert!(model_id_in_openai_models(
            &payload,
            &["unsloth/Kimi-K2.6", "moonshotai/kimi-k2.6"]
        ));
        assert!(!model_id_in_openai_models(&payload, &["unsloth/Kimi-K2.6"]));
    }
}
