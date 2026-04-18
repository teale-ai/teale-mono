//! Phase C2: on-demand model swap for Ultra Studios.
//!
//! Owns the currently-loaded llama-server subprocess + its supervisor +
//! a `Backend` pointed at it. On `loadModel`, drains in-flight requests,
//! kills the current subprocess, spawns a fresh one with a different
//! `--model` path, waits for it to pass `/health`, and atomically swaps
//! the `Backend` reference so subsequent inference calls go to the new
//! model.
//!
//! Budget: 30 s total (10 s drain + 20 s health). On timeout / failure we
//! mark the node `is_available=false` and emit `modelLoadError`. No
//! automatic rollback — operator reviews logs and bounces the node.
//!
//! MNN / LiteRT swap not supported (their lifecycles differ; not on the
//! OpenRouter path for MVP).

use std::collections::HashMap;
use std::sync::atomic::Ordering;
use std::sync::Arc;
use std::time::{Duration, Instant};

use serde_json::Value;
use tokio::sync::{mpsc, RwLock};
use tracing::{info, warn};

use teale_protocol::openai::ChatCompletionRequest;
use teale_protocol::{ModelLoadErrorPayload, ModelLoadedPayload};

use crate::backend::Backend;
use crate::cluster::NodeRuntimeState;
use crate::config::LlamaConfig;
use crate::inference::{build_llama_command, InferenceProxy};
use crate::supervisor::Supervisor;

/// Per-model slot on disk. `swappable_models` in `teale-node.toml` is a
/// list of `"model_id=/path/to/model.gguf"` strings that map into this.
#[derive(Debug, Clone)]
pub struct ModelSlot {
    pub model_id: String,
    pub gguf_path: String,
}

impl ModelSlot {
    /// Parse a config entry. Accepts either `"id=path"` or just `"path"`
    /// (id derived from file stem).
    pub fn parse(entry: &str) -> Self {
        if let Some((id, path)) = entry.split_once('=') {
            return Self {
                model_id: id.trim().to_string(),
                gguf_path: path.trim().to_string(),
            };
        }
        let id = std::path::Path::new(entry)
            .file_stem()
            .map(|s| s.to_string_lossy().to_string())
            .unwrap_or_else(|| entry.to_string());
        Self {
            model_id: id,
            gguf_path: entry.to_string(),
        }
    }
}

/// The swap-capable wrapper around a single llama-server `Backend`.
pub struct SwapManager {
    inner: Arc<RwLock<Inner>>,
    llama_base: LlamaConfig,
    whitelist: HashMap<String, String>,
    state: Arc<NodeRuntimeState>,
    drain_budget: Duration,
    health_budget: Duration,
}

struct Inner {
    backend: Backend,
    supervisor: Option<Supervisor>,
    model_id: String,
}

impl SwapManager {
    pub fn new(
        backend: Backend,
        supervisor: Option<Supervisor>,
        model_id: String,
        llama_base: LlamaConfig,
        swappable_slots: Vec<ModelSlot>,
        state: Arc<NodeRuntimeState>,
    ) -> Arc<Self> {
        let mut whitelist: HashMap<String, String> = HashMap::new();
        for slot in swappable_slots {
            whitelist.insert(slot.model_id, slot.gguf_path);
        }
        Arc::new(Self {
            inner: Arc::new(RwLock::new(Inner {
                backend,
                supervisor,
                model_id,
            })),
            llama_base,
            whitelist,
            state,
            drain_budget: Duration::from_secs(10),
            health_budget: Duration::from_secs(20),
        })
    }

    /// Current loaded model ids. Source of truth for the heartbeat.
    pub async fn loaded_models(&self) -> Vec<String> {
        self.inner.read().await.backend.loaded_models()
    }

    /// Forward an inference request to whatever backend is loaded now.
    /// The read guard is dropped before the returned `Receiver` is used,
    /// so streams survive concurrent swaps (the spawned reader tasks hold
    /// the HTTP response, not the `Backend`).
    pub async fn stream_completion(
        &self,
        request: &ChatCompletionRequest,
    ) -> anyhow::Result<mpsc::Receiver<Value>> {
        let guard = self.inner.read().await;
        guard.backend.stream_completion(request).await
    }

    /// Is `model_id` either the loaded one or in the swap whitelist?
    pub async fn accepts(&self, model_id: &str) -> bool {
        let g = self.inner.read().await;
        if g.model_id == model_id {
            return true;
        }
        self.whitelist.contains_key(model_id)
    }

    /// Can we swap? Returns `Ok(())` if the model is in the whitelist and
    /// the GGUF file exists on disk.
    pub fn pre_check(&self, model_id: &str) -> Result<&str, SwapRejection> {
        let path = self
            .whitelist
            .get(model_id)
            .ok_or(SwapRejection::NotInWhitelist)?;
        if !std::path::Path::new(path).exists() {
            return Err(SwapRejection::GgufMissing);
        }
        Ok(path.as_str())
    }

