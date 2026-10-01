use super::Harness;
use anyhow::{bail, Context, Result};
use jsonc_parser::cst::{CstInputValue, CstRootNode};
use serde_json::Value;
use std::str::FromStr;

fn input(value: &Value) -> CstInputValue {
    match value {
        Value::Null => CstInputValue::Null,
        Value::Bool(v) => CstInputValue::Bool(*v),
        Value::Number(v) => CstInputValue::Number(v.to_string()),
        Value::String(v) => CstInputValue::String(v.clone()),
        Value::Array(v) => CstInputValue::Array(v.iter().map(input).collect()),
        Value::Object(v) => {
            CstInputValue::Object(v.iter().map(|(k, v)| (k.clone(), input(v))).collect())
        }
    }
}
/// Refuse collisions even if values look like a previous Teale setup. Only a receipt owns them.
pub fn project(harness: Harness, source: &str, edits: &[(Vec<String>, Value)]) -> Result<String> {
    match harness {
        Harness::OpenCode => {
            let value: Value = jsonc_parser::parse_to_serde_value(source, &Default::default())?;
            if !value.is_object() {
                bail!("config must be an object");
            }
            if value.get("provider").is_some_and(|p| !p.is_object()) {
                bail!("provider must be an object");
            }
            if value.get("provider").and_then(|p| p.get("teale")).is_some() {
                bail!("existing Teale provider is not owned; preserved");
            }
            let tree = CstRootNode::parse(source, &Default::default())?;
            for (path, value) in edits {
                let mut object = tree.object_value().context("config must be an object")?;
                for part in &path[..path.len() - 1] {
                    object = object.object_value_or_set(part);
                }
                let key = &path[path.len() - 1];
                if let Some(prop) = object.get(key) {
                    prop.set_value(input(value));
                } else {
                    object.append(key, input(value));
                }
            }
            Ok(tree.to_string())
        }
        Harness::Hermes => {
            let value: Value = serde_yaml::from_str(source).context("invalid YAML")?;
            if !value.is_object() {
                bail!("config must be a mapping");
            }
            for name in ["providers", "model"] {
                if value.get(name).is_some_and(|p| !p.is_object()) {
                    bail!("{name} must be a mapping");
                }
            }
            if value
                .get("providers")
                .and_then(|p| p.get("teale"))
                .is_some()
            {
                bail!("existing Teale provider is not owned; preserved");
            }
            let doc = yaml_edit::YamlFile::from_str(source).context("invalid YAML syntax")?;
            let documents: Vec<_> = doc.documents().collect();
            if documents.len() != 1 {
                bail!("exactly one YAML document is required");
            }
            let root = documents[0]
                .as_mapping()
                .context("config must be a mapping")?;
            for (path, value) in edits {
                let mut mapping = root.clone();
                for part in &path[..path.len() - 1] {
                    if mapping.get_mapping(part.as_str()).is_none() {
                        let empty = yaml_edit::Document::from_str("{}")?;
                        mapping.set(part.as_str(), empty.as_mapping().unwrap());
                    }
                    mapping = mapping
                        .get_mapping(part.as_str())
                        .context("nested mapping unavailable")?;
                }
                // JSON values are legal YAML flow values, with unambiguous quoting.
                let key = path.last().unwrap().as_str();
                if value.is_object() {
                    let fragment = yaml_edit::Document::from_str(&serde_json::to_string(value)?)?;
                    mapping.set(
                        key,
                        fragment.as_mapping().context("invalid projected mapping")?,
                    );
                } else if let Some(text) = value.as_str() {
                    mapping.set(key, text);
                } else {
                    bail!("unsupported YAML projection value");
                }
            }
            let out = doc.to_string();
            let actual: Value = serde_yaml::from_str(&out).context("projected YAML is invalid")?;
            let mut expected = value.clone();
            for (path, value) in edits {
                let mut cursor = &mut expected;
                for part in &path[..path.len() - 1] {
                    let object = cursor
                        .as_object_mut()
                        .context("projection parent is not a mapping")?;
                    cursor = object.entry(part).or_insert_with(|| serde_json::json!({}));
                }
                cursor
                    .as_object_mut()
                    .context("projection target is not a mapping")?
                    .insert(path.last().unwrap().clone(), value.clone());
            }
            if actual != expected {
                bail!("YAML projection changed unrelated values; no files written");
            }
            Ok(out)
        }
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    fn edits() -> Vec<(Vec<String>, Value)> {
        vec![(
            vec!["provider".into(), "teale".into()],
            json!({"key":"quoted:secret"}),
        )]
    }
    #[test]
    fn jsonc_keeps_unrelated_comments_and_values() {
        let s = "{\n // user comment\n \"theme\": \"dark\",\n \"provider\": {\"mine\": {}},\n}\n";
        let out = project(Harness::OpenCode, s, &edits()).unwrap();
        assert!(out.contains("// user comment"));
        assert!(out.contains("\"dark\""));
        assert!(out.contains("\"mine\""));
    }
    #[test]
    fn fresh_yaml_mapping_can_add_provider_and_selection() {
        let e = vec![
            (
                vec!["providers".into(), "teale".into()],
                json!({"name":"Teale","api_key":"fake"}),
            ),
            (
                vec!["model".into(), "provider".into()],
                json!("custom:teale"),
            ),
        ];
        let out = project(Harness::Hermes, "{}\n", &e).unwrap();
        let v: Value = serde_yaml::from_str(&out).unwrap();
        assert_eq!(v["model"]["provider"], "custom:teale");
    }
    #[test]
    fn collisions_and_invalid_config_refused() {
        assert!(project(Harness::OpenCode, "{\"provider\":{\"teale\":{}}}", &edits()).is_err());
        assert!(project(Harness::OpenCode, "{\"provider\":false}", &edits()).is_err());
        assert!(project(Harness::Hermes, "providers: [x]\n", &[]).is_err());
        assert!(project(Harness::Hermes, "providers:\n  teale: {}\n", &[]).is_err());
    }
    #[test]
    fn yaml_keeps_comments_and_nested_unrelated_fields() {
        let s="# retained\nproviders:\n  custom: {name: Other}\nmodel:\n  provider: old\n  default: old-model\nagent:\n  reasoning: high\n";
        let e = vec![
            (
                vec!["providers".into(), "teale".into()],
                json!({"name":"Teale","api_key":"abc:123"}),
            ),
            (
                vec!["model".into(), "provider".into()],
                json!("custom:teale"),
            ),
        ];
        let out = project(Harness::Hermes, s, &e).unwrap();
        assert!(out.contains("# retained"));
        assert!(out.contains("reasoning: high"));
        let v: Value = serde_yaml::from_str(&out).unwrap();
        assert_eq!(v["model"]["default"], "old-model");
        assert_eq!(v["providers"]["teale"]["api_key"], "abc:123");
    }
}
