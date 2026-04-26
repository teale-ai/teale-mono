use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};

use crate::privacy_filter::PrivacyFilterMode;
use crate::windows_model_catalog::{model_by_file_name, WINDOWS_MODEL_CATALOG};

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct PersistedModelRecord {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub downloaded_file_path: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub last_error: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct PersistedRegistry {
    #[serde(default)]
    pub active_model_id: Option<String>,
    #[serde(default)]
    pub privacy_filter_mode: PrivacyFilterMode,
    #[serde(default)]
    pub models: BTreeMap<String, PersistedModelRecord>,
}

impl PersistedRegistry {
    pub fn ensure_catalog_entries(&mut self) {
        for model in WINDOWS_MODEL_CATALOG {
            self.models.entry(model.id.to_string()).or_default();
        }
    }
}

#[derive(Debug, Clone)]
pub struct RegistryStore {
    path: PathBuf,
}

impl RegistryStore {
    pub fn new(path: impl Into<PathBuf>) -> Self {
        Self { path: path.into() }
    }

    pub fn path(&self) -> &Path {
        &self.path
    }

    pub fn load(&self) -> anyhow::Result<PersistedRegistry> {
        match std::fs::read_to_string(&self.path) {
            Ok(content) => {
                let mut registry: PersistedRegistry = serde_json::from_str(&content)?;
                registry.ensure_catalog_entries();
                Ok(registry)
            }
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => {
                let mut registry = PersistedRegistry::default();
                registry.ensure_catalog_entries();
                Ok(registry)
            }
            Err(e) => Err(e.into()),
        }
    }

    pub fn save(&self, registry: &PersistedRegistry) -> anyhow::Result<()> {
        if let Some(parent) = self.path.parent() {
            std::fs::create_dir_all(parent)?;
        }
        let content = serde_json::to_string_pretty(registry)?;
        std::fs::write(&self.path, content)?;
        Ok(())
    }

    pub fn load_or_init_with_legacy(
        &self,
        legacy_model_path: Option<&str>,
        legacy_model_id: Option<&str>,
        model_dir: &Path,
    ) -> anyhow::Result<PersistedRegistry> {
        let mut registry = self.load()?;

        if registry.active_model_id.is_some() {
            return Ok(registry);
        }

        let mut discovered_active_model_id = None;

        if let Some(path) = legacy_model_path
            .filter(|p| !p.trim().is_empty())
            .map(PathBuf::from)
            .filter(|p| p.exists())
        {
            let model_id = legacy_model_id
                .filter(|id| !id.trim().is_empty())
                .map(ToOwned::to_owned)
                .or_else(|| {
                    path.file_name()
                        .and_then(|s| s.to_str())
                        .and_then(model_by_file_name)
                        .map(|m| m.id.to_string())
                });

            if let Some(model_id) = model_id {
                registry.ensure_catalog_entries();
                registry.active_model_id = Some(model_id.clone());
                registry
                    .models
                    .entry(model_id)
                    .or_default()
                    .downloaded_file_path = Some(path.to_string_lossy().to_string());
                discovered_active_model_id = registry.active_model_id.clone();
            }
        }

        if let Ok(entries) = std::fs::read_dir(model_dir) {
            for entry in entries.flatten() {
                let path = entry.path();
                if !path.is_file() {
                    continue;
                }
                let Some(file_name) = path.file_name().and_then(|s| s.to_str()) else {
                    continue;
                };
                let Some(model) = model_by_file_name(file_name) else {
                    continue;
                };
                registry.ensure_catalog_entries();
                registry
                    .models
                    .entry(model.id.to_string())
                    .or_default()
                    .downloaded_file_path = Some(path.to_string_lossy().to_string());
            }
        }

        if registry.active_model_id.is_none() {
            registry.active_model_id = discovered_active_model_id.or_else(|| {
                WINDOWS_MODEL_CATALOG.iter().find_map(|model| {
                    registry
                        .models
                        .get(model.id)
                        .and_then(|record| record.downloaded_file_path.as_ref())
                        .map(|_| model.id.to_string())
                })
            });
        }

        self.save(&registry)?;
        Ok(registry)
    }
}

#[cfg(test)]
mod tests {
    use std::{
        fs,
        time::{SystemTime, UNIX_EPOCH},
    };

    use super::RegistryStore;

    #[test]
    fn migrates_legacy_model_into_registry() {
        let base = std::env::temp_dir().join(format!(
            "teale-registry-test-{}",
            SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .expect("clock")
                .as_nanos()
        ));
        let config_dir = base.join("config");
        let models_dir = base.join("models");
        fs::create_dir_all(&config_dir).expect("config dir");
        fs::create_dir_all(&models_dir).expect("models dir");

        let model_path = models_dir.join("hermes-3-llama-3.1-8b-Q5_K_M.gguf");
        fs::write(&model_path, b"stub").expect("write legacy model");

        let store = RegistryStore::new(config_dir.join("model-registry.json"));
        let registry = store
            .load_or_init_with_legacy(
                model_path.to_str(),
                Some("nousresearch/hermes-3-llama-3.1-8b"),
                &models_dir,
            )
            .expect("load registry");

        assert_eq!(
            registry.active_model_id.as_deref(),
            Some("nousresearch/hermes-3-llama-3.1-8b")
        );
        assert_eq!(
            registry.models["nousresearch/hermes-3-llama-3.1-8b"]
                .downloaded_file_path
                .as_deref(),
            model_path.to_str()
        );

        let _ = fs::remove_dir_all(base);
    }

    #[test]
    fn discovers_all_downloaded_models_in_model_directory() {
        let base = std::env::temp_dir().join(format!(
            "teale-registry-discovery-test-{}",
            SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .expect("clock")
                .as_nanos()
        ));
        let config_dir = base.join("config");
        let models_dir = base.join("models");
        fs::create_dir_all(&config_dir).expect("config dir");
        fs::create_dir_all(&models_dir).expect("models dir");

        let hermes_path = models_dir.join("hermes-3-llama-3.1-8b-Q5_K_M.gguf");
        let llama_path = models_dir.join("llama-3.1-8b-instruct-Q4_K_M.gguf");
        fs::write(&hermes_path, b"stub").expect("write hermes");
        fs::write(&llama_path, b"stub").expect("write llama");

        let store = RegistryStore::new(config_dir.join("model-registry.json"));
        let registry = store
            .load_or_init_with_legacy(None, None, &models_dir)
            .expect("load registry");

        assert_eq!(
            registry.active_model_id.as_deref(),
            Some("nousresearch/hermes-3-llama-3.1-8b")
        );
        assert_eq!(
            registry.models["nousresearch/hermes-3-llama-3.1-8b"]
                .downloaded_file_path
                .as_deref(),
            hermes_path.to_str()
        );
        assert_eq!(
            registry.models["meta-llama/llama-3.1-8b-instruct"]
                .downloaded_file_path
                .as_deref(),
            llama_path.to_str()
        );

        let _ = fs::remove_dir_all(base);
    }
}
