//! Curated model catalog loaded from `models.yaml` at startup.
//!
//! This is the gateway's view of "what we claim to serve" — gated further
//! by live device availability before appearing in `/v1/models`.

use serde::Deserialize;
use teale_protocol::openai::{ModelEntry, Pricing};

#[derive(Debug, Deserialize, Clone)]
pub struct CatalogFile {
    pub models: Vec<CatalogModel>,
}

#[derive(Debug, Deserialize, Clone)]
pub struct CatalogModel {
    pub id: String,
    pub display_name: String,
    pub owned_by: String,
    pub context_length: u32,
    /// Max completion tokens we'll accept for `max_tokens` on this model.
    /// Required by OpenRouter's /models schema.
    pub max_output_tokens: u32,
    /// Parameter count in billions, for fleet-floor tier lookup.
    pub params_b: f64,
    pub pricing_prompt: String,
    pub pricing_completion: String,
    pub quantization: Option<String>,
    #[serde(default)]
    pub supported_parameters: Vec<String>,
    #[serde(default)]
    pub description: Option<String>,
    /// Extra aliases the gateway accepts in the `model` field (e.g. short names).
    #[serde(default)]
    pub aliases: Vec<String>,
}

impl CatalogModel {
    pub fn to_entry(&self) -> ModelEntry {
        self.to_entry_with_metrics(None)
    }

    pub fn to_entry_with_metrics(
        &self,
        metrics: Option<teale_protocol::openai::ModelMetrics>,
    ) -> ModelEntry {
        ModelEntry {
            id: self.id.clone(),
            object: "model".to_string(),
            created: 0,
            owned_by: self.owned_by.clone(),
            context_length: Some(self.context_length),
            max_output_tokens: Some(self.max_output_tokens),
            pricing: Some(Pricing {
                prompt: self.pricing_prompt.clone(),
                completion: self.pricing_completion.clone(),
                request: None,
                image: None,
                input_cache_read: None,
                input_cache_write: None,
            }),
            supported_parameters: if self.supported_parameters.is_empty() {
                None
            } else {
                Some(self.supported_parameters.clone())
            },
            quantization: self.quantization.clone(),
            description: self.description.clone(),
            metrics,
        }
    }

    pub fn matches(&self, id: &str) -> bool {
        if self.id.eq_ignore_ascii_case(id) {
            return true;
        }
        self.aliases.iter().any(|a| a.eq_ignore_ascii_case(id))
    }

    /// Per-token prompt price in USD, parsed from the YAML string. Malformed
    /// values fall back to 0 (free) rather than blowing up inference — a bad
    /// catalog entry should not take down the gateway.
    pub fn prompt_price_usd(&self) -> f64 {
        self.pricing_prompt.parse::<f64>().unwrap_or(0.0)
    }

    /// Per-token completion price in USD. See `prompt_price_usd`.
    pub fn completion_price_usd(&self) -> f64 {
        self.pricing_completion.parse::<f64>().unwrap_or(0.0)
    }
}

pub fn load(path: &str) -> anyhow::Result<Vec<CatalogModel>> {
    let content =
        std::fs::read_to_string(path).map_err(|e| anyhow::anyhow!("read {}: {}", path, e))?;
    let file: CatalogFile = serde_yaml::from_str(&content)?;
    Ok(file.models)
}

/// Floor-category for per-model availability gating.
pub fn is_large(params_b: f64) -> bool {
    params_b >= 50.0
}

/// Rough on-disk / VRAM footprint in GB. Used for "will this fit?" checks
/// when deciding whether an un-cached model is *potentially* downloadable.
/// Intentionally conservative — better to over-estimate and hide an
/// ambiguous case than to promise capacity that doesn't exist.
pub fn estimated_size_gb(params_b: f64, quantization: Option<&str>) -> f64 {
    let q = quantization.map(|s| s.to_ascii_uppercase());
    let bytes_per_param = match q.as_deref() {
        Some(q) if q.contains("FP16") || q.contains("BF16") => 2.0,
        Some(q) if q.contains("Q8") || q.contains("8BIT") => 1.1,
        Some(q) if q.contains("Q6") => 0.75,
        Some(q) if q.contains("Q5") => 0.65,
        Some(q) if q.contains("Q4") => 0.55,
        Some(q) if q.contains("MXFP4") => 0.55,
        Some(q) if q.contains("Q3") => 0.40,
        Some(q) if q.contains("Q2") => 0.30,
        _ => 0.6,
    };
    params_b * bytes_per_param
}
