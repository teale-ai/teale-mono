//! Gateway's WebSocket client for the TealeNet relay.
//!
//! Responsibilities:
//!   1. Connect to `wss://relay.teale.com/ws` with the gateway's own Ed25519
//!      identity and register as a "node" with minimal capabilities.
//!   2. Maintain the device registry by consuming `peerJoined` / `peerLeft`
//!      and `discoverResponse` messages.
//!   3. Route outgoing `relayData(inferenceRequest)` to target nodes.
//!   4. Fan `inferenceChunk` / `inferenceComplete` / `inferenceError`
//!      responses back to per-request consumers via a session registry.

use std::collections::HashMap;
use std::sync::Arc;
use std::time::{Duration, Instant};

use dashmap::DashMap;
use futures_util::{SinkExt, StreamExt};
use parking_lot::Mutex;
use tokio::sync::{mpsc, oneshot};
use tokio_tungstenite::{connect_async, tungstenite::Message};
use tracing::{debug, info, warn};
use uuid::Uuid;

use teale_protocol::{
    ClusterMessage, GpuBackend, HardwareCapability, IncomingRelayMessage, NodeCapabilities,
};

use crate::config::Config;
use crate::identity::GatewayIdentity;
use crate::metrics;
use crate::registry::Registry;

fn relay_idle_timeout(discover_interval_seconds: u64) -> Duration {
    Duration::from_secs((discover_interval_seconds.saturating_mul(6)).max(30))
}
/// One in-flight session waiting for its upstream response.
pub struct PendingSession {
    pub request_id: String,
    pub device_node_id: String,
    pub session_id: String,
    pub chunks_tx: mpsc::Sender<SessionEvent>,
}

/// Events forwarded to the request handler.
#[derive(Debug, Clone)]
pub enum SessionEvent {
    Chunk(serde_json::Value),
    Complete {
        tokens_out: Option<u32>,
    },
    Error {
        message: String,
        code: Option<String>,
    },
    /// Relay session or upstream node dropped — treat as failure.
    Disconnect(String),
}

/// Handle returned from `RelayClient::spawn` — the axum handlers use this
/// to open sessions, send requests, and receive the per-request stream.
#[derive(Clone)]
pub struct RelayHandle {
    node_id: String,
    sessions: Arc<DashMap<String, PendingSession>>,
    /// Waiters registered before `relayReady` arrives (by session_id).
    ready_waiters: Arc<Mutex<HashMap<String, ReadyWaiter>>>,
    outbox: mpsc::UnboundedSender<Message>,
}

struct ReadyWaiter {
    target_node_id: String,
    tx: oneshot::Sender<anyhow::Result<()>>,
}

impl RelayHandle {
    /// Test-only handle whose outbox goes nowhere (sends are swallowed).
    #[cfg(test)]
    pub(crate) fn dummy_for_tests() -> Self {
        let (tx, _rx) = mpsc::unbounded_channel();
        Self {
            node_id: "test-gateway".to_string(),
            sessions: Default::default(),
            ready_waiters: Default::default(),
            outbox: tx,
        }
    }

    pub fn node_id(&self) -> &str {
        &self.node_id
    }

    /// Open a relay session with a target node. Returns when the peer sends
    /// `relayReady` (or the timeout elapses).
    pub async fn open_session(
        &self,
        target_node_id: &str,
        timeout: Duration,
    ) -> anyhow::Result<String> {
        let session_id = Uuid::new_v4().to_string();
        let (tx, rx) = oneshot::channel::<anyhow::Result<()>>();
        self.ready_waiters.lock().insert(
            session_id.clone(),
            ReadyWaiter {
                target_node_id: target_node_id.to_string(),
                tx,
            },
        );

        let payload = serde_json::json!({
            "relayOpen": {
                "fromNodeID": self.node_id,
                "toNodeID": target_node_id,
                "sessionID": session_id,
            }
        });
        if let Err(err) = self.send_json(&payload) {
            self.ready_waiters.lock().remove(&session_id);
            return Err(err);
        }

        match tokio::time::timeout(timeout, rx).await {
            Ok(Ok(Ok(()))) => Ok(session_id),
            Ok(Ok(Err(err))) => Err(err),
            Ok(Err(_)) => anyhow::bail!("session ready waiter dropped"),
            Err(_) => {
                self.ready_waiters.lock().remove(&session_id);
                anyhow::bail!("timeout waiting for relayReady")
            }
        }
    }

