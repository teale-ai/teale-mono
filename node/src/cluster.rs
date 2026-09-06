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
    InferenceErrorCode, InferenceErrorPayload, InferenceRequestPayload, ModelLoadErrorPayload,
    ThermalLevel,
};

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
    pub user_paused: AtomicBool,
    pub on_ac_power: AtomicBool,
    pub battery_gated: bool,
    pub throttle_level: AtomicU32, // 0 (paused) .. 100 (full)
    pub thermal_level: AtomicU32,  // encoded ThermalLevel ordinal
    pub completed_requests: AtomicU64,
    pub failed_requests: AtomicU64,
    pub total_completion_tokens: AtomicU64,
    pub total_completion_seconds_micros: AtomicU64, // sum of completion durations in microseconds
    pub shutting_down: AtomicBool,
    pub semaphore: Arc<Semaphore>,
    /// PIN-over-DIN admission priority, sharing `semaphore`.
    pub pin_gate: Arc<crate::pin::gate::PriorityGate>,
    /// Live inference worker tasks by relay session id (#229), each with
    /// its target peer id. RelayClose - or a peer_not_found / peerLeft
    /// naming the target (#237) - aborts the worker so a dead client
    /// stops consuming GPU.
    pub inference_tasks:
        std::sync::Mutex<std::collections::HashMap<String, (String, tokio::task::JoinHandle<()>)>>,
}

impl NodeRuntimeState {
    pub fn new(max_concurrent: u32) -> Self {
        let semaphore = Arc::new(Semaphore::new(max_concurrent as usize));
        Self {
            device_id: uuid::Uuid::new_v4().to_string(),
            queue_depth: AtomicU32::new(0),
            is_generating: AtomicBool::new(false),
            user_paused: AtomicBool::new(false),
            on_ac_power: AtomicBool::new(true),
            battery_gated: false,
            throttle_level: AtomicU32::new(100),
            thermal_level: AtomicU32::new(thermal_to_ord(ThermalLevel::Nominal)),
            completed_requests: AtomicU64::new(0),
            failed_requests: AtomicU64::new(0),
            total_completion_tokens: AtomicU64::new(0),
            total_completion_seconds_micros: AtomicU64::new(0),
            shutting_down: AtomicBool::new(false),
            semaphore: semaphore.clone(),
            pin_gate: crate::pin::gate::PriorityGate::new(semaphore),
            inference_tasks: std::sync::Mutex::new(std::collections::HashMap::new()),
        }
    }

    pub fn with_power_gating(mut self, battery_gated: bool, on_ac_power: bool) -> Self {
        self.battery_gated = battery_gated;
        self.on_ac_power.store(on_ac_power, Ordering::Relaxed);
        self
    }

    pub fn can_supply(&self) -> bool {
        !self.user_paused.load(Ordering::Relaxed)
            && (!self.battery_gated || self.on_ac_power.load(Ordering::Relaxed))
    }

    pub fn ewma_tokens_per_second(&self) -> Option<f64> {
        let tokens = self.total_completion_tokens.load(Ordering::Relaxed) as f64;
        let secs =
            self.total_completion_seconds_micros.load(Ordering::Relaxed) as f64 / 1_000_000.0;
        if secs < 0.001 || tokens < 1.0 {
            return None;
        }
        Some(tokens / secs)
    }

    pub fn thermal_level(&self) -> ThermalLevel {
        ord_to_thermal(self.thermal_level.load(Ordering::Relaxed))
    }

    pub fn set_thermal_level(&self, level: ThermalLevel) {
        self.thermal_level
            .store(thermal_to_ord(level), Ordering::Relaxed);
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
            if !state.can_supply() {
                reply_err(
                    relay,
                    from,
                    session,
                    &req.request_id,
                    "node is paused",
                    Some(InferenceErrorCode::Unavailable),
                );
                return;
            }
            // Run inference on its own task so the relay message pump keeps
            // processing other sessions (#229). The pin_gate semaphore is
            // the real concurrency cap (fail-fast QueueFull when full);
            // before this, the inline await serialized every request behind
            // the running one and max_concurrent never engaged.
            let relay_handle = relay.clone();
            let from_owned = from.to_string();
            let session_owned = session.to_string();
            let swap_owned = swap.clone();
            let state_owned = state.clone();
            let session_key = session_owned.clone();
            let handle = tokio::spawn(async move {
                handle_inference_request(
                    &relay_handle,
                    &from_owned,
                    &session_owned,
                    *req,
                    &swap_owned,
                    &state_owned,
                )
                .await;
                state_owned
                    .inference_tasks
                    .lock()
                    .unwrap()
                    .remove(&session_key);
            });
            state
                .inference_tasks
                .lock()
                .unwrap()
                .insert(session.to_string(), (from.to_string(), handle));
        }

