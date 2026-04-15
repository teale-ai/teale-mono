use futures_util::{SinkExt, StreamExt};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use tokio::sync::mpsc;
use tokio_tungstenite::{connect_async, tungstenite::Message};
use tracing::{error, info};

use crate::hardware::NodeCapabilities;
use crate::identity::NodeIdentity;

/// Apple reference date offset: seconds between Unix epoch and 2001-01-01.
const APPLE_REFERENCE_OFFSET: f64 = 978307200.0;

pub fn now_reference_seconds() -> f64 {
    let unix_secs = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_secs_f64();
    unix_secs - APPLE_REFERENCE_OFFSET
}

// ── Relay message types ──

#[derive(Debug, Clone, Serialize)]
#[serde(untagged)]
pub enum OutgoingRelayMessage {
    Register { register: RegisterPayload },
    Discover { discover: DiscoverPayload },
    RelayOpen { #[serde(rename = "relayOpen")] relay_open: RelaySessionPayload },
    RelayReady { #[serde(rename = "relayReady")] relay_ready: RelaySessionPayload },
    RelayData { #[serde(rename = "relayData")] relay_data: RelayDataPayload },
    RelayClose { #[serde(rename = "relayClose")] relay_close: RelaySessionPayload },
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct RegisterPayload {
    pub node_id: String,
    pub public_key: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub wg_public_key: Option<String>,
    pub display_name: String,
    pub capabilities: NodeCapabilities,
    pub signature: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DiscoverPayload {
    pub requesting_node_id: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RelaySessionPayload {
    pub from_node_id: String,
    pub to_node_id: String,
    pub session_id: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RelayDataPayload {
    pub from_node_id: String,
    pub to_node_id: String,
    pub session_id: String,
    pub data: serde_json::Value,  // base64-encoded bytes from Swift
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PeerNotificationPayload {
    #[serde(rename = "nodeID")]
    pub node_id: String,
    #[serde(rename = "displayName")]
    pub display_name: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RelayErrorPayload {
    pub code: String,
    pub message: String,
}

/// Parsed incoming relay message.
#[derive(Debug, Clone)]
pub enum IncomingRelayMessage {
    RegisterAck { node_id: String },
    DiscoverResponse { peers: Vec<Value> },
    RelayOpen(RelaySessionPayload),
    RelayReady(RelaySessionPayload),
    RelayData(RelayDataPayload),
    RelayClose(RelaySessionPayload),
    PeerJoined(PeerNotificationPayload),
    PeerLeft(PeerNotificationPayload),
    Error(RelayErrorPayload),
    Unknown(String),
}

fn parse_incoming(raw: &str) -> Option<IncomingRelayMessage> {
    let v: Value = serde_json::from_str(raw).ok()?;
    let obj = v.as_object()?;

    if let Some(payload) = obj.get("registerAck") {
        let node_id = payload.get("nodeID")?.as_str()?.to_string();
        return Some(IncomingRelayMessage::RegisterAck { node_id });
    }
    if let Some(payload) = obj.get("discoverResponse") {
        let peers = payload.get("peers")?.as_array()?.clone();
        return Some(IncomingRelayMessage::DiscoverResponse { peers });
    }
    if let Some(payload) = obj.get("relayOpen") {
        let p: RelaySessionPayload = serde_json::from_value(payload.clone()).ok()?;
        return Some(IncomingRelayMessage::RelayOpen(p));
    }
    if let Some(payload) = obj.get("relayReady") {
        let p: RelaySessionPayload = serde_json::from_value(payload.clone()).ok()?;
        return Some(IncomingRelayMessage::RelayReady(p));
    }
    if let Some(payload) = obj.get("relayData") {
        let p: RelayDataPayload = serde_json::from_value(payload.clone()).ok()?;
        return Some(IncomingRelayMessage::RelayData(p));
    }
    if let Some(payload) = obj.get("relayClose") {
        let p: RelaySessionPayload = serde_json::from_value(payload.clone()).ok()?;
        return Some(IncomingRelayMessage::RelayClose(p));
    }
    if let Some(payload) = obj.get("peerJoined") {
        let p: PeerNotificationPayload = serde_json::from_value(payload.clone()).ok()?;
        return Some(IncomingRelayMessage::PeerJoined(p));
    }
    if let Some(payload) = obj.get("peerLeft") {
        let p: PeerNotificationPayload = serde_json::from_value(payload.clone()).ok()?;
        return Some(IncomingRelayMessage::PeerLeft(p));
    }
    if let Some(payload) = obj.get("error") {
        let p: RelayErrorPayload = serde_json::from_value(payload.clone()).ok()?;
        return Some(IncomingRelayMessage::Error(p));
    }

    let kind = obj.keys().next()?.to_string();
    Some(IncomingRelayMessage::Unknown(kind))
}

// ── Relay Client ──

pub struct RelayClient {
    node_id: String,
    relay_url: String,
    write_tx: mpsc::UnboundedSender<Message>,
}

impl RelayClient {
    /// Connect to relay, returns (client, receiver for incoming messages).
    pub async fn connect(
        relay_url: &str,
        identity: &NodeIdentity,
    ) -> anyhow::Result<(Self, mpsc::UnboundedReceiver<IncomingRelayMessage>)> {
        let node_id = identity.node_id();
        let url_with_node = format!("{}?node={}", relay_url, node_id);

        info!("Connecting to relay: {}", relay_url);
        let (ws_stream, _) = connect_async(&url_with_node).await
            .map_err(|e| anyhow::anyhow!("WebSocket connect failed: {}", e))?;
        info!("Connected to relay");

        let (write, read) = ws_stream.split();

        let (write_tx, mut write_rx) = mpsc::unbounded_channel::<Message>();
        let (incoming_tx, incoming_rx) = mpsc::unbounded_channel::<IncomingRelayMessage>();

        // Write task: forward outgoing messages to WebSocket
        tokio::spawn(async move {
            let mut write = write;
            while let Some(msg) = write_rx.recv().await {
                if let Err(e) = write.send(msg).await {
                    error!("WebSocket write error: {}", e);
                    break;
                }
            }
        });

        // Read task: parse incoming messages and forward to channel
        let ping_tx = write_tx.clone();
        tokio::spawn(async move {
            let mut read = read;
            while let Some(result) = read.next().await {
                match result {
                    Ok(Message::Text(text)) => {
                        if let Some(msg) = parse_incoming(&text) {
                            if incoming_tx.send(msg).is_err() {
                                break;
                            }
                        }
                    }
                    Ok(Message::Binary(data)) => {
                        if let Ok(text) = String::from_utf8(data.to_vec()) {
                            if let Some(msg) = parse_incoming(&text) {
                                if incoming_tx.send(msg).is_err() {
                                    break;
                                }
                            }
                        }
                    }
                    Ok(Message::Ping(data)) => {
                        let _ = ping_tx.send(Message::Pong(data));
                    }
                    Ok(Message::Close(_)) => {
                        info!("WebSocket closed by server");
                        break;
                    }
                    Err(e) => {
                        error!("WebSocket read error: {}", e);
                        break;
                    }
                    _ => {}
                }
            }
        });

        // Ping task: send ping every 25s
        let ping_write_tx = write_tx.clone();
        tokio::spawn(async move {
            loop {
                tokio::time::sleep(tokio::time::Duration::from_secs(25)).await;
                if ping_write_tx.send(Message::Ping(vec![].into())).is_err() {
                    break;
                }
            }
        });

        Ok((
            Self {
                node_id,
                relay_url: relay_url.to_string(),
                write_tx,
            },
            incoming_rx,
        ))
    }

    pub fn node_id(&self) -> &str {
        &self.node_id
    }

    fn send_json(&self, value: &Value) -> anyhow::Result<()> {
        let text = serde_json::to_string(value)?;
        self.write_tx.send(Message::Text(text))
            .map_err(|_| anyhow::anyhow!("WebSocket channel closed"))?;
        Ok(())
    }

    pub fn register(&self, identity: &NodeIdentity, display_name: &str, capabilities: &NodeCapabilities) -> anyhow::Result<()> {
        let signature = identity.sign_node_id();

        let payload = serde_json::json!({
            "register": {
                "nodeID": identity.node_id(),
                "publicKey": identity.public_key_hex(),
                "displayName": display_name,
                "capabilities": capabilities,
                "signature": signature
            }
        });

        info!("Registering with relay as '{}'", display_name);
        self.send_json(&payload)
    }

    pub fn discover(&self) -> anyhow::Result<()> {
        let payload = serde_json::json!({
            "discover": {
                "requestingNodeID": self.node_id
            }
        });
        self.send_json(&payload)
    }

    pub fn send_relay_ready(&self, to_node_id: &str, session_id: &str) -> anyhow::Result<()> {
        let payload = serde_json::json!({
            "relayReady": {
                "fromNodeID": self.node_id,
                "toNodeID": to_node_id,
                "sessionID": session_id
            }
        });
        self.send_json(&payload)
    }

    pub fn send_relay_data(&self, to_node_id: &str, session_id: &str, data: &[u8]) -> anyhow::Result<()> {
        let encoded = base64::Engine::encode(&base64::engine::general_purpose::STANDARD, data);
        let payload = serde_json::json!({
            "relayData": {
                "fromNodeID": self.node_id,
                "toNodeID": to_node_id,
                "sessionID": session_id,
                "data": encoded
            }
        });
        self.send_json(&payload)
    }

    pub fn send_relay_close(&self, to_node_id: &str, session_id: &str) -> anyhow::Result<()> {
        let payload = serde_json::json!({
            "relayClose": {
                "fromNodeID": self.node_id,
                "toNodeID": to_node_id,
                "sessionID": session_id
            }
        });
        self.send_json(&payload)
    }
}