    pub fn close_session(&self, target_node_id: &str, session_id: &str) {
        self.sessions.remove(session_id);
        let payload = serde_json::json!({
            "relayClose": {
                "fromNodeID": self.node_id,
                "toNodeID": target_node_id,
                "sessionID": session_id,
            }
        });
        let _ = self.send_json(&payload);
    }

    pub fn register_session(&self, session: PendingSession) {
        self.sessions.insert(session.session_id.clone(), session);
    }

    pub fn send_cluster(
        &self,
        target_node_id: &str,
        session_id: &str,
        message: &ClusterMessage,
    ) -> anyhow::Result<()> {
        let data_bytes = serde_json::to_vec(&message.to_value())?;
        let encoded =
            base64::Engine::encode(&base64::engine::general_purpose::STANDARD, &data_bytes);
        let payload = serde_json::json!({
            "relayData": {
                "fromNodeID": self.node_id,
                "toNodeID": target_node_id,
                "sessionID": session_id,
                "data": encoded,
            }
        });
        self.send_json(&payload)
    }

    fn send_json(&self, v: &serde_json::Value) -> anyhow::Result<()> {
        let text = serde_json::to_string(v)?;
        self.outbox
            .send(Message::Text(text))
            .map_err(|_| anyhow::anyhow!("relay outbox closed"))?;
        Ok(())
    }

    pub fn request_discover(&self) -> anyhow::Result<()> {
        let payload = serde_json::json!({
            "discover": {
                "requestingNodeID": self.node_id,
            }
        });
        self.send_json(&payload)
    }

    #[cfg(test)]
    pub fn test_handle() -> Self {
        let (outbox, mut rx) = mpsc::unbounded_channel();
        tokio::spawn(async move { while rx.recv().await.is_some() {} });
        Self {
            node_id: "test-node".into(),
            sessions: Arc::new(DashMap::new()),
            ready_waiters: Arc::new(Mutex::new(HashMap::new())),
            outbox,
        }
    }

    #[cfg(test)]
    pub fn test_ready_waiter_ids(&self) -> Vec<String> {
        self.ready_waiters.lock().keys().cloned().collect()
    }

    #[cfg(test)]
    pub fn test_signal_ready(&self, session_id: &str) -> bool {
        self.ready_waiters
            .lock()
            .remove(session_id)
            .map(|waiter| waiter.tx.send(Ok(())).is_ok())
            .unwrap_or(false)
    }
}

