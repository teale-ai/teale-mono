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
use std::time::Duration;

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

#[derive(Clone, Default)]
struct SharedOutbox(Arc<Mutex<Option<mpsc::UnboundedSender<Message>>>>);

impl SharedOutbox {
    fn replace(&self, tx: mpsc::UnboundedSender<Message>) {
        *self.0.lock() = Some(tx);
    }

    fn clear(&self) {
        self.0.lock().take();
    }

    fn send(&self, msg: Message) -> anyhow::Result<()> {
        let tx = self
            .0
            .lock()
            .clone()
            .ok_or_else(|| anyhow::anyhow!("relay not connected"))?;
        tx.send(msg)
            .map_err(|_| anyhow::anyhow!("relay outbox closed"))?;
        Ok(())
    }
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
    ready_waiters: Arc<Mutex<HashMap<String, oneshot::Sender<()>>>>,
    outbox: SharedOutbox,
}

impl RelayHandle {
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
        let (tx, rx) = oneshot::channel::<()>();
        self.ready_waiters.lock().insert(session_id.clone(), tx);

        let payload = serde_json::json!({
            "relayOpen": {
                "fromNodeID": self.node_id,
                "toNodeID": target_node_id,
                "sessionID": session_id,
            }
        });
        self.send_json(&payload)?;

        match tokio::time::timeout(timeout, rx).await {
            Ok(Ok(())) => Ok(session_id),
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
        self.outbox.send(Message::Text(text.into()))
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
        let shared_outbox = SharedOutbox::default();
        shared_outbox.replace(outbox);
        Self {
            node_id: "test-node".into(),
            sessions: Arc::new(DashMap::new()),
            ready_waiters: Arc::new(Mutex::new(HashMap::new())),
            outbox: shared_outbox,
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
            .map(|tx| tx.send(()).is_ok())
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
    let sessions: Arc<DashMap<String, PendingSession>> = Arc::new(DashMap::new());
    let ready_waiters: Arc<Mutex<HashMap<String, oneshot::Sender<()>>>> =
        Arc::new(Mutex::new(HashMap::new()));
    let outbox = SharedOutbox::default();

    let handle = RelayHandle {
        node_id: node_id.clone(),
        sessions: sessions.clone(),
        ready_waiters: ready_waiters.clone(),
        outbox: outbox.clone(),
    };

    let connection_task = {
        let relay_url = config.relay.url.clone();
        let identity = identity.clone();
        let registry = registry.clone();
        let display_name = config.display_name.clone();
        let sessions = sessions.clone();
        let ready_waiters = ready_waiters.clone();
        let outbox = outbox.clone();
        let _reliability = config.reliability.clone();

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

                        // writer task
                        let (local_outbox_tx, mut local_outbox_rx) =
                            mpsc::unbounded_channel::<Message>();
                        outbox.replace(local_outbox_tx.clone());
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
                        if let Err(e) = local_outbox_tx.send(Message::Text(register_payload.into()))
                        {
                            warn!("send register: {}", e);
                        }

                        // reader loop: every incoming message until close.
                        let mut reader = read;
                        let mut sent_discover_after_ack = false;
                        loop {
                            let result = reader.next().await;
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
                                        &node_id,
                                        &mut sent_discover_after_ack,
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
                                                &node_id,
                                                &mut sent_discover_after_ack,
                                            )
                                            .await;
                                        }
                                    }
                                }
                                Ok(Message::Ping(d)) => {
                                    let _ = local_outbox_tx.send(Message::Pong(d));
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

                        outbox.clear();
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

async fn handle_incoming(
    msg: IncomingRelayMessage,
    registry: &Arc<Registry>,
    sessions: &Arc<DashMap<String, PendingSession>>,
    ready_waiters: &Arc<Mutex<HashMap<String, oneshot::Sender<()>>>>,
    _self_node_id: &str,
    sent_discover_after_ack: &mut bool,
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
                let caps = match serde_json::from_value::<NodeCapabilities>(caps_json.clone()) {
                    Ok(c) => c,
                    Err(e) => {
                        debug!(node = node_id, "capabilities parse failed: {}", e);
                        continue;
                    }
                };
                registry.upsert_device(node_id.to_string(), display_name, caps);
            }
            update_eligible_gauges(registry);
        }
        IncomingRelayMessage::PeerJoined(p) => {
            debug!(node = p.node_id, "peerJoined");
            // A full capability update will arrive on the next discover.
        }
        IncomingRelayMessage::PeerLeft(p) => {
            info!(node = p.node_id, "peerLeft");
            registry.remove_device(&p.node_id);
            update_eligible_gauges(registry);
        }
        IncomingRelayMessage::RelayReady(s) => {
            if let Some(tx) = ready_waiters.lock().remove(&s.session_id) {
                let _ = tx.send(());
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
            dispatch_cluster(msg, sessions, registry, &d.session_id, &d.from_node_id).await;
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
        }
        IncomingRelayMessage::Unknown(k) => {
            debug!("unknown relay msg: {}", k);
        }
        _ => {}
    }
}

async fn dispatch_cluster(
    msg: ClusterMessage,
    sessions: &Arc<DashMap<String, PendingSession>>,
    registry: &Arc<Registry>,
    session_id: &str,
    from_node_id: &str,
) {
    match msg {
        ClusterMessage::InferenceChunk(p) => {
            if let Some(entry) = sessions.get(session_id) {
                let _ = entry.chunks_tx.try_send(SessionEvent::Chunk(p.chunk));
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
    let mut per_model: std::collections::HashMap<String, u32> = std::collections::HashMap::new();
    for dev in registry.snapshot_devices() {
        for m in &dev.capabilities.loaded_models {
            *per_model.entry(m.clone()).or_insert(0) += 1;
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

    #[test]
    fn shared_outbox_tracks_the_current_connection() {
        let outbox = SharedOutbox::default();
        assert!(outbox.send(Message::Text("before-connect".into())).is_err());

        let (tx1, mut rx1) = mpsc::unbounded_channel();
        outbox.replace(tx1);
        outbox
            .send(Message::Text("first-connection".into()))
            .unwrap();
        let first = rx1.try_recv().unwrap();
        assert!(matches!(first, Message::Text(text) if text.as_str() == "first-connection"));

        outbox.clear();
        assert!(outbox
            .send(Message::Text("after-disconnect".into()))
            .is_err());

        let (tx2, mut rx2) = mpsc::unbounded_channel();
        outbox.replace(tx2);
        outbox
            .send(Message::Text("second-connection".into()))
            .unwrap();
        let second = rx2.try_recv().unwrap();
        assert!(matches!(second, Message::Text(text) if text.as_str() == "second-connection"));
    }
}
