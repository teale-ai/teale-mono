//! OpenRouter provider model document, schema_version 2.4 (typed modality
//! objects). Source: https://openrouter.ai/docs/guides/providers/integration
//!
//! Deliberately conservative internal prep:
//! - `is_ready` is always false, so OpenRouter's monitor stages the endpoint
//!   hidden and skips baseline tests until we flip it on purpose.
//! - No `pricing`, `datacenters`, `deployment_region`, `hugging_face_id`, or
//!   `capacity` are emitted. Pricing and regional disclosure are pending an
//!   owner decision; capacity must come from measured simultaneous
//!   execution, not from scheduler queue depth.
//! - `tools` is declared only when the catalog entry lists it.

use serde_json::{json, Map, Value};

use crate::catalog::CatalogModel;

pub const SCHEMA_VERSION: &str = "2.4";

const VALID_QUANTIZATIONS: &[&str] = &[
    "int4", "int8", "fp4", "mxfp4", "nvfp4", "fp6", "fp8", "mxfp8", "fp16", "bf16", "fp32",
];

fn quantization(raw: Option<&str>) -> Value {
    match raw.map(|q| q.to_ascii_lowercase()) {
        Some(q) if VALID_QUANTIZATIONS.contains(&q.as_str()) => Value::String(q),
        _ => Value::Null,
    }
}

fn supported_parameters(m: &CatalogModel) -> Map<String, Value> {
    let has = |name: &str| m.supported_parameters.iter().any(|p| p == name);
    let mut out = Map::new();
    if has("temperature") {
        out.insert("temperature".into(), json!({"type": "range", "min": 0, "max": 2}));
    }
    if has("top_p") {
        out.insert("top_p".into(), json!({"type": "range", "min": 0, "max": 1}));
    }
    if has("max_tokens") {
        out.insert(
            "max_tokens".into(),
            json!({"type": "integer", "min": 1, "max": m.max_output_tokens, "unit": "token"}),
        );
    }
    if has("stop") {
        out.insert("stop".into(), json!({"type": "array", "max_items": 4}));
    }
    if has("tools") {
        out.insert("tools".into(), json!({"type": "boolean"}));
    }
    if has("structured_outputs") || has("response_format") {
        out.insert("structured_outputs".into(), json!({"type": "boolean"}));
    }
    if has("reasoning") || has("include_reasoning") {
        out.insert("reasoning".into(), json!({"type": "boolean"}));
    }
    out
}

/// Build one 2.4 model document from a catalog entry.
pub fn model_document(m: &CatalogModel) -> Value {
    json!({
        "schema_version": SCHEMA_VERSION,
        "id": m.id,
        "name": m.display_name,
        "created": 0,
        "quantization": quantization(m.quantization.as_deref()),
        "description": m.description.clone().unwrap_or_default(),
        "input_modalities": [{
            "type": "text",
            "supported_inputs": {
                "max_context_length": {"value": m.context_length, "unit": "token"}
            }
        }],
        "output_modalities": [{
            "type": "text",
            "max_length": {"value": m.max_output_tokens, "unit": "token"},
            "streaming": true,
            "supported_parameters": Value::Object(supported_parameters(m))
        }],
        "is_ready": false
    })
}

pub fn models_document<'a>(models: impl IntoIterator<Item = &'a CatalogModel>) -> Value {
    json!({ "data": models.into_iter().map(model_document).collect::<Vec<_>>() })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn model(params: &[&str], quant: Option<&str>) -> CatalogModel {
        CatalogModel {
            id: "org/model".into(),
            display_name: "Org: Model".into(),
            owned_by: "org".into(),
            context_length: 32768,
            max_output_tokens: 8192,
            params_b: 8.0,
            pricing_prompt: "0.1".into(),
            pricing_completion: "0.2".into(),
            quantization: quant.map(str::to_string),
            supported_parameters: params.iter().map(|s| s.to_string()).collect(),
            description: None,
            aliases: vec![],
            is_virtual: false,
            routing_tags: vec![],
            estimated_ttft_ms: None,
            estimated_tps: None,
        }
    }

    #[test]
    fn document_is_not_ready_and_omits_held_fields() {
        let d = model_document(&model(&["temperature", "max_tokens"], None));
        assert_eq!(d["schema_version"], "2.4");
        assert_eq!(d["is_ready"], false);
        for held in ["pricing", "datacenters", "deployment_region", "hugging_face_id", "capacity"] {
            assert!(d.get(held).is_none(), "{held} must not be emitted");
        }
        assert!(d["input_modalities"][0].get("pricing").is_none());
        assert!(d["output_modalities"][0].get("pricing").is_none());
        assert!(d["output_modalities"][0].get("capacity").is_none());
    }

    #[test]
    fn typed_modalities_and_descriptors() {
        let d = model_document(&model(&["temperature", "top_p", "max_tokens", "stop"], None));
        assert_eq!(d["input_modalities"][0]["type"], "text");
        assert_eq!(
            d["input_modalities"][0]["supported_inputs"]["max_context_length"]["value"],
            32768
        );
        let out = &d["output_modalities"][0];
        assert_eq!(out["type"], "text");
        assert_eq!(out["streaming"], true);
        assert_eq!(out["max_length"]["value"], 8192);
        assert_eq!(out["supported_parameters"]["max_tokens"]["max"], 8192);
        assert_eq!(out["supported_parameters"]["temperature"]["type"], "range");
        assert_eq!(out["supported_parameters"]["stop"]["max_items"], 4);
    }

    #[test]
    fn tools_only_when_catalog_lists_them() {
        let without = model_document(&model(&["temperature"], None));
        assert!(without["output_modalities"][0]["supported_parameters"].get("tools").is_none());
        let with = model_document(&model(&["temperature", "tools"], None));
        assert_eq!(with["output_modalities"][0]["supported_parameters"]["tools"]["type"], "boolean");
    }

    #[test]
    fn empty_parameters_is_empty_object_and_unlisted_not_invented() {
        let d = model_document(&model(&["stream", "seed"], None));
        let p = d["output_modalities"][0]["supported_parameters"].as_object().unwrap();
        assert!(p.is_empty());
    }

    #[test]
    fn quantization_only_from_valid_set() {
        assert_eq!(model_document(&model(&[], Some("MXFP4")))["quantization"], "mxfp4");
        assert!(model_document(&model(&[], Some("8bit")))["quantization"].is_null());
        assert!(model_document(&model(&[], Some("Q4_K_M")))["quantization"].is_null());
        assert!(model_document(&model(&[], None))["quantization"].is_null());
    }

    #[test]
    fn wrapper_has_data_array() {
        let m = model(&[], None);
        let d = models_document([&m]);
        assert_eq!(d["data"].as_array().unwrap().len(), 1);
    }
}