/// Spawn the relay client — connects, registers, routes messages into the
/// registry + session table, exposes a [`RelayHandle`] for the axum side.
pub async fn spawn(
    config: &Config,
    identity: Arc<GatewayIdentity>,
    registry: Arc<Registry>,
) -> anyhow::Result<RelayHandle> {
    let node_id = identity.node_id();

    let (outbox_tx, mut outbox_rx) = mpsc::unbounded_channel::<Message>();
    let sessions: Arc<DashMap<String, PendingSession>> = Arc::new(DashMap::new());
    // Ghost sessions already answered with relayClose (#213 symmetry):
    // one close per unknown session, not one per streamed chunk.
    let ghost_closes: Arc<DashMap<String, Instant>> = Arc::new(DashMap::new());
    let ready_waiters: Arc<Mutex<HashMap<String, ReadyWaiter>>> =
        Arc::new(Mutex::new(HashMap::new()));

    let handle = RelayHandle {
        node_id: node_id.clone(),
        sessions: sessions.clone(),
        ready_waiters: ready_waiters.clone(),
        outbox: outbox_tx.clone(),
    };

    // The outbox receiver must live for the whole process, so it is drained
    // by ONE persistent task that forwards to whichever connection is live.
    // The previous design moved the receiver into a per-connection drain task;
    // on the first reconnect the drained receiver was a dummy, the real one was
    // dropped, and every send (including the re-register) failed silently -
    // leaving the gateway connected to the relay but unregistered until the
    // next process restart (devices' offers then die as peer_not_found).
    let current_tx: Arc<std::sync::Mutex<Option<mpsc::UnboundedSender<Message>>>> =
        Arc::new(std::sync::Mutex::new(None));
    {
        let current_tx = current_tx.clone();
        tokio::spawn(async move {
            while let Some(m) = outbox_rx.recv().await {
                let tx = current_tx.lock().unwrap().clone();
                if let Some(tx) = tx {
                    // A dead connection between snapshot and send drops the
                    // message; sessions are failed on disconnect anyway.
                    let _ = tx.send(m);
                }
                // None (disconnected): drop. Stale register/relayOpen/relayData
                // for dead sessions must not replay onto the next connection.
            }
        });
    }

    let connection_task = {
        let relay_url = config.relay.url.clone();
        let identity = identity.clone();
        let registry = registry.clone();
        let display_name = config.display_name.clone();
        let sessions = sessions.clone();
        let ghost_closes = ghost_closes.clone();
        let ready_waiters = ready_waiters.clone();
        let outbox_tx = outbox_tx.clone();
        let handle = handle.clone();
        let current_tx = current_tx.clone();
        let reliability = config.reliability.clone();
        let fleet = config.fleet.clone();
        let apmhelp = config.apmhelp.clone();
        let idle_timeout = relay_idle_timeout(config.reliability.discover_interval_seconds);

        tokio::spawn(async move {
            let mut backoff = Duration::from_secs(1);
            const MAX_BACKOFF: Duration = Duration::from_secs(60);

            loop {
                let url_with_node = format!("{}?node={}", relay_url, node_id);
                info!("Connecting to relay: {}", relay_url);
                match connect_async(&url_with_node).await {
                    Ok((ws_stream, _)) => {
                        info!("Connected to relay");
                        backoff = Duration::from_secs(1);
                        metrics::WS_RECONNECTS_TOTAL
                            .with_label_values(&["connect_success"])
                            .inc();

                        let (mut write, read) = ws_stream.split();

                        // writer task: fed by the persistent drain via the slot
                        let (local_outbox_tx, mut local_outbox_rx) =
                            mpsc::unbounded_channel::<Message>();
                        *current_tx.lock().unwrap() = Some(local_outbox_tx);
                        let write_task = tokio::spawn(async move {
                            while let Some(msg) = local_outbox_rx.recv().await {
                                if let Err(e) = write.send(msg).await {
                                    warn!("relay write: {}", e);
                                    break;
                                }
                            }
                        });

                        // register ourselves
                        let register_payload = make_register_payload(&identity, &display_name);
                        if let Err(e) = outbox_tx.send(Message::Text(register_payload)) {
                            warn!("send register: {}", e);
                        }

                        // reader loop: every incoming message until close.
                        let mut reader = read;
                        let mut sent_discover_after_ack = false;
                        loop {
                            let result =
                                match tokio::time::timeout(idle_timeout, reader.next()).await {
                                    Ok(result) => result,
                                    Err(_) => {
                                        warn!(
                                            "relay idle timeout after {:?} without inbound traffic",
                                            idle_timeout
                                        );
                                        metrics::WS_RECONNECTS_TOTAL
                                            .with_label_values(&["idle_timeout"])
                                            .inc();
                                        break;
                                    }
                                };
                            let Some(result) = result else {
                                warn!("relay connection closed by peer");
                                metrics::WS_RECONNECTS_TOTAL
                                    .with_label_values(&["peer_closed"])
                                    .inc();
                                break;
                            };

                            match result {
                                Ok(Message::Text(text)) => {
                                    let Some(msg) = IncomingRelayMessage::parse(&text) else {
                                        debug!("unparseable relay message: {}", text);
                                        continue;
                                    };
                                    handle_incoming(
                                        msg,
                                        &registry,
                                        &sessions,
                                        &ready_waiters,
                                        reliability.quarantine_seconds,
                                        &fleet,
                                        &apmhelp,
                                        &mut sent_discover_after_ack,
                                        &handle,
                                        &ghost_closes,
                                    )
                                    .await;
                                }
                                Ok(Message::Binary(data)) => {
                                    if let Ok(text) = String::from_utf8(data.to_vec()) {
                                        if let Some(msg) = IncomingRelayMessage::parse(&text) {
                                            handle_incoming(
                                                msg,
                                                &registry,
                                                &sessions,
                                                &ready_waiters,
                                                reliability.quarantine_seconds,
                                                &fleet,
                                                &apmhelp,
                                                &mut sent_discover_after_ack,
                                                &handle,
                                                &ghost_closes,
                                            )
                                            .await;
                                        }
                                    }
                                }
                                Ok(Message::Ping(d)) => {
                                    let _ = outbox_tx.send(Message::Pong(d));
                                }
                                Ok(Message::Close(_)) => {
                                    info!("relay sent Close");
                                    metrics::WS_RECONNECTS_TOTAL
                                        .with_label_values(&["server_close"])
                                        .inc();
                                    break;
                                }
                                Err(e) => {
                                    warn!("relay read error: {}", e);
                                    metrics::WS_RECONNECTS_TOTAL
                                        .with_label_values(&["read_error"])
                                        .inc();
                                    break;
                                }
                                _ => {}
                            }
                        }

                        *current_tx.lock().unwrap() = None;
                        write_task.abort();

                        // Fail in-flight sessions.
                        for entry in sessions.iter_mut() {
                            let _ = entry
                                .chunks_tx
                                .try_send(SessionEvent::Disconnect("relay disconnected".into()));
                        }
                        sessions.clear();
                        ready_waiters.lock().clear();
                    }
                    Err(e) => {
                        warn!("relay connect failed: {} — retry in {:?}", e, backoff);
                        metrics::WS_RECONNECTS_TOTAL
                            .with_label_values(&["connect_failed"])
                            .inc();
                    }
                }

                tokio::time::sleep(backoff).await;
                backoff = (backoff * 2).min(MAX_BACKOFF);
            }
        })
    };

    // Periodic discover + sweep task.
    {
        let handle = handle.clone();
        let registry = registry.clone();
        let interval = config.reliability.discover_interval_seconds;
        tokio::spawn(async move {
            let mut ticker = tokio::time::interval(Duration::from_secs(interval));
            ticker.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
            loop {
                ticker.tick().await;
                let _ = handle.request_discover();
                registry.sweep();
                metrics::DEVICES_CONNECTED.set(registry.device_count() as i64);
            }
        });
    }

    std::mem::forget(connection_task); // intentionally kept alive for process lifetime

    Ok(handle)
}

