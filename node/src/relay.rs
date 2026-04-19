//! WebSocket client for the TealeNet relay.
//!
//! Protocol types live in `teale_protocol::relay`. This file is the node's
//! WS transport, register/discover helpers, and ping/keepalive logic.

use futures_util::{SinkExt, StreamExt};
use serde_json::Value;
use tokio::sync::mpsc;
use tokio_tungstenite::{connect_async, tungstenite::Message};
use tracing::{error, info};

use teale_protocol::{IncomingRelayMessage, NodeCapabilities};

pub use teale_protocol::{now_reference_seconds, RelayDataPayload, RelaySessionPayload};

use crate::identity::NodeIdentity;

#[derive(Clone)]
pub struct RelayClient {
    node_id: String,
    #[allow(dead_code)]
    relay_url: String,
    write_tx: mpsc::UnboundedSender<Message>,
}

impl RelayClient {
    /// Connect to relay. Returns (client, receiver for incoming messages).
    pub async fn connect(
        relay_url: &str,
        identity: &NodeIdentity,
    ) -> anyhow::Result<(Self, mpsc::UnboundedReceiver<IncomingRelayMessage>)> {
        let node_id = identity.node_id();
        let url_with_node = format!("{}?node={}", relay_url, node_id);

        info!("Connecting to relay: {}", relay_url);
        let (ws_stream, _) = connect_async(&url_with_node)
            .await
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

        // Read task
        let ping_tx = write_tx.clone();
        tokio::spawn(async move {
            let mut read = read;
            while let Some(result) = read.next().await {
                match result {
                    Ok(Message::Text(text)) => {
                        if let Some(msg) = IncomingRelayMessage::parse(&text) {
                            if incoming_tx.send(msg).is_err() {
                                break;
                            }
                        }
                    }
                    Ok(Message::Binary(data)) => {
                        if let Ok(text) = String::from_utf8(data.to_vec()) {
                            if let Some(msg) = IncomingRelayMessage::parse(&text) {
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

        // Ping task: every 25s
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
        self.write_tx
            .send(Message::Text(text.into()))
            .map_err(|_| anyhow::anyhow!("WebSocket channel closed"))?;
        Ok(())
    }

    pub fn register(
        &self,
        identity: &NodeIdentity,
        display_name: &str,
        capabilities: &NodeCapabilities,
    ) -> anyhow::Result<()> {
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

    pub fn send_relay_data(
        &self,
        to_node_id: &str,
        session_id: &str,
        data: &[u8],
    ) -> anyhow::Result<()> {
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

    /// Send arbitrary cluster message (ClusterMessage wrapped in relayData).
    pub fn send_cluster_message(
        &self,
        to_node_id: &str,
        session_id: &str,
        message: &Value,
    ) -> anyhow::Result<()> {
        let json_bytes = serde_json::to_vec(message)?;
        self.send_relay_data(to_node_id, session_id, &json_bytes)
    }
}
