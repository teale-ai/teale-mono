//! WebSocket client for the TealeNet relay.
//!
//! Protocol types live in `teale_protocol::relay`. This file is the node's
//! WS transport, register/discover helpers, and ping/keepalive logic.

use std::time::Duration;

use futures_util::{SinkExt, StreamExt};
use serde_json::Value;
use tokio::sync::mpsc;
use tokio_tungstenite::{connect_async, tungstenite::Error as WsError, tungstenite::Message};
use tracing::{error, info, warn};

use teale_protocol::{IncomingRelayMessage, NodeCapabilities};

pub use teale_protocol::RelayDataPayload;

use crate::identity::NodeIdentity;

/// The relay WebSocket handshake failed. Carries the server's `Retry-After`
/// (HTTP 429/503 during the upgrade) so the reconnect loop can honour it.
#[derive(Debug)]
pub struct RelayConnectError {
    pub message: String,
    pub retry_after: Option<Duration>,
}

impl std::fmt::Display for RelayConnectError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.message)
    }
}

impl std::error::Error for RelayConnectError {}

/// `Retry-After` in delta-seconds form, capped at 10 minutes. HTTP-date
/// values are ignored (the relay only ever sends seconds).
fn parse_retry_after(value: &str) -> Option<Duration> {
    let seconds = value.trim().parse::<u64>().ok()?;
    Some(Duration::from_secs(seconds.min(600)))
}

fn connect_error(error: WsError) -> RelayConnectError {
    let header = match &error {
        WsError::Http(response) => response.headers().get("retry-after").cloned(),
        _ => None,
    };
    let retry_after = header
        .as_ref()
        .and_then(|value| value.to_str().ok())
        .and_then(parse_retry_after);
    RelayConnectError {
        message: format!("WebSocket connect failed: {error}"),
        retry_after,
    }
}

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
        let connected = connect_async(&url_with_node).await;
        let (ws_stream, _) = connected.map_err(connect_error)?;
        info!("Connected to relay");

        let (write, read) = ws_stream.split();

        let (write_tx, mut write_rx) = mpsc::unbounded_channel::<Message>();
        let (incoming_tx, incoming_rx) = mpsc::unbounded_channel::<IncomingRelayMessage>();

        // Write task: forward outgoing messages to WebSocket
        tokio::spawn(async move {
            let mut write = write;
            while let Some(msg) = write_rx.recv().await {
                if let Err(e) = write.send(msg).await {
                    // Send-after-close family: a write that races a session or
                    // socket close inside the reconnect window lands on an
                    // already-closed handle. The read side and the next
                    // cadence register prove the connection's liveness, so a
                    // close-race io error (broken pipe/reset/abort) is not an
                    // outage - log it as a warning instead of a false ERROR.
                    // Control flow is unchanged: any write failure still ends
                    // the write task and the reconnect path owns recovery.
                    let close_race = matches!(&e, WsError::Io(io_err) if matches!(
                        io_err.kind(),
                        std::io::ErrorKind::BrokenPipe
                            | std::io::ErrorKind::ConnectionReset
                            | std::io::ErrorKind::ConnectionAborted
                    ));
                    if close_race {
                        warn!(
                            "WebSocket write raced a close ({}); reconnect path owns recovery",
                            e
                        );
                    } else {
                        error!("WebSocket write error: {}", e);
                    }
                    break;
                }
            }
        });

        // Read task
        let ping_tx = write_tx.clone();
        let ready_tx = write_tx.clone();
        let ready_node_id = node_id.clone();
        tokio::spawn(async move {
            let mut read = read;
            while let Some(result) = read.next().await {
                match result {
                    Ok(Message::Text(text)) => {
                        if let Some(msg) = IncomingRelayMessage::parse(&text) {
                            // Answer RelayOpen inline, from the read task. The
                            // main loop can sit behind a long inference (#229)
                            // while the gateway's relayReady deadline is 4s -
                            // a control-plane reply must not queue behind
                            // inference, or concurrent session opens time out
                            // with "relay open: timeout waiting for relayReady"
                            // on an otherwise healthy node. Forwarding to the
                            // main loop continues below, so session
                            // bookkeeping/logging is unchanged and channel
                            // order (open before its data) is preserved.
                            if let IncomingRelayMessage::RelayOpen(ref session) = msg {
                                let ready = serde_json::json!({
                                    "relayReady": {
                                        "fromNodeID": ready_node_id,
                                        "toNodeID": session.from_node_id,
                                        "sessionID": session.session_id,
                                    }
                                });
                                if ready_tx.send(Message::Text(ready.to_string())).is_err() {
                                    break;
                                }
                            }
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
                if ping_write_tx.send(Message::Ping(vec![])).is_err() {
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
            .send(Message::Text(text))
            .map_err(|_| anyhow::anyhow!("WebSocket channel closed"))?;
        Ok(())
    }

    pub fn register(
        &self,
        identity: &NodeIdentity,
        display_name: &str,
        capabilities: &NodeCapabilities,
    ) -> anyhow::Result<()> {
        self.register_signed(
            &identity.node_id(),
            &identity.public_key_hex(),
            display_name,
            capabilities,
            &identity.sign_node_id(),
        )
    }

    pub fn register_signed(
        &self,
        node_id: &str,
        public_key: &str,
        display_name: &str,
        capabilities: &NodeCapabilities,
        signature: &str,
    ) -> anyhow::Result<()> {
        let payload = serde_json::json!({
            "register": {
                "nodeID": node_id,
                "publicKey": public_key,
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

#[cfg(test)]
mod tests {
    use super::parse_retry_after;
    use std::time::Duration;

    #[test]
    fn retry_after_parses_seconds_and_caps() {
        assert_eq!(parse_retry_after(" 30 "), Some(Duration::from_secs(30)));
        assert_eq!(parse_retry_after("86400"), Some(Duration::from_secs(600)));
        assert_eq!(parse_retry_after("Wed, 21 Oct 2015 07:28:00 GMT"), None);
    }
}