#[allow(clippy::too_many_arguments)]
async fn handle_incoming(
    msg: IncomingRelayMessage,
    registry: &Arc<Registry>,
    sessions: &Arc<DashMap<String, PendingSession>>,
    ready_waiters: &Arc<Mutex<HashMap<String, ReadyWaiter>>>,
    quarantine_seconds: u64,
    fleet: &crate::config::FleetConfig,
    apmhelp: &crate::config::ApmhelpConfig,
    sent_discover_after_ack: &mut bool,
    relay: &RelayHandle,
    ghost_closes: &Arc<DashMap<String, Instant>>,
) {
    match msg {
        IncomingRelayMessage::RegisterAck { node_id } => {
            info!(
                "relay registerAck (nodeID: {}...)",
                &node_id[..16.min(node_id.len())]
            );
            // Request a full peer dump now.
            *sent_discover_after_ack = true;
            // The next tick of the discover-interval task will fire; we could
            // send an immediate one here too — but the first tick fires now.
        }
        IncomingRelayMessage::DiscoverResponse { peers } => {
            debug!("discover response: {} peer(s)", peers.len());
            for peer in peers {
                let Some(obj) = peer.as_object() else {
                    continue;
                };
                let Some(node_id) = obj.get("nodeID").and_then(|v| v.as_str()) else {
                    continue;
                };
                let display_name = obj
                    .get("displayName")
                    .and_then(|v| v.as_str())
                    .unwrap_or("unknown")
                    .to_string();
                let Some(caps_json) = obj.get("capabilities") else {
                    continue;
                };
                // Fleet membership gate (#263): the relay is a global
                // namespace - any client can register and advertise
                // available=true, and an unfiltered upsert makes a
                // stranger's machine eligible supply that dispatch can
                // dial, sending prompts to unknown hardware. When the
                // allowlist is configured, only listed node ids enter
                // the registry.
                // apmhelp employee supply (#272): confirmed-employee
                // machines are admitted as lane-scoped supply (employee
                // class) even though they are not fleet; they never serve
                // the default lane.
                let employee = apmhelp.is_employee(node_id) && !fleet.allows(node_id);
                if !fleet.allows(node_id) && !employee {
                    warn!(
                        node = node_id,
                        display = %display_name,
                        "discover: peer denied by fleet allowlist - not eligible supply"
                    );
                    continue;
                }
                if employee && !fleet.allows(node_id) {
                    info!(
                        node = node_id,
                        display = %display_name,
                        "discover: apmhelp employee peer admitted as lane-scoped supply"
                    );
                }
                let caps = match serde_json::from_value::<NodeCapabilities>(caps_json.clone()) {
                    Ok(c) => c,
                    Err(e) => {
                        debug!(node = node_id, "capabilities parse failed: {}", e);
                        continue;
                    }
                };
                registry.upsert_device_with_class(
                    node_id.to_string(),
                    display_name,
                    caps,
                    employee,
                );
            }
            update_eligible_gauges(registry);
        }
        IncomingRelayMessage::PeerJoined(p) => {
            debug!(node = p.node_id, "peerJoined");
            // A full capability update will arrive on the next discover.
        }
        IncomingRelayMessage::PeerLeft(p) => {
            info!(node = p.node_id, "peerLeft");
            // Grace window, not instant removal: a transient relay flap
            // must not vanish the node's models from the catalog (#220).
            registry.mark_departed(&p.node_id);
            update_eligible_gauges(registry);
        }
        IncomingRelayMessage::RelayReady(s) => {
            if let Some(waiter) = ready_waiters.lock().remove(&s.session_id) {
                let _ = waiter.tx.send(Ok(()));
            }
        }
        IncomingRelayMessage::RelayData(d) => {
            let Some(raw) = teale_protocol::decode_relay_data(&d.data) else {
                debug!("relayData: failed to decode");
                return;
            };
            let Some(msg) = ClusterMessage::parse(&raw) else {
                debug!("relayData: unparseable ClusterMessage");
                return;
            };
            dispatch_cluster(
                msg,
                sessions,
                registry,
                &d.session_id,
                &d.from_node_id,
                relay,
                ghost_closes,
            )
            .await;
        }
        IncomingRelayMessage::RelayClose(s) => {
            if let Some((_, pending)) = sessions.remove(&s.session_id) {
                let _ = pending
                    .chunks_tx
                    .try_send(SessionEvent::Disconnect("peer closed session".into()));
            }
        }
        IncomingRelayMessage::Error(e) => {
            warn!("relay error: {} — {}", e.code, e.message);
            if e.code == "peer_not_found" {
                if let Some(peer_node_id) = extract_peer_node_id(&e.message) {
                    registry.quarantine(peer_node_id, quarantine_seconds);
                    fail_ready_waiters_for_target(
                        ready_waiters,
                        peer_node_id,
                        &format!("peer not connected: {}", peer_node_id),
                    );
                    fail_sessions_for_target(
                        sessions,
                        peer_node_id,
                        &format!("peer not connected: {}", peer_node_id),
                    );
                    update_eligible_gauges(registry);
                }
            }
        }
        IncomingRelayMessage::Unknown(k) => {
            debug!("unknown relay msg: {}", k);
        }
        _ => {}
    }
}

