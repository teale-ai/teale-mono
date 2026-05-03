//! `GET /v1/providers` — public-facing marketplace listing.
//!
//! Mirrors OpenRouter's `/v1/models` shape: each active provider plus its
//! model menu, prices, advertised features, and rolling health metrics.
//! Unauthenticated; safe to expose so the catalog page and `curl` users can
//! see who's serving what.

use axum::{extract::State, Json};
use serde::Serialize;
use serde_json::Value;

use crate::providers::health::HealthTier;
use crate::state::AppState;

#[derive(Debug, Serialize)]
pub struct ProviderEntry {
    pub slug: String,
    #[serde(rename = "displayName")]
    pub display_name: String,
    #[serde(rename = "wireFormat")]
    pub wire_format: String,
    #[serde(rename = "dataCollection")]
    pub data_collection: String,
    pub zdr: bool,
    pub quantization: Option<String>,
    pub models: Vec<ProviderModelEntry>,
}

#[derive(Debug, Serialize)]
pub struct ProviderModelEntry {
    pub id: String,
    pub pricing: PricingShape,
    #[serde(rename = "contextLength")]
    pub context_length: u32,
    #[serde(rename = "maxOutputTokens", skip_serializing_if = "Option::is_none")]
    pub max_output_tokens: Option<u32>,
    #[serde(rename = "minContext", skip_serializing_if = "Option::is_none")]
    pub min_context: Option<u32>,
    #[serde(rename = "supportedFeatures")]
    pub supported_features: Vec<String>,
    #[serde(rename = "inputModalities")]
    pub input_modalities: Vec<String>,
    pub uptime: UptimeInfo,
    #[serde(rename = "deprecationDate", skip_serializing_if = "Option::is_none")]
    pub deprecation_date: Option<String>,
}

#[derive(Debug, Serialize)]
pub struct PricingShape {
    pub prompt: String,
    pub completion: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub request: Option<String>,
}

#[derive(Debug, Serialize)]
pub struct UptimeInfo {
    pub tier: HealthTier,
    #[serde(rename = "successRatio")]
    pub success_ratio: f64,
    #[serde(rename = "sampleCount")]
    pub sample_count: u64,
    #[serde(rename = "ttftP50Ms", skip_serializing_if = "Option::is_none")]
    pub ttft_p50_ms: Option<u64>,
    #[serde(rename = "tpsP50", skip_serializing_if = "Option::is_none")]
    pub tps_p50: Option<f64>,
}

pub async fn list_providers(State(state): State<AppState>) -> Json<Value> {
    let providers = state.providers.registry.list_active_providers();
    let mut entries: Vec<ProviderEntry> = Vec::with_capacity(providers.len());
    for p in providers {
        let models = state.providers.registry.list_models_for(&p.provider_id);
        let mut model_entries: Vec<ProviderModelEntry> = Vec::with_capacity(models.len());
        for m in models {
            let h = state.providers.health.snapshot(&p.provider_id, &m.model_id);
            model_entries.push(ProviderModelEntry {
                id: m.model_id.clone(),
                pricing: PricingShape {
                    prompt: m.pricing_prompt_usd.clone(),
                    completion: m.pricing_completion_usd.clone(),
                    request: m.pricing_request_usd.clone(),
                },
                context_length: m.context_length,
                max_output_tokens: m.max_output_tokens,
                min_context: m.min_context,
                supported_features: m.supported_features.clone(),
                input_modalities: m.input_modalities.clone(),
                uptime: UptimeInfo {
                    tier: h.tier(),
                    success_ratio: h.success_ratio,
                    sample_count: h.sample_count,
                    ttft_p50_ms: h.ttft_p50_ms,
                    tps_p50: h.tps_p50,
                },
                deprecation_date: m.deprecation_date.clone(),
            });
        }
        entries.push(ProviderEntry {
            slug: p.slug.clone(),
            display_name: p.display_name.clone(),
            wire_format: p.wire_format.as_str().to_string(),
            data_collection: p.data_collection.clone(),
            zdr: p.zdr,
            quantization: p.quantization.clone(),
            models: model_entries,
        });
    }
    Json(serde_json::json!({ "data": entries }))
}