    /// Perform the swap. Blocks the write lock for the duration — this
    /// serializes swaps but doesn't block already-returned streams.
    pub async fn swap(
        &self,
        request_id: String,
        model_id: String,
    ) -> Result<ModelLoadedPayload, ModelLoadErrorPayload> {
        info!(request_id, model_id, "swap requested");

        // Pre-check: in whitelist + file exists.
        let target_path = match self.pre_check(&model_id) {
            Ok(p) => p.to_string(),
            Err(r) => {
                return Err(ModelLoadErrorPayload {
                    request_id,
                    model_id,
                    reason: r.to_string(),
                });
            }
        };

        // If we're already serving this model, return success immediately.
        {
            let g = self.inner.read().await;
            if g.model_id == model_id {
                return Ok(ModelLoadedPayload {
                    request_id,
                    model_id,
                    load_time_ms: 0,
                });
            }
        }

        let total_started = Instant::now();

        // 1. Drain in-flight requests up to budget.
        let drain_deadline = Instant::now() + self.drain_budget;
        while self.state.queue_depth.load(Ordering::Relaxed) > 0 {
            if Instant::now() > drain_deadline {
                return Err(ModelLoadErrorPayload {
                    request_id,
                    model_id,
                    reason: format!(
                        "drain deadline exceeded ({} in flight)",
                        self.state.queue_depth.load(Ordering::Relaxed)
                    ),
                });
            }
            tokio::time::sleep(Duration::from_millis(100)).await;
        }

        // 2. Take the write lock; kill old subprocess; spawn new one.
        let mut inner = self.inner.write().await;

        if let Some(sup) = inner.supervisor.take() {
            info!("shutting down current subprocess ({})", sup.name());
            sup.shutdown().await;
        }

        let mut new_cfg = self.llama_base.clone();
        new_cfg.model = target_path.clone();
        let spawn_cfg = new_cfg.clone();

        info!(path = %target_path, "spawning llama-server for new model");
        let new_sup = Supervisor::spawn("llama-server", move || {
            let mut cmd = build_llama_command(&spawn_cfg)?;
            let mut child = cmd
                .spawn()
                .map_err(|e| anyhow::anyhow!("spawn llama-server: {}", e))?;
            attach_stderr_logger(&mut child, "llama-server");
            Ok(child)
        });

        // 3. Wait for the new server to become healthy.
        let proxy = InferenceProxy::new(new_cfg.port, &model_id);
        let elapsed_drain = total_started.elapsed();
        let health_budget = self
            .health_budget
            .saturating_sub(elapsed_drain.min(self.health_budget));
        let health_secs = health_budget.as_secs().max(1);

        if let Err(e) = proxy.wait_for_health(health_secs).await {
            warn!("new backend failed health check: {}", e);
            // Tear down the failed subprocess. We leave `inner.supervisor = None`
            // so the node appears unavailable until the operator intervenes.
            new_sup.shutdown().await;
            // Keep old backend model_id as the advertised state so the gateway
            // de-lists us cleanly.
            inner.supervisor = None;
            return Err(ModelLoadErrorPayload {
                request_id,
                model_id,
                reason: format!("new backend health check failed: {}", e),
            });
        }

        // 4. Commit.
        inner.backend = Backend::Http(proxy);
        inner.supervisor = Some(new_sup);
        inner.model_id = model_id.clone();

        let load_ms = total_started.elapsed().as_millis() as u64;
        info!(model_id, load_ms, "swap complete");
        Ok(ModelLoadedPayload {
            request_id,
            model_id,
            load_time_ms: load_ms,
        })
    }

    pub fn whitelist_ids(&self) -> Vec<String> {
        self.whitelist.keys().cloned().collect()
    }

    /// Signal shutdown on the current supervisor (if any). Called at
    /// graceful shutdown time from main.rs.
    pub async fn shutdown(&self) {
        let mut inner = self.inner.write().await;
        if let Some(sup) = inner.supervisor.take() {
            sup.shutdown().await;
        }
    }
}

#[derive(Debug, thiserror::Error)]
pub enum SwapRejection {
    #[error("not_swappable: model not in config.swappable_models")]
    NotInWhitelist,
    #[error("gguf_missing: configured GGUF path does not exist on disk")]
    GgufMissing,
}

fn attach_stderr_logger(child: &mut tokio::process::Child, tag: &'static str) {
    use tokio::io::{AsyncBufReadExt, BufReader};
    if let Some(stderr) = child.stderr.take() {
        tokio::spawn(async move {
            let reader = BufReader::new(stderr);
            let mut lines = reader.lines();
            while let Ok(Some(line)) = lines.next_line().await {
                tracing::info!("[{}] {}", tag, line);
            }
        });
    }
}