fn extract_peer_node_id(message: &str) -> Option<&str> {
    let rest = message.strip_prefix("Peer ")?;
    let (peer_node_id, suffix) = rest.split_once(' ')?;
    if suffix == "is not connected" {
        Some(peer_node_id)
    } else {
        None
    }
}

fn fail_ready_waiters_for_target(
    ready_waiters: &Arc<Mutex<HashMap<String, ReadyWaiter>>>,
    target_node_id: &str,
    message: &str,
) -> usize {
    let session_ids: Vec<String> = ready_waiters
        .lock()
        .iter()
        .filter_map(|(session_id, waiter)| {
            (waiter.target_node_id == target_node_id).then_some(session_id.clone())
        })
        .collect();
    let mut failed = 0usize;
    let mut waiters = ready_waiters.lock();
    for session_id in session_ids {
        if let Some(waiter) = waiters.remove(&session_id) {
            failed += 1;
            let _ = waiter.tx.send(Err(anyhow::anyhow!(message.to_string())));
        }
    }
    failed
}

fn fail_sessions_for_target(
    sessions: &Arc<DashMap<String, PendingSession>>,
    target_node_id: &str,
    message: &str,
) -> usize {
    let session_ids: Vec<String> = sessions
        .iter()
        .filter_map(|entry| {
            (entry.device_node_id == target_node_id).then_some(entry.session_id.clone())
        })
        .collect();
    let mut failed = 0usize;
    for session_id in session_ids {
        if let Some((_, pending)) = sessions.remove(&session_id) {
            failed += 1;
            let _ = pending
                .chunks_tx
                .try_send(SessionEvent::Disconnect(message.to_string()));
        }
    }
    failed
}

