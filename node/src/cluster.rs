//! Node-side cluster message handlers.
//!
//! Types are in `teale_protocol::cluster`; this file wires the node's
//! behaviour when an `inferenceRequest` / `heartbeat` / `hello` arrives.
//!
//! Reliability primitives live here too: bounded channels, concurrency cap,
//! model pre-check, real heartbeat state.

use std::sync::atomic::{AtomicBool, AtomicU32, AtomicU64, Ordering};
use std::sync::Arc;
use std::time::Instant;

use serde_json::Value;
use tokio::sync::Semaphore;
use tracing::{debug, error, info, warn};

use teale_protocol::{
    decode_relay_data, now_reference_seconds, ClusterMessage, HeartbeatPayload, HelloAckPayload,
    InferenceErrorCode, InferenceErrorPayload, InferenceRequestPayload, ThermalLevel,
};

pub use teale_protocol::openai::{ApiMessage, ChatCompletionRequest};

use crate::relay::{RelayClient, RelayDataPayload};
use crate::swap::SwapManager;

/// Shared, in-process node state surfaced into heartbeats.
///
/// Invariants: atomics are the source of truth; `HeartbeatPayload`
/// rendered from them matches protocol expectations.
pub struct NodeRuntimeState {
    pub device_id: String,
    pub queue_depth: AtomicU32,
    pub is_generating: AtomicBool,
    pub throttle_level: AtomicU32,       // 0 (paused) .. 100 (full)
    pub thermal_level: AtomicU32,        // encoded ThermalLevel ordinal
    pub completed_requests: AtomicU64,
    pub failed_requests: AtomicU64,
    pub total_completion_tokens: AtomicU64,
    pub total_completion_seconds_micros: AtomicU64, // sum of completion durations in microseconds
    pub shutting_down: AtomicBool,
    pub semaphore: Arc<Semaphore>,
}

impl NodeRuntimeState {
    pub fn new(max_concurrent: u32) -> Self {
        Self {
            device_id: uuid::Uuid::new_v4().to_string(),
            queue_depth: AtomicU32::new(0),
            is_generating: AtomicBool::new(false),
            throttle_level: AtomicU32::new(100),
            thermal_level: AtomicU32::new(thermal_to_ord(ThermalLevel::Nominal)),
            completed_requests: AtomicU64::new(0),
            failed_requests: AtomicU64::new(0),
            total_completion_tokens: AtomicU64::new(0),
            total_completion_seconds_micros: AtomicU64::new(0),
            shutting_down: AtomicBool::new(false),
            semaphore: Arc::new(Semaphore::new(max_concurrent as usize)),
        }
    }

    pub fn ewma_tokens_per_second(&self) -> Option<f64> {
        let tokens = self.total_completion_tokens.load(Ordering::Relaxed) as f64;
        let secs = self.total_completion_seconds_micros.load(Ordering::Relaxed) as f64 / 1_000_000.0;
        if secs < 0.001 || tokens < 1.0 {
            return None;
        }
        Some(tokens / secs)
    }

    pub fn thermal_level(&self) -> ThermalLevel {
        ord_to_thermal(self.thermal_level.load(Ordering::Relaxed))
    }

    pub fn set_thermal_level(&self, level: ThermalLevel) {
        self.thermal_level.store(thermal_to_ord(level), Ordering::Relaxed);
    }

    pub fn heartbeat_payload(&self, loaded_models: Vec<String>) -> HeartbeatPayload {
        HeartbeatPayload {
            device_id: self.device_id.clone(),
            timestamp: now_reference_seconds(),
            thermal_level: self.thermal_level(),
            throttle_level: self.throttle_level.load(Ordering::Relaxed),
            loaded_models,
            is_generating: self.is_generating.load(Ordering::Relaxed),
            queue_depth: self.queue_depth.load(Ordering::Relaxed),
            ewma_tokens_per_second: self.ewma_tokens_per_second(),
        }
    }
}

fn thermal_to_ord(t: ThermalLevel) -> u32 {
    match t {
        ThermalLevel::Nominal => 0,
        ThermalLevel::Fair => 1,
        ThermalLevel::Serious => 2,
        ThermalLevel::Critical => 3,
    }
}

