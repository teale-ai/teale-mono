//! Relay wire protocol — the messages exchanged between a node (or gateway)
//! and the relay server at `wss://relay.teale.com/ws`.

use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::hardware::NodeCapabilities;

// ── Outgoing ────────────────────────────────────────────────────────

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

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RegisterPayload {
    #[serde(rename = "nodeID")]
    pub node_id: String,
    pub public_key: String,
    #[serde(default, skip_serializing_if = "Option::is_none", rename = "wgPublicKey")]
    pub wg_public_key: Option<String>,
    pub display_name: String,
    pub capabilities: NodeCapabilities,
    pub signature: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DiscoverPayload {
    #[serde(rename = "requestingNodeID")]
    pub requesting_node_id: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub filter: Option<DiscoverFilter>,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
pub struct DiscoverFilter {
    #[serde(default, skip_serializing_if = "Option::is_none", rename = "modelID")]
    pub model_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none", rename = "minRAMGB")]
    pub min_ram_gb: Option<f64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub min_tier: Option<u32>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RelaySessionPayload {
    // Swift encodes `nodeID`/`sessionID` with CAP-ID (Apple naming) rather
    // than default camelCase `nodeId`/`sessionId`. Keep these renames
    // explicit so the Rust side wire-matches the Mac app.
    #[serde(rename = "fromNodeID")]
    pub from_node_id: String,
    #[serde(rename = "toNodeID")]
    pub to_node_id: String,
    #[serde(rename = "sessionID")]
    pub session_id: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RelayDataPayload {
    #[serde(rename = "fromNodeID")]
    pub from_node_id: String,
    #[serde(rename = "toNodeID")]
    pub to_node_id: String,
    #[serde(rename = "sessionID")]
    pub session_id: String,
    /// Base64-encoded JSON ClusterMessage (Swift `Data` default encoding).
    pub data: Value,
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

// ── Incoming ────────────────────────────────────────────────────────

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

impl IncomingRelayMessage {
    pub fn parse(raw: &str) -> Option<Self> {
        let v: Value = serde_json::from_str(raw).ok()?;
        let obj = v.as_object()?;

        if let Some(payload) = obj.get("registerAck") {
            let node_id = payload.get("nodeID")?.as_str()?.to_string();
            return Some(Self::RegisterAck { node_id });
        }
        if let Some(payload) = obj.get("discoverResponse") {
            let peers = payload.get("peers")?.as_array()?.clone();
            return Some(Self::DiscoverResponse { peers });
        }
        if let Some(payload) = obj.get("relayOpen") {
            let p: RelaySessionPayload = serde_json::from_value(payload.clone()).ok()?;
            return Some(Self::RelayOpen(p));
        }
        if let Some(payload) = obj.get("relayReady") {
            let p: RelaySessionPayload = serde_json::from_value(payload.clone()).ok()?;
            return Some(Self::RelayReady(p));
        }
        if let Some(payload) = obj.get("relayData") {
            let p: RelayDataPayload = serde_json::from_value(payload.clone()).ok()?;
            return Some(Self::RelayData(p));
        }
        if let Some(payload) = obj.get("relayClose") {
            let p: RelaySessionPayload = serde_json::from_value(payload.clone()).ok()?;
            return Some(Self::RelayClose(p));
        }
        if let Some(payload) = obj.get("peerJoined") {
            let p: PeerNotificationPayload = serde_json::from_value(payload.clone()).ok()?;
            return Some(Self::PeerJoined(p));
        }
        if let Some(payload) = obj.get("peerLeft") {
            let p: PeerNotificationPayload = serde_json::from_value(payload.clone()).ok()?;
            return Some(Self::PeerLeft(p));
        }
        if let Some(payload) = obj.get("error") {
            let p: RelayErrorPayload = serde_json::from_value(payload.clone()).ok()?;
            return Some(Self::Error(p));
        }

        let kind = obj.keys().next()?.to_string();
        Some(Self::Unknown(kind))
    }
}
