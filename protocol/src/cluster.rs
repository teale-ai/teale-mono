//! Cluster message types — carried inside `relayData.data` (base64-encoded JSON).
//! These are the node-to-node messages that carry inference requests and results.

use base64::Engine;
use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::openai::ChatCompletionRequest;

/// Top-level cluster message. Encoded as a JSON object with exactly one
/// top-level key naming the variant (matches Swift's Codable union encoding).
///
/// `InferenceRequest` carries a full `ChatCompletionRequest` (~320 bytes);
/// box it so the enum's size isn't dominated by a single variant.
#[derive(Debug, Clone)]
pub enum ClusterMessage {
    Hello(HelloPayload),
    HelloAck(HelloAckPayload),
    Heartbeat(HeartbeatPayload),
    HeartbeatAck(HeartbeatPayload),
    InferenceRequest(Box<InferenceRequestPayload>),
    InferenceChunk(InferenceChunkPayload),
    InferenceComplete(InferenceCompletePayload),
    InferenceError(InferenceErrorPayload),
    LoadModel(LoadModelPayload),
    ModelLoaded(ModelLoadedPayload),
    ModelLoadError(ModelLoadErrorPayload),
    Unknown { kind: String, raw: Value },
}

impl ClusterMessage {
    /// Parse a ClusterMessage from JSON bytes.
    pub fn parse(data: &[u8]) -> Option<Self> {
        let v: Value = serde_json::from_slice(data).ok()?;
        Self::from_value(&v)
    }

    pub fn from_value(v: &Value) -> Option<Self> {
        let obj = v.as_object()?;

        // Mac-app's ClusterMessage uses default Swift Codable, which
        // serializes `enum Foo { case bar(Payload) }` as
        // `{"bar": {"_0": {...payload...}}}`. Unwrap that extra `_0` here
        // so the Rust side can deserialize the payload directly.
        // Rust-origin messages (from the gateway) don't have the wrapper;
        // tolerate both shapes.
        let unwrap_0 = |p: &Value| -> Value { p.get("_0").cloned().unwrap_or_else(|| p.clone()) };

        macro_rules! try_variant {
            ($key:expr, $payload:ty, $variant:ident) => {
                if let Some(p) = obj.get($key) {
                    let inner = unwrap_0(p);
                    if let Ok(parsed) = serde_json::from_value::<$payload>(inner) {
                        return Some(Self::$variant(parsed));
                    }
                }
            };
            (boxed $key:expr, $payload:ty, $variant:ident) => {
                if let Some(p) = obj.get($key) {
                    let inner = unwrap_0(p);
                    if let Ok(parsed) = serde_json::from_value::<$payload>(inner) {
                        return Some(Self::$variant(Box::new(parsed)));
                    }
                }
            };
        }

        try_variant!("hello", HelloPayload, Hello);
        try_variant!("helloAck", HelloAckPayload, HelloAck);
        try_variant!("heartbeat", HeartbeatPayload, Heartbeat);
        try_variant!("heartbeatAck", HeartbeatPayload, HeartbeatAck);
        try_variant!(
            boxed
            "inferenceRequest",
            InferenceRequestPayload,
            InferenceRequest
        );
        try_variant!("inferenceChunk", InferenceChunkPayload, InferenceChunk);
        try_variant!(
            "inferenceComplete",
            InferenceCompletePayload,
            InferenceComplete
        );
        try_variant!("inferenceError", InferenceErrorPayload, InferenceError);
        try_variant!("loadModel", LoadModelPayload, LoadModel);
        try_variant!("modelLoaded", ModelLoadedPayload, ModelLoaded);
        try_variant!("modelLoadError", ModelLoadErrorPayload, ModelLoadError);

        let kind = obj.keys().next()?.to_string();
        Some(Self::Unknown {
            kind,
            raw: v.clone(),
        })
    }

