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
        ModelEntry {
            id: self.id.clone(),
            object: "model".to_string(),
            created: 0,
            owned_by: self.owned_by.clone(),
            context_length: Some(self.context_length),
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
        }
    }

    pub fn matches(&self, id: &str) -> bool {
        if self.id.eq_ignore_ascii_case(id) {
            return true;
        }
        self.aliases.iter().any(|a| a.eq_ignore_ascii_case(id))
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