/// #213 symmetry, gateway side: a node streaming into a session the
/// gateway has no record of (the in-memory session table died with a
/// restart or relay flap) is streaming to nobody. Answer the first ghost
/// chunk with relayClose so the node's consumer-gone path (#258) cancels
/// the backend turn and frees the slot now, instead of running it to
/// completion. One close per ghost session, cached 10min so a long ghost
/// stream does not draw one close per chunk.
fn ghost_close_once(
    relay: &RelayHandle,
    ghost_closes: &DashMap<String, Instant>,
    from_node_id: &str,
    session_id: &str,
) {
    if ghost_closes.contains_key(session_id) {
        return;
    }
    if ghost_closes.len() >= 512 {
        ghost_closes.retain(|_, t| t.elapsed() < Duration::from_secs(600));
    }
    ghost_closes.insert(session_id.to_string(), Instant::now());
    info!(
        "ghost session {} traffic from {} - answering relayClose",
        session_id, from_node_id
    );
    relay.close_session(from_node_id, session_id);
}

async fn dispatch_cluster(
    msg: ClusterMessage,
    sessions: &Arc<DashMap<String, PendingSession>>,
    registry: &Arc<Registry>,
    session_id: &str,
    from_node_id: &str,
    relay: &RelayHandle,
    ghost_closes: &Arc<DashMap<String, Instant>>,
) {
    match msg {
        ClusterMessage::InferenceChunk(p) => {
            if let Some(entry) = sessions.get(session_id) {
                let _ = entry.chunks_tx.try_send(SessionEvent::Chunk(p.chunk));
            } else {
                ghost_close_once(relay, ghost_closes, from_node_id, session_id);
            }
        }
        ClusterMessage::InferenceComplete(p) => {
            if let Some((_, entry)) = sessions.remove(session_id) {
                let _ = entry.chunks_tx.try_send(SessionEvent::Complete {
                    tokens_out: p.tokens_out,
                });
            }
        }
        ClusterMessage::InferenceError(p) => {
            if let Some((_, entry)) = sessions.remove(session_id) {
                let code = p.code.map(|c| format!("{:?}", c).to_lowercase());
                let _ = entry.chunks_tx.try_send(SessionEvent::Error {
                    message: p.error_message,
                    code,
                });
            }
        }
        ClusterMessage::HeartbeatAck(hb) | ClusterMessage::Heartbeat(hb) => {
            registry.apply_heartbeat(from_node_id, &hb);
            update_eligible_gauges(registry);
        }
        _ => {
            debug!("dispatch: unhandled ClusterMessage");
        }
    }
}

