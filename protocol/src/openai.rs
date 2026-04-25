//! OpenAI-compatible request/response types.

use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Deserialize, Serialize)]
pub struct ChatCompletionRequest {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub model: Option<String>,
    pub messages: Vec<ApiMessage>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub temperature: Option<f64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub top_p: Option<f64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub max_tokens: Option<u32>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub stream: Option<bool>,
    /// OpenAI-style `stream_options`. When `include_usage=true`, the upstream
    /// emits a final chunk carrying a `usage` object — required by OpenRouter.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub stream_options: Option<serde_json::Value>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub stop: Option<Vec<String>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub presence_penalty: Option<f64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub frequency_penalty: Option<f64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub tools: Option<serde_json::Value>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub tool_choice: Option<serde_json::Value>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub response_format: Option<serde_json::Value>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub seed: Option<i64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub user: Option<String>,
}

#[derive(Debug, Clone, Deserialize, Serialize)]
pub struct ApiMessage {
    pub role: String,
    pub content: serde_json::Value,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub name: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub tool_calls: Option<serde_json::Value>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub tool_call_id: Option<String>,
}

/// OpenAI `/v1/models` response shape.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ModelsResponse {
    pub object: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub connected_device_count: Option<u32>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub total_ram_gb: Option<f64>,
    pub data: Vec<ModelEntry>,
}

/// One entry in the `/v1/models` catalog.
/// Matches OpenAI's schema plus OpenRouter-compatible extensions.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ModelEntry {
    pub id: String,
    pub object: String,
    pub created: u64,
    pub owned_by: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub context_length: Option<u32>,
    /// Max output tokens we will accept for `max_tokens` on this model.
    /// OpenRouter's provider form explicitly requires this field on /models.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub max_output_tokens: Option<u32>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub pricing: Option<Pricing>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub supported_parameters: Option<Vec<String>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub quantization: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub description: Option<String>,
    /// Healthy devices that currently have this model loaded.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub loaded_device_count: Option<u32>,
    /// Rolling per-model serving stats (TTFT + TPS averages and percentiles).
    /// Absent when no recent successful completions for this model are in the window.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub metrics: Option<ModelMetrics>,
}

/// Per-model serving stats surfaced on `/v1/models` entries and the
/// `/try/:token` landing pages so clients can compare latency/throughput.
/// Averages and percentiles are computed over a sliding window of recent successful
/// completions (size controlled by the gateway).
#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct ModelMetrics {
    /// Time-to-first-token in milliseconds.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub ttft_ms_avg: Option<u32>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub ttft_ms_p50: Option<u32>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub ttft_ms_p95: Option<u32>,
    /// Tokens per second during the generation phase (first token → last token).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub tps_avg: Option<f32>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub tps_p50: Option<f32>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub tps_p95: Option<f32>,
    /// Samples contributing to the rolling stats above.
    pub sample_count: u32,
    /// Age of the freshest sample in seconds — lets clients detect stale data.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub last_sample_age_seconds: Option<u32>,
    /// Sliding-window size in seconds.
    pub window_seconds: u32,
}

/// Per-1-token prices (stringified because OpenAI/OpenRouter quote them that way).
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Pricing {
    pub prompt: String,
    pub completion: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub request: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub image: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub input_cache_read: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub input_cache_write: Option<String>,
}