fn ord_to_thermal(v: u32) -> ThermalLevel {
    match v {
        1 => ThermalLevel::Fair,
        2 => ThermalLevel::Serious,
        3 => ThermalLevel::Critical,
        _ => ThermalLevel::Nominal,
    }
}

/// Dispatch a decoded relayData payload.
pub async fn handle_relay_data(
    relay: &RelayClient,
    payload: &RelayDataPayload,
    swap: &Arc<SwapManager>,
    state: &Arc<NodeRuntimeState>,
    device_info_json: &Value,
) {
    let data_bytes = match decode_relay_data(&payload.data) {
        Some(b) => b,
        None => {
            warn!(
                "Failed to decode relay data from {}",
                &payload.from_node_id[..16.min(payload.from_node_id.len())]
            );
            return;
        }
    };

    let message = match ClusterMessage::parse(&data_bytes) {
        Some(m) => m,
        None => {
            let preview = String::from_utf8_lossy(&data_bytes[..200.min(data_bytes.len())]);
            warn!("Failed to parse ClusterMessage: {}", preview);
            return;
        }
    };

    let from = &payload.from_node_id;
    let session = &payload.session_id;

    match message {
        ClusterMessage::Hello(_) => {
            info!("Received hello from {}, sending helloAck", short(from));
            let ack = ClusterMessage::HelloAck(HelloAckPayload {
                device_info: device_info_json.clone(),
                protocol_version: 1,
                loaded_models: swap.loaded_models().await,
            });
            send(relay, from, session, &ack);
        }

        ClusterMessage::Heartbeat(_) => {
            let loaded = swap.loaded_models().await;
            let ack = ClusterMessage::HeartbeatAck(state.heartbeat_payload(loaded));
            send(relay, from, session, &ack);
        }

        ClusterMessage::InferenceRequest(req) => {
            if state.shutting_down.load(Ordering::Relaxed) {
                reply_err(
                    relay,
                    from,
                    session,
                    &req.request_id,
                    "node is shutting down",
                    Some(InferenceErrorCode::Unavailable),
                );
                return;
            }
            handle_inference_request(relay, from, session, req, swap, state).await;
        }

        ClusterMessage::LoadModel(req) => {
            let sm = swap.clone();
            let relay_node = from.to_string();
            let relay_session = session.to_string();
            let relay_handle = relay.clone();
            let request_id = req.request_id.clone();
            let model_id = req.model_id.clone();
            // Run the swap off the message-pump task so the relay keeps
            // receiving other traffic. `swap` drains the queue and does a
            // subprocess dance; it can take tens of seconds.
            tokio::spawn(async move {
                let reply = match sm.swap(request_id, model_id).await {
                    Ok(loaded) => ClusterMessage::ModelLoaded(loaded),
                    Err(err) => ClusterMessage::ModelLoadError(err),
                };
                let value = reply.to_value();
                if let Err(e) =
                    relay_handle.send_cluster_message(&relay_node, &relay_session, &value)
                {
                    error!("send swap result: {}", e);
                }
            });
        }

        ClusterMessage::Unknown { kind, .. } => {
            debug!("Ignoring unknown cluster message type: {}", kind);
        }

        _ => {
            // HelloAck / HeartbeatAck / InferenceChunk/Complete/Error / ModelLoaded*
            // are responses — a supply node doesn't expect to receive them.
        }
    }
}