fn update_eligible_gauges(registry: &Arc<Registry>) {
    // Rebuild once a full discover lands. Clear then re-emit.
    metrics::DEVICES_ELIGIBLE.reset();
    metrics::DEVICE_SLOTS_BUSY.reset();
    metrics::DEVICE_SLOTS_TOTAL.reset();
    let mut per_model: std::collections::HashMap<String, u32> = std::collections::HashMap::new();
    for dev in registry.snapshot_devices() {
        for m in &dev.capabilities.loaded_models {
            *per_model.entry(m.clone()).or_insert(0) += 1;
        }
        // Slot occupancy is self-reported (#288): emit a series only for
        // devices whose heartbeats carry it - an absent series reads as
        // "does not report", never as zero.
        if let Some(busy) = dev.capabilities.backend_slots_busy {
            metrics::DEVICE_SLOTS_BUSY
                .with_label_values(&[&dev.display_name])
                .set(busy as f64);
        }
        if let Some(total) = dev.capabilities.backend_slots_total {
            metrics::DEVICE_SLOTS_TOTAL
                .with_label_values(&[&dev.display_name])
                .set(total as f64);
        }
    }
    for (m, n) in per_model {
        metrics::DEVICES_ELIGIBLE
            .with_label_values(&[&m])
            .set(n as f64);
    }
}

