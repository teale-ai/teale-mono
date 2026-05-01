//! Curated model catalog loaded from `models.yaml` at startup.
//!
//! This is the gateway's view of "what we claim to serve" — gated further
//! by live device availability before appearing in `/v1/models`.

use serde::Deserialize;
use teale_protocol::openai::{ModelEntry, Pricing};

pub const LIVE_MODEL_DEFAULT_PROMPT_PRICE: &str = "0.00000030";
pub const LIVE_MODEL_DEFAULT_COMPLETION_PRICE: &str = "0.00000120";
pub const LIVE_MODEL_DEFAULT_CONTEXT_LENGTH: u32 = 32_768;
pub const LIVE_MODEL_DEFAULT_MAX_OUTPUT_TOKENS: u32 = 8_192;

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
    /// Virtual meta-model (e.g. `teale/auto`). Always advertised, never
    /// dispatched directly — resolved at request time to a concrete model
    /// via `resolve_auto`.
    #[serde(default, rename = "virtual")]
    pub is_virtual: bool,
    /// Routing tags used by virtual models such as `teale/auto` to recognize
    /// request classes that need stricter model selection than "smallest that fits".
    #[serde(default)]
    pub routing_tags: Vec<String>,
}

impl CatalogModel {
    pub fn to_entry(&self) -> ModelEntry {
        self.to_entry_with_live_state(None, 0)
    }