    /// Serialize to the wire-format JSON Value.
    ///
    /// Wrapping each payload in `_0` matches Swift's default Codable
    /// encoding for `enum Case(Payload)`, so messages we emit round-trip
    /// with the Mac app's `ClusterMessage` (which uses default Codable).
    pub fn to_value(&self) -> Value {
        match self {
            Self::Hello(p) => serde_json::json!({ "hello": { "_0": p } }),
            Self::HelloAck(p) => serde_json::json!({ "helloAck": { "_0": p } }),
            Self::Heartbeat(p) => serde_json::json!({ "heartbeat": { "_0": p } }),
            Self::HeartbeatAck(p) => serde_json::json!({ "heartbeatAck": { "_0": p } }),
            Self::InferenceRequest(p) => serde_json::json!({ "inferenceRequest": { "_0": p } }),
            Self::InferenceChunk(p) => serde_json::json!({ "inferenceChunk": { "_0": p } }),
            Self::InferenceComplete(p) => serde_json::json!({ "inferenceComplete": { "_0": p } }),
            Self::InferenceError(p) => serde_json::json!({ "inferenceError": { "_0": p } }),
            Self::LoadModel(p) => serde_json::json!({ "loadModel": { "_0": p } }),
            Self::ModelLoaded(p) => serde_json::json!({ "modelLoaded": { "_0": p } }),
            Self::ModelLoadError(p) => serde_json::json!({ "modelLoadError": { "_0": p } }),
            Self::Unknown { raw, .. } => raw.clone(),
        }
    }
}

/// Decode the `data` field from a relayData payload. Handles both
/// Swift's default base64-string encoding and raw-JSON fallback.
pub fn decode_relay_data(data_value: &Value) -> Option<Vec<u8>> {
    match data_value {
        Value::String(s) => {
            if let Ok(bytes) = base64::engine::general_purpose::STANDARD.decode(s) {
                return Some(bytes);
            }
            Some(s.as_bytes().to_vec())
        }
        Value::Array(arr) => arr.iter().map(|v| v.as_u64().map(|n| n as u8)).collect(),
        _ => None,
    }
}

// ── Payloads ────────────────────────────────────────────────────────

#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct HelloPayload {
    pub device_info: Value,
    pub protocol_version: u32,
    #[serde(default)]
    pub loaded_models: Vec<String>,
}

#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct HelloAckPayload {
    pub device_info: Value,
    pub protocol_version: u32,
    #[serde(default)]
    pub loaded_models: Vec<String>,
}

#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct HeartbeatPayload {
    #[serde(rename = "deviceID")]
    pub device_id: String,
    pub timestamp: f64,
    pub thermal_level: ThermalLevel,
    pub throttle_level: u32,
    #[serde(default)]
    pub loaded_models: Vec<String>,
    #[serde(default)]
    pub is_generating: bool,
    #[serde(default)]
    pub queue_depth: u32,
    /// EWMA of tokens-per-second observed locally. Used by gateway scheduler.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub ewma_tokens_per_second: Option<f64>,
}

#[derive(Debug, Clone, Copy, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum ThermalLevel {
    Nominal,
    Fair,
    Serious,
    Critical,
}

impl ThermalLevel {
    /// Weight factor for scheduler (0.0–1.0). Serious/Critical route less traffic.
    pub fn weight(self) -> f64 {
        match self {
            Self::Nominal => 1.0,
            Self::Fair => 0.8,
            Self::Serious => 0.3,
            Self::Critical => 0.0,
        }
    }
}

// ── Inference flow ──

#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct InferenceRequestPayload {
    #[serde(rename = "requestID")]
    pub request_id: String,
    pub request: ChatCompletionRequest,
    #[serde(default)]
    pub streaming: bool,
}

#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct InferenceChunkPayload {
    #[serde(rename = "requestID")]
    pub request_id: String,
    pub chunk: Value,
}

#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct InferenceCompletePayload {
    #[serde(rename = "requestID")]
    pub request_id: String,
    /// Optional token counts for metering.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub tokens_in: Option<u32>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub tokens_out: Option<u32>,
}

#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct InferenceErrorPayload {
    #[serde(rename = "requestID")]
    pub request_id: String,
    pub error_message: String,
    /// Typed error code so gateway can route intelligently.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub code: Option<InferenceErrorCode>,
}

#[derive(Debug, Clone, Copy, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum InferenceErrorCode {
    ModelNotLoaded,
    QueueFull,
    Unavailable,
    InternalError,
    Timeout,
    Cancelled,
}

// ── Model-swap protocol (Phase C, Ultra-only) ──

#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct LoadModelPayload {
    #[serde(rename = "requestID")]
    pub request_id: String,
    #[serde(rename = "modelID")]
    pub model_id: String,
}

#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ModelLoadedPayload {
    #[serde(rename = "requestID")]
    pub request_id: String,
    #[serde(rename = "modelID")]
    pub model_id: String,
    pub load_time_ms: u64,
}

#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ModelLoadErrorPayload {
    #[serde(rename = "requestID")]
    pub request_id: String,
    #[serde(rename = "modelID")]
    pub model_id: String,
    pub reason: String,
}
