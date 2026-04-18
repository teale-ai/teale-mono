//! Phase C2: on-demand model swap for Ultra Studios.
//!
//! **Skeleton only — not wired into `main.rs` yet.** Ship pinned-only for the
//! OpenRouter MVP; promote swap in a subsequent deploy once the gateway's
//! Phase B scoreboard is green.
//!
//! When enabled, this module will:
//!   1. Own the current `Supervisor` + active `model_id`.
//!   2. On `loadModel { model_id }`, verify the requested id is in the
//!      configured `swappable_models` list and the GGUF file exists on disk.
//!   3. `Supervisor::shutdown()` the current backend.
//!   4. Rebuild a `LlamaConfig` pointed at the new GGUF and spawn a new
//!      Supervisor. Wait up to 30s for health.
//!   5. Atomically publish the new `loaded_model` so subsequent inference
//!      requests pre-check against it.
//!   6. Emit a fresh heartbeat / re-register so the gateway's registry
//!      updates its loaded_models set.
//!
//! Contract:
//!   - If the swap succeeds within the budget → `ModelLoaded { load_time_ms }`.
//!   - If the budget is exceeded → kill the new process, respawn the
//!     previous model, respond `ModelLoadError { reason: "timeout" }`.
//!   - If the GGUF isn't on disk or isn't in the whitelist →
//!     `ModelLoadError { reason: "not_swappable" }`.
//!
//! Safety:
//!   - Only one swap at a time; concurrent `loadModel` requests must
//!     serialize on a `tokio::sync::Mutex<SwapState>`.
//!   - During swap, `NodeRuntimeState.is_available = false` so the gateway
//!     stops routing new requests to us mid-transition.

use std::sync::Arc;

use teale_protocol::{ModelLoadedPayload, ModelLoadErrorPayload};
use tokio::sync::Mutex;

use crate::config::LlamaConfig;
use crate::supervisor::Supervisor;

#[allow(dead_code)]
pub struct SwapState {
    current_model_id: String,
    current_supervisor: Option<Supervisor>,
    swappable_models: Vec<ModelSlot>,
}

/// One slot in the swappable-models list — points at a GGUF path that's
/// already on disk and ready to mmap.
#[derive(Debug, Clone)]
pub struct ModelSlot {
    pub model_id: String,
    pub gguf_path: String,
}

#[allow(dead_code)]
pub struct SwapManager {
    inner: Arc<Mutex<SwapState>>,
    base_config: LlamaConfig,
}

#[allow(dead_code)]
impl SwapManager {
    pub fn new(base_config: LlamaConfig, initial_model_id: String, slots: Vec<ModelSlot>) -> Self {
        Self {
            inner: Arc::new(Mutex::new(SwapState {
                current_model_id: initial_model_id,
                current_supervisor: None,
                swappable_models: slots,
            })),
            base_config,
        }
    }

    /// TODO(Phase C2): perform the actual swap. Returns one of the two
    /// ClusterMessage payloads the caller should send back via the relay.
    pub async fn load_model(
        &self,
        request_id: String,
        model_id: String,
    ) -> Result<ModelLoadedPayload, ModelLoadErrorPayload> {
        let _guard = self.inner.lock().await;
        // Not implemented — caller (cluster.rs) currently responds with
        // ModelLoadError for every loadModel request.
        Err(ModelLoadErrorPayload {
            request_id,
            model_id,
            reason: "swap not enabled on this build (pinned-only MVP)".to_string(),
        })
    }
}