    pub fn to_entry_with_live_state(
        &self,
        metrics: Option<teale_protocol::openai::ModelMetrics>,
        loaded_device_count: u32,
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
            loaded_device_count: Some(loaded_device_count),
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

    pub fn has_routing_tag(&self, tag: &str) -> bool {
        self.routing_tags
            .iter()
            .any(|t| t.eq_ignore_ascii_case(tag))
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AutoRouteProfile {
    Generic,
    AgentHarness,
}

impl AutoRouteProfile {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Generic => "generic",
            Self::AgentHarness => "agent_harness",
        }
    }
}

pub fn load(path: &str) -> anyhow::Result<Vec<CatalogModel>> {
    let content =
        std::fs::read_to_string(path).map_err(|e| anyhow::anyhow!("read {}: {}", path, e))?;
    let file: CatalogFile = serde_yaml::from_str(&content)?;
    Ok(file.models)
}

pub fn synthesize_live_model(model_id: &str, effective_context: Option<u32>) -> CatalogModel {
    let context_length = effective_context.unwrap_or(LIVE_MODEL_DEFAULT_CONTEXT_LENGTH);
    let max_output_tokens =
        (context_length / 4).clamp(1_024, LIVE_MODEL_DEFAULT_MAX_OUTPUT_TOKENS.max(1_024));
    let display_name = model_id
        .rsplit('/')
        .next()
        .filter(|name| !name.is_empty())
        .unwrap_or(model_id)
        .replace(['-', '_'], " ");
    let owned_by = model_id
        .split('/')
        .next()
        .filter(|owner| !owner.is_empty())
        .unwrap_or("teale")
        .to_string();

    CatalogModel {
        id: model_id.to_string(),
        display_name,
        owned_by,
        context_length,
        max_output_tokens,
        params_b: 1.0,
        pricing_prompt: LIVE_MODEL_DEFAULT_PROMPT_PRICE.to_string(),
        pricing_completion: LIVE_MODEL_DEFAULT_COMPLETION_PRICE.to_string(),
        quantization: None,
        supported_parameters: vec![
            "temperature".into(),
            "top_p".into(),
            "max_tokens".into(),
            "stop".into(),
            "stream".into(),
            "seed".into(),
        ],
        description: Some(
            "Live Teale network model discovered from active supply. Gateway default pricing applies."
                .into(),
        ),
        aliases: vec![],
        is_virtual: false,
        routing_tags: vec![],
    }
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

/// Resolve a virtual model (e.g. `teale/auto`) to a concrete catalog model.
///
/// Picks the smallest concrete model (lowest `params_b`) whose
/// `context_length >= required_ctx` AND whose live supplier count meets
/// the per-model floor. Returns `None` if no catalog model satisfies both
/// — caller must translate to 503 `NoEligibleDevice` (strict, per the
/// project's fallback policy).
pub fn resolve_auto(
    catalog: &[CatalogModel],
    required_ctx: u32,
    profile: AutoRouteProfile,
    eligible_count: impl Fn(&str, u32) -> u32,
    floor_small: u32,
    floor_large: u32,
) -> Option<&CatalogModel> {
    let build_candidates = |prefer_agent_harness: bool| -> Vec<&CatalogModel> {
        catalog
            .iter()
            .filter(|m| !m.is_virtual)
            .filter(|m| m.context_length >= required_ctx)
            .filter(|m| match (profile, prefer_agent_harness) {
                (AutoRouteProfile::Generic, _) => true,
                (AutoRouteProfile::AgentHarness, true) => m.has_routing_tag("agent-harness"),
                (AutoRouteProfile::AgentHarness, false) => true,
            })
            .filter(|m| {
                let required = if is_large(m.params_b) {
                    floor_large
                } else {
                    floor_small
                };
                eligible_count(&m.id, required_ctx) >= required
            })
            .collect()
    };

    let mut candidates = build_candidates(true);
    if matches!(profile, AutoRouteProfile::AgentHarness) && candidates.is_empty() {
        candidates = build_candidates(false);
    }

    candidates.sort_by(|a, b| {
        match profile {
            // For agent harnesses, stay inside a curated set of models we have
            // explicitly marked as suitable for coding/tool-heavy workflows when
            // that supply exists. If the curated lane is unavailable, we
            // gracefully fall back to the generic pool rather than 503ing a
            // simple OpenClaw turn that Hermes can satisfy.
            AutoRouteProfile::AgentHarness => a
                .params_b
                .partial_cmp(&b.params_b)
                .unwrap_or(std::cmp::Ordering::Equal)
                .then(b.context_length.cmp(&a.context_length)),
            // Generic traffic keeps the old "smallest fit wins" behavior.
            AutoRouteProfile::Generic => a
                .params_b
                .partial_cmp(&b.params_b)
                .unwrap_or(std::cmp::Ordering::Equal)
                .then(b.context_length.cmp(&a.context_length)),
        }
    });
    candidates.first().copied()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn model(id: &str, params_b: f64, context_length: u32, tags: &[&str]) -> CatalogModel {
        CatalogModel {
            id: id.to_string(),
            display_name: id.to_string(),
            owned_by: "test".to_string(),
            context_length,
            max_output_tokens: 8192,
            params_b,
            pricing_prompt: "0.00000010".to_string(),
            pricing_completion: "0.00000020".to_string(),
            quantization: None,
            supported_parameters: vec![],
            description: None,
            aliases: vec![],
            is_virtual: false,
            routing_tags: tags.iter().map(|s| s.to_string()).collect(),
        }
    }

    #[test]
    fn generic_auto_picks_smallest_eligible_model() {
        let catalog = vec![
            model("small", 8.0, 32768, &[]),
            model("big", 27.0, 262144, &["agent-harness"]),
        ];
        let picked = resolve_auto(
            &catalog,
            20_000,
            AutoRouteProfile::Generic,
            |id, _| u32::from(id == "small" || id == "big"),
            1,
            1,
        )
        .expect("should resolve");
        assert_eq!(picked.id, "small");
    }

    #[test]
    fn agent_harness_auto_ignores_untagged_models() {
        let catalog = vec![
            model("small", 8.0, 32768, &[]),
            model("agentic", 27.0, 262144, &["agent-harness"]),
        ];
        let picked = resolve_auto(
            &catalog,
            20_000,
            AutoRouteProfile::AgentHarness,
            |id, _| u32::from(id == "small" || id == "agentic"),
            1,
            1,
        )
        .expect("should resolve");
        assert_eq!(picked.id, "agentic");
    }

    #[test]
    fn agent_harness_auto_falls_back_to_generic_when_tagged_lane_missing() {
        let catalog = vec![
            model("small", 8.0, 32768, &[]),
            model("agentic", 27.0, 262144, &["agent-harness"]),
        ];
        let picked = resolve_auto(
            &catalog,
            20_000,
            AutoRouteProfile::AgentHarness,
            |id, _| u32::from(id == "small"),
            1,
            1,
        )
        .expect("should resolve");
        assert_eq!(picked.id, "small");
    }

    #[test]
    fn auto_resolution_uses_context_eligible_supply() {
        let catalog = vec![model("agentic", 27.0, 262144, &["agent-harness"])];
        let picked = resolve_auto(
            &catalog,
            120_000,
            AutoRouteProfile::AgentHarness,
            |_, need_ctx| u32::from(need_ctx <= 64_000),
            1,
            1,
        );
        assert!(
            picked.is_none(),
            "should reject when no node can honor context"
        );
    }
}