fn make_register_payload(identity: &Arc<GatewayIdentity>, display_name: &str) -> String {
    let caps = NodeCapabilities {
        hardware: HardwareCapability {
            chip_family: "gatewayVirtual".into(),
            chip_name: "gateway.teale.com".into(),
            total_ram_gb: 0.0,
            gpu_core_count: 0,
            memory_bandwidth_gbs: 0.0,
            tier: 0,
            gpu_backend: Some(format!("{:?}", GpuBackend::Cpu).to_lowercase()),
            platform: Some("gateway".into()),
            gpu_vram_gb: None,
        },
        loaded_models: vec![],
        max_model_size_gb: 0.0,
        is_available: true,
        ptn_ids: None,
        swappable_models: vec![],
        max_concurrent_requests: Some(0),
        effective_context: None,
        on_ac_power: None,
        backend_slots_busy: None,
        backend_slots_total: None,
    };
    let signature = identity.sign_node_id();
    serde_json::json!({
        "register": {
            "nodeID": identity.node_id(),
            "publicKey": identity.public_key_hex(),
            "displayName": display_name,
            "capabilities": caps,
            "signature": signature,
        }
    })
    .to_string()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::config::ReliabilityConfig;

    #[tokio::test]
    async fn ghost_session_chunk_draws_one_relay_close() {
        let registry = Registry::new(ReliabilityConfig::default());
        let sessions: Arc<DashMap<String, PendingSession>> = Arc::new(DashMap::new());
        let ghost_closes: Arc<DashMap<String, Instant>> = Arc::new(DashMap::new());
        let (outbox, mut rx) = mpsc::unbounded_channel();
        let relay = RelayHandle {
            node_id: "gw".to_string(),
            sessions: sessions.clone(),
            ready_waiters: Default::default(),
            outbox,
        };
        let ghost_chunk = || {
            ClusterMessage::InferenceChunk(teale_protocol::InferenceChunkPayload {
                request_id: "req-x".to_string(),
                chunk: serde_json::json!({"text": "hi"}),
            })
        };

        // Unknown session: ghost - exactly one relayClose back to the node.
        dispatch_cluster(
            ghost_chunk(),
            &sessions,
            &registry,
            "ghost-s1",
            "node-a",
            &relay,
            &ghost_closes,
        )
        .await;
        let Some(Message::Text(text)) = rx.try_recv().ok() else {
            panic!("expected one relayClose frame")
        };
        assert!(text.contains("relayClose"));
        assert!(text.contains("ghost-s1"));
        assert!(text.contains("node-a"));

        // Same ghost streams on: throttled, no per-chunk closes.
        dispatch_cluster(
            ghost_chunk(),
            &sessions,
            &registry,
            "ghost-s1",
            "node-a",
            &relay,
            &ghost_closes,
        )
        .await;
        assert!(rx.try_recv().is_err(), "no second close for the same ghost");

        // Known session: chunk delivered to the session channel, no close.
        let (chunks_tx, mut chunks_rx) = mpsc::channel(8);
        sessions.insert(
            "live-s1".to_string(),
            PendingSession {
                request_id: "req-1".to_string(),
                device_node_id: "node-a".to_string(),
                session_id: "live-s1".to_string(),
                chunks_tx,
            },
        );
        dispatch_cluster(
            ghost_chunk(),
            &sessions,
            &registry,
            "live-s1",
            "node-a",
            &relay,
            &ghost_closes,
        )
        .await;
        assert!(matches!(chunks_rx.try_recv(), Ok(SessionEvent::Chunk(_))));
        assert!(rx.try_recv().is_err(), "no close for a live session");
    }

    #[test]
    fn relay_idle_timeout_has_reasonable_floor_and_scale() {
        assert_eq!(relay_idle_timeout(1), Duration::from_secs(30));
        assert_eq!(relay_idle_timeout(5), Duration::from_secs(30));
        assert_eq!(relay_idle_timeout(10), Duration::from_secs(60));
    }

    fn caps(loaded_models: &[&str]) -> NodeCapabilities {
        NodeCapabilities {
            hardware: HardwareCapability {
                chip_family: "m3".to_string(),
                chip_name: "Apple M3".to_string(),
                total_ram_gb: 64.0,
                gpu_core_count: 40,
                memory_bandwidth_gbs: 300.0,
                tier: 1,
                gpu_backend: Some("metal".to_string()),
                platform: Some("macOS".to_string()),
                gpu_vram_gb: None,
            },
            loaded_models: loaded_models.iter().map(|m| m.to_string()).collect(),
            max_model_size_gb: 128.0,
            is_available: true,
            ptn_ids: None,
            swappable_models: Vec::new(),
            max_concurrent_requests: Some(2),
            effective_context: Some(131072),
            on_ac_power: Some(true),
            backend_slots_busy: None,
            backend_slots_total: None,
        }
    }

    #[test]
    fn extract_peer_node_id_parses_peer_not_found_message() {
        assert_eq!(
            extract_peer_node_id("Peer abc123 is not connected"),
            Some("abc123")
        );
        assert_eq!(extract_peer_node_id("something else"), None);
    }

    #[tokio::test]
    async fn peer_not_found_fails_waiters_and_inflight_sessions() {
        let registry = Registry::new(ReliabilityConfig::default());
        registry.upsert_device("node-a".to_string(), "A".to_string(), caps(&["teale/auto"]));

        let (waiter_tx, waiter_rx) = oneshot::channel();
        let ready_waiters = Arc::new(Mutex::new(HashMap::from([(
            "session-open".to_string(),
            ReadyWaiter {
                target_node_id: "node-a".to_string(),
                tx: waiter_tx,
            },
        )])));

        let (chunks_tx, mut chunks_rx) = mpsc::channel(8);
        let sessions = Arc::new(DashMap::new());
        sessions.insert(
            "session-active".to_string(),
            PendingSession {
                request_id: "req-1".to_string(),
                device_node_id: "node-a".to_string(),
                session_id: "session-active".to_string(),
                chunks_tx,
            },
        );

        let mut sent_discover_after_ack = false;
        handle_incoming(
            IncomingRelayMessage::Error(teale_protocol::RelayErrorPayload {
                code: "peer_not_found".to_string(),
                message: "Peer node-a is not connected".to_string(),
                retry_after_seconds: None,
            }),
            &registry,
            &sessions,
            &ready_waiters,
            60,
            &crate::config::FleetConfig::default(),
            &crate::config::ApmhelpConfig::default(),
            &mut sent_discover_after_ack,
            &RelayHandle::dummy_for_tests(),
            &Arc::new(DashMap::new()),
        )
        .await;

        let waiter_err = waiter_rx.await.expect("waiter should resolve");
        assert!(waiter_err.is_err());
        match chunks_rx.recv().await {
            Some(SessionEvent::Disconnect(reason)) => {
                assert!(reason.contains("peer not connected: node-a"));
            }
            other => panic!("expected disconnect, got {:?}", other),
        }
        assert!(ready_waiters.lock().is_empty());
        assert!(sessions.is_empty());
        let dev = registry
            .snapshot_devices()
            .into_iter()
            .find(|d| d.node_id == "node-a")
            .expect("device still tracked");
        assert!(dev.is_quarantined());
    }
}
