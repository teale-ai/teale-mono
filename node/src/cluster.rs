use base64::Engine;
use serde::{Deserialize, Serialize};
use serde_json::Value;
use tracing::{error, info, warn};

use crate::backend::Backend;
use crate::relay::{RelayClient, RelayDataPayload};

/// Decode the `data` field from a relayData payload.
/// Swift encodes `Data` as base64 by default in JSON.
pub fn decode_relay_data(data_value: &Value) -> Option<Vec<u8>> {
    match data_value {
        Value::String(s) => {
            // Try base64 first (Swift's default Data encoding)
            if let Ok(bytes) = base64::engine::general_purpose::STANDARD.decode(s) {
                return Some(bytes);
            }
            // Maybe it's raw JSON string
            Some(s.as_bytes().to_vec())
        }
        Value::Array(arr) => {
            // Could be byte array [1, 2, 3, ...]
            let bytes: Option<Vec<u8>> = arr.iter().map(|v| v.as_u64().map(|n| n as u8)).collect();
            bytes
        }
        _ => None,
    }
}

/// Parse a ClusterMessage from JSON bytes.
pub fn parse_cluster_message(data: &[u8]) -> Option<ClusterMessageKind> {
    let v: Value = serde_json::from_slice(data).ok()?;
    let obj = v.as_object()?;

    if obj.contains_key("hello") {
        return Some(ClusterMessageKind::Hello(v.clone()));
    }
    if obj.contains_key("helloAck") {
        return Some(ClusterMessageKind::HelloAck);
    }
    if obj.contains_key("heartbeat") {
        return Some(ClusterMessageKind::Heartbeat(v.clone()));
    }
    if obj.contains_key("heartbeatAck") {
        return Some(ClusterMessageKind::HeartbeatAck);
    }
    if let Some(payload) = obj.get("inferenceRequest") {
        let p: InferenceRequestPayload = serde_json::from_value(payload.clone()).ok()?;
        return Some(ClusterMessageKind::InferenceRequest(p));
    }
    if let Some(_) = obj.get("inferenceChunk") {
        return Some(ClusterMessageKind::InferenceChunk);
    }
    if let Some(_) = obj.get("inferenceComplete") {
        return Some(ClusterMessageKind::InferenceComplete);
    }
    if let Some(_) = obj.get("inferenceError") {
        return Some(ClusterMessageKind::InferenceError);
    }

    let kind = obj.keys().next()?.to_string();
    Some(ClusterMessageKind::Unknown(kind))
}

#[derive(Debug)]
pub enum ClusterMessageKind {
    Hello(Value),
    HelloAck,
    Heartbeat(Value),
    HeartbeatAck,
    InferenceRequest(InferenceRequestPayload),
    InferenceChunk,
    InferenceComplete,
    InferenceError,
    Unknown(String),
}

// ── Inference payloads ──

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct InferenceRequestPayload {
    #[serde(rename = "requestID")]
    pub request_id: String,
    pub request: ChatCompletionRequest,
    #[serde(default)]
    pub streaming: bool,
}

#[derive(Debug, Clone, Deserialize, Serialize)]
pub struct ChatCompletionRequest {
    pub model: Option<String>,
    pub messages: Vec<ApiMessage>,
    pub temperature: Option<f64>,
    pub top_p: Option<f64>,
    pub max_tokens: Option<u32>,
    pub stream: Option<bool>,
    pub stop: Option<Vec<String>>,
    pub presence_penalty: Option<f64>,
    pub frequency_penalty: Option<f64>,
}

#[derive(Debug, Clone, Deserialize, Serialize)]
pub struct ApiMessage {
    pub role: String,
    pub content: String,
}

/// Handle a relayData message: decode, parse ClusterMessage, process.
pub async fn handle_relay_data(
    relay: &RelayClient,
    payload: &RelayDataPayload,
    inference: &Backend,
    device_info_json: &Value,
) {
    let data_bytes = match decode_relay_data(&payload.data) {
        Some(b) => b,
        None => {
            warn!("Failed to decode relay data from {}", &payload.from_node_id[..16.min(payload.from_node_id.len())]);
            return;
        }
    };

    let message = match parse_cluster_message(&data_bytes) {
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
        ClusterMessageKind::Hello(_) => {
            info!("Received hello from {}, sending helloAck", &from[..16.min(from.len())]);
            let ack = serde_json::json!({
                "helloAck": {
                    "deviceInfo": device_info_json,
                    "protocolVersion": 1,
                    "loadedModels": inference.loaded_models()
                }
            });
            send_cluster_message(relay, from, session, &ack);
        }

        ClusterMessageKind::Heartbeat(_) => {
            let ack = serde_json::json!({
                "heartbeatAck": {
                    "deviceID": uuid::Uuid::new_v4().to_string(),
                    "timestamp": crate::relay::now_reference_seconds(),
                    "thermalLevel": "nominal",
                    "throttleLevel": 100,
                    "loadedModels": inference.loaded_models(),
                    "isGenerating": false,
                    "queueDepth": 0
                }
            });
            send_cluster_message(relay, from, session, &ack);
        }

        ClusterMessageKind::InferenceRequest(req) => {
            info!("Inference request {} from {}", &req.request_id, &from[..16.min(from.len())]);
            handle_inference_request(relay, from, session, req, inference).await;
        }

        ClusterMessageKind::Unknown(kind) => {
            info!("Ignoring unknown cluster message type: {}", kind);
        }

        _ => {
            // HelloAck, HeartbeatAck, InferenceChunk/Complete/Error are responses — we don't expect them as a supply node
        }
    }
}

async fn handle_inference_request(
    relay: &RelayClient,
    from: &str,
    session: &str,
    req: InferenceRequestPayload,
    inference: &Backend,
) {
    let request_id = &req.request_id;

    match inference.stream_completion(&req.request).await {
        Ok(mut rx) => {
            while let Some(chunk_json) = rx.recv().await {
                let msg = serde_json::json!({
                    "inferenceChunk": {
                        "requestID": request_id,
                        "chunk": chunk_json
                    }
                });
                send_cluster_message(relay, from, session, &msg);
            }

            let complete = serde_json::json!({
                "inferenceComplete": {
                    "requestID": request_id
                }
            });
            send_cluster_message(relay, from, session, &complete);
            info!("Inference request {} completed", request_id);
        }
        Err(e) => {
            error!("Inference error for {}: {}", request_id, e);
            let err_msg = serde_json::json!({
                "inferenceError": {
                    "requestID": request_id,
                    "errorMessage": e.to_string()
                }
            });
            send_cluster_message(relay, from, session, &err_msg);
        }
    }
}

fn send_cluster_message(relay: &RelayClient, to_node_id: &str, session_id: &str, message: &Value) {
    let json_bytes = serde_json::to_vec(message).unwrap_or_default();
    if let Err(e) = relay.send_relay_data(to_node_id, session_id, &json_bytes) {
        error!("Failed to send cluster message: {}", e);
    }
}

pub use crate::relay::now_reference_seconds;