async fn handle_inference_request(
    relay: &RelayClient,
    from: &str,
    session: &str,
    req: InferenceRequestPayload,
    swap: &Arc<SwapManager>,
    state: &Arc<NodeRuntimeState>,
) {
    let request_id = req.request_id.clone();

    // 1. Concurrency cap: fail fast if full.
    let permit = match state.semaphore.clone().try_acquire_owned() {
        Ok(p) => p,
        Err(_) => {
            warn!("Queue full — dropping request {}", request_id);
            state.failed_requests.fetch_add(1, Ordering::Relaxed);
            reply_err(
                relay,
                from,
                session,
                &request_id,
                "queue full",
                Some(InferenceErrorCode::QueueFull),
            );
            return;
        }
    };

    state.queue_depth.fetch_add(1, Ordering::Relaxed);
    state.is_generating.store(true, Ordering::Relaxed);

    // Guard decrements on drop — covers error paths.
    struct QueueGuard<'a>(&'a NodeRuntimeState);
    impl<'a> Drop for QueueGuard<'a> {
        fn drop(&mut self) {
            self.0.queue_depth.fetch_sub(1, Ordering::Relaxed);
            if self.0.queue_depth.load(Ordering::Relaxed) == 0 {
                self.0.is_generating.store(false, Ordering::Relaxed);
            }
        }
    }
    let _guard = QueueGuard(state);

    // 2. Model pre-check: fail typed instead of hitting the backend with a wrong model.
    if let Some(requested_model) = req.request.model.as_deref() {
        let loaded = swap.loaded_models().await;
        if !model_matches_any(requested_model, &loaded) {
            warn!(
                "Model pre-check failed: requested {} but loaded {:?}",
                requested_model, loaded
            );
            state.failed_requests.fetch_add(1, Ordering::Relaxed);
            reply_err(
                relay,
                from,
                session,
                &request_id,
                &format!(
                    "model '{}' not loaded on this node (loaded: {:?})",
                    requested_model, loaded
                ),
                Some(InferenceErrorCode::ModelNotLoaded),
            );
            return;
        }
    }

    info!(
        "Inference request {} from {} (queue_depth={})",
        request_id,
        short(from),
        state.queue_depth.load(Ordering::Relaxed)
    );

    let started = Instant::now();
    let mut token_count: u64 = 0;

    match swap.stream_completion(&req.request).await {
        Ok(mut rx) => {
            while let Some(chunk_json) = rx.recv().await {
                token_count += 1;
                let msg = ClusterMessage::InferenceChunk(teale_protocol::InferenceChunkPayload {
                    request_id: request_id.clone(),
                    chunk: chunk_json,
                });
                send(relay, from, session, &msg);
            }

            let elapsed = started.elapsed();
            state
                .total_completion_tokens
                .fetch_add(token_count, Ordering::Relaxed);
            state
                .total_completion_seconds_micros
                .fetch_add(elapsed.as_micros() as u64, Ordering::Relaxed);
            state.completed_requests.fetch_add(1, Ordering::Relaxed);

            let done = ClusterMessage::InferenceComplete(teale_protocol::InferenceCompletePayload {
                request_id: request_id.clone(),
                tokens_in: None,
                tokens_out: Some(token_count as u32),
            });
            send(relay, from, session, &done);
            info!(
                "Inference request {} completed ({} tokens in {:?})",
                request_id, token_count, elapsed
            );
        }
        Err(e) => {
            error!("Inference error for {}: {}", request_id, e);
            state.failed_requests.fetch_add(1, Ordering::Relaxed);
            reply_err(
                relay,
                from,
                session,
                &request_id,
                &e.to_string(),
                Some(InferenceErrorCode::InternalError),
            );
        }
    }

    drop(permit);
}

/// Tolerant match: accept `owner/name` and bare `name` variants because
/// OpenRouter/HF/llama-server all use different forms.
fn model_matches_any(requested: &str, loaded: &[String]) -> bool {
    let requested_norm = normalize_model_id(requested);
    loaded
        .iter()
        .any(|loaded| normalize_model_id(loaded) == requested_norm || loaded_contains(loaded, requested))
}

fn loaded_contains(loaded: &str, requested: &str) -> bool {
    // llama-server often serves with a file path as model id; allow substring match.
    loaded.contains(requested) || requested.contains(loaded)
}

fn normalize_model_id(id: &str) -> String {
    id.rsplit('/').next().unwrap_or(id).trim().to_lowercase()
}

fn reply_err(
    relay: &RelayClient,
    to: &str,
    session: &str,
    request_id: &str,
    message: &str,
    code: Option<InferenceErrorCode>,
) {
    let err = ClusterMessage::InferenceError(InferenceErrorPayload {
        request_id: request_id.to_string(),
        error_message: message.to_string(),
        code,
    });
    send(relay, to, session, &err);
}

fn send(relay: &RelayClient, to_node_id: &str, session_id: &str, message: &ClusterMessage) {
    let value = message.to_value();
    if let Err(e) = relay.send_cluster_message(to_node_id, session_id, &value) {
        error!("Failed to send cluster message: {}", e);
    }
}

fn short(node_id: &str) -> &str {
    &node_id[..16.min(node_id.len())]
}