        ClusterMessage::LoadModel(req) => {
            let in_flight = state.queue_depth.load(Ordering::Relaxed);
            if in_flight > 0 {
                warn!(
                    "Rejecting swap to {} - {} inference request(s) in flight",
                    req.model_id, in_flight
                );
                let reply = ClusterMessage::ModelLoadError(ModelLoadErrorPayload {
                    request_id: req.request_id.clone(),
                    model_id: req.model_id.clone(),
                    reason: format!(
                        "node busy: {} inference request(s) in flight; retry when idle",
                        in_flight
                    ),
                });
                send(relay, from, session, &reply);
                return;
            }
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

    // 1. Concurrency cap: fail fast if full — and yield to waiting PIN
    // requests (PIN traffic holds queue priority; spec §9).
    let permit = match state.pin_gate.try_acquire_din() {
        Some(p) => p,
        None => {
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
    struct QueueGuard(Arc<NodeRuntimeState>);
    impl Drop for QueueGuard {
        fn drop(&mut self) {
            self.0.queue_depth.fetch_sub(1, Ordering::Relaxed);
            if self.0.queue_depth.load(Ordering::Relaxed) == 0 {
                self.0.is_generating.store(false, Ordering::Relaxed);
            }
        }
    }
    let _guard = QueueGuard(state.clone());

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
            let mut first_token_logged = false;
            // Every stream ends with a terminal event (#255): Finished on a
            // natural end, Failed on the 900s budget cap or a mid-stream
            // read/decode error. A bare channel close is treated as a
            // failure too - never as a silent completion.
            let mut terminal: Option<Result<(), String>> = None;
            while let Some(event) = rx.recv().await {
                let chunk_json = match event {
                    crate::backend::StreamEvent::Chunk(c) => c,
                    crate::backend::StreamEvent::Finished => {
                        terminal = Some(Ok(()));
                        break;
                    }
                    crate::backend::StreamEvent::Failed(e) => {
                        terminal = Some(Err(e));
                        break;
                    }
                };
                if !first_token_logged {
                    first_token_logged = true;
                    info!(
                        "Inference request {} first token in {}ms",
                        request_id,
                        started.elapsed().as_millis()
                    );
                }
                token_count += 1;
                let msg = ClusterMessage::InferenceChunk(teale_protocol::InferenceChunkPayload {
                    request_id: request_id.clone(),
                    chunk: chunk_json,
                });
                send(relay, from, session, &msg);
            }

            match terminal {
                Some(Ok(())) => {
                    let elapsed = started.elapsed();
                    state
                        .total_completion_tokens
                        .fetch_add(token_count, Ordering::Relaxed);
                    state
                        .total_completion_seconds_micros
                        .fetch_add(elapsed.as_micros() as u64, Ordering::Relaxed);
                    state.completed_requests.fetch_add(1, Ordering::Relaxed);

                    let done = ClusterMessage::InferenceComplete(
                        teale_protocol::InferenceCompletePayload {
                            request_id: request_id.clone(),
                            tokens_in: None,
                            tokens_out: Some(token_count as u32),
                        },
                    );
                    send(relay, from, session, &done);
                    info!(
                        "Inference request {} completed ({} tokens in {:?})",
                        request_id, token_count, elapsed
                    );
                }
                Some(Err(e)) => {
                    state.failed_requests.fetch_add(1, Ordering::Relaxed);
                    error!(
                        "Inference request {} failed after {} token(s): {}",
                        request_id, token_count, e
                    );
                    reply_err(
                        relay,
                        from,
                        session,
                        &request_id,
                        &e,
                        Some(InferenceErrorCode::InternalError),
                    );
                }
                None => {
                    state.failed_requests.fetch_add(1, Ordering::Relaxed);
                    error!(
                        "Inference request {} stream closed with no terminal event after {} token(s)",
                        request_id, token_count
                    );
                    reply_err(
                        relay,
                        from,
                        session,
                        &request_id,
                        "backend stream closed without an outcome",
                        Some(InferenceErrorCode::InternalError),
                    );
                }
            }
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
pub(crate) fn model_matches_any(requested: &str, loaded: &[String]) -> bool {
    let requested_norm = normalize_model_id(requested);
    loaded.iter().any(|loaded| {
        normalize_model_id(loaded) == requested_norm || loaded_contains(loaded, requested)
    })
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

/// Abort in-flight inference workers whose target peer is `peer_id`
/// (#237): once the relay says a peer is gone (peer_not_found) or left,
/// requests toward it are generating into the void. Returns how many
/// workers were aborted.
pub fn abort_sessions_to_peer(state: &NodeRuntimeState, peer_id: &str) -> usize {
    let mut tasks = state.inference_tasks.lock().unwrap();
    let doomed: Vec<String> = tasks
        .iter()
        .filter(|(_, (from, _))| from == peer_id)
        .map(|(session, _)| session.clone())
        .collect();
    let aborted = doomed.len();
    for session in doomed {
        if let Some((_, handle)) = tasks.remove(&session) {
            handle.abort();
        }
    }
    aborted
}

/// Abort every in-flight inference worker (#237): the relay connection
/// itself is gone, so no chunk can reach any consumer - each in-flight
/// request already failed from the consumer's side, and letting it run to
/// "completion" would burn compute and count a request as served that was
/// never delivered. Aborted workers are counted as failed, not completed.
/// Returns how many workers were aborted.
pub fn abort_all_inference(state: &NodeRuntimeState) -> usize {
    let mut tasks = state.inference_tasks.lock().unwrap();
    let aborted = tasks.len();
    if aborted > 0 {
        state
            .failed_requests
            .fetch_add(aborted as u64, Ordering::Relaxed);
    }
    for (_, (_, handle)) in tasks.drain() {
        handle.abort();
    }
    aborted
}

/// Parse the peer id out of a relay `peer_not_found` error message
/// ("Peer <id> is not connected", relay/server.ts).
pub fn peer_not_found_id(message: &str) -> Option<&str> {
    message
        .strip_prefix("Peer ")?
        .strip_suffix(" is not connected")
}

#[cfg(test)]
mod tests {
    use super::peer_not_found_id;

    #[test]
    fn parses_peer_not_found_message() {
        assert_eq!(
            peer_not_found_id("Peer e8e5a748b6fc9a92 is not connected"),
            Some("e8e5a748b6fc9a92")
        );
        assert_eq!(peer_not_found_id("rate limited"), None);
        assert_eq!(peer_not_found_id("Peer x is not connecte"), None);
    }
}
