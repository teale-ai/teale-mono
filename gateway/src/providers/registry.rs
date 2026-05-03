//! In-memory snapshot of `providers` + `provider_models`, refreshed from the
//! DB on every admin mutation. Lookups by slug or by (model_id) for routing.

use std::collections::HashMap;
use std::sync::Arc;

use parking_lot::RwLock;
use rusqlite::params;
use serde::{Deserialize, Serialize};

use crate::db::DbPool;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum ProviderStatus {
    Active,
    Disabled,
    Probation,
}

impl ProviderStatus {
    pub fn as_str(&self) -> &'static str {
        match self {
            ProviderStatus::Active => "active",
            ProviderStatus::Disabled => "disabled",
            ProviderStatus::Probation => "probation",
        }
    }

    pub fn parse(s: &str) -> Option<Self> {
        match s {
            "active" => Some(ProviderStatus::Active),
            "disabled" => Some(ProviderStatus::Disabled),
            "probation" => Some(ProviderStatus::Probation),
            _ => None,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ProviderWireFormat {
    Openai,
    Anthropic,
}

impl ProviderWireFormat {
    pub fn as_str(&self) -> &'static str {
        match self {
            ProviderWireFormat::Openai => "openai",
            ProviderWireFormat::Anthropic => "anthropic",
        }
    }
    pub fn parse(s: &str) -> Self {
        match s {
            "anthropic" => ProviderWireFormat::Anthropic,
            _ => ProviderWireFormat::Openai,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ProviderRow {
    #[serde(rename = "providerID")]
    pub provider_id: String,
    pub slug: String,
    #[serde(rename = "displayName")]
    pub display_name: String,
    #[serde(rename = "baseURL")]
    pub base_url: String,
    #[serde(rename = "wireFormat")]
    pub wire_format: ProviderWireFormat,
    #[serde(rename = "authHeaderName")]
    pub auth_header_name: String,
    /// Env var name (or other secret-store key) that holds the actual API
    /// key. Never the raw secret — kept consistent with the existing static
    /// `GATEWAY_TOKENS` posture.
    #[serde(rename = "authSecretRef")]
    pub auth_secret_ref: String,
    pub status: ProviderStatus,
    #[serde(rename = "dataCollection")]
    pub data_collection: String,
    pub zdr: bool,
    pub quantization: Option<String>,
    #[serde(rename = "createdAt")]
    pub created_at: i64,
    #[serde(rename = "updatedAt")]
    pub updated_at: i64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ProviderModelRow {
    #[serde(rename = "providerID")]
    pub provider_id: String,
    #[serde(rename = "modelID")]
    pub model_id: String,
    #[serde(rename = "pricingPromptUsd")]
    pub pricing_prompt_usd: String,
    #[serde(rename = "pricingCompletionUsd")]
    pub pricing_completion_usd: String,
    #[serde(rename = "pricingRequestUsd", skip_serializing_if = "Option::is_none")]
    pub pricing_request_usd: Option<String>,
    #[serde(rename = "minContext", skip_serializing_if = "Option::is_none")]
    pub min_context: Option<u32>,
    #[serde(rename = "contextLength")]
    pub context_length: u32,
    #[serde(rename = "maxOutputTokens", skip_serializing_if = "Option::is_none")]
    pub max_output_tokens: Option<u32>,
    /// Free-form JSON list of feature flags ("tools", "json_mode",
    /// "structured_outputs"). Compared to the request to support the
    /// OpenRouter `require_parameters` semantics.
    #[serde(rename = "supportedFeatures", default)]
    pub supported_features: Vec<String>,
    #[serde(rename = "inputModalities", default)]
    pub input_modalities: Vec<String>,
    #[serde(rename = "deprecationDate", skip_serializing_if = "Option::is_none")]
    pub deprecation_date: Option<String>,
}

impl ProviderModelRow {
    pub fn prompt_price_usd(&self) -> f64 {
        self.pricing_prompt_usd.parse().unwrap_or(0.0)
    }

    pub fn completion_price_usd(&self) -> f64 {
        self.pricing_completion_usd.parse().unwrap_or(0.0)
    }

    pub fn request_price_usd(&self) -> f64 {
        self.pricing_request_usd
            .as_deref()
            .map(|s| s.parse().unwrap_or(0.0))
            .unwrap_or(0.0)
    }
}

#[derive(Default)]
struct Inner {
    /// All known providers, keyed by provider_id.
    providers: HashMap<String, ProviderRow>,
    /// Reverse index: slug → provider_id.
    by_slug: HashMap<String, String>,
    /// Reverse index: model_id → list of (provider_id, ProviderModelRow).
    /// Populated on every refresh; routing walks this list.
    by_model: HashMap<String, Vec<ProviderModelRow>>,
}

pub struct ProviderRegistry {
    pool: DbPool,
    inner: RwLock<Inner>,
}

impl ProviderRegistry {
    pub fn load(pool: DbPool) -> anyhow::Result<Arc<Self>> {
        let registry = Arc::new(Self {
            pool,
            inner: RwLock::new(Inner::default()),
        });
        registry.refresh()?;
        Ok(registry)
    }

    /// Re-read all rows from the DB. Called at boot and after every admin
    /// mutation so the in-memory snapshot stays consistent.
    pub fn refresh(&self) -> anyhow::Result<()> {
        let conn = self.pool.lock();
        let mut providers: HashMap<String, ProviderRow> = HashMap::new();
        let mut by_slug = HashMap::new();
        {
            let mut stmt = conn.prepare(
                "SELECT provider_id, slug, display_name, base_url, wire_format,
                        auth_header_name, auth_secret_ref, status, data_collection,
                        zdr, quantization, created_at, updated_at
                 FROM providers",
            )?;
            let rows = stmt.query_map([], |row| {
                let status_s: String = row.get(7)?;
                let wire_s: String = row.get(4)?;
                Ok(ProviderRow {
                    provider_id: row.get(0)?,
                    slug: row.get(1)?,
                    display_name: row.get(2)?,
                    base_url: row.get(3)?,
                    wire_format: ProviderWireFormat::parse(&wire_s),
                    auth_header_name: row.get(5)?,
                    auth_secret_ref: row.get(6)?,
                    status: ProviderStatus::parse(&status_s).unwrap_or(ProviderStatus::Disabled),
                    data_collection: row.get(8)?,
                    zdr: row.get::<_, i64>(9)? != 0,
                    quantization: row.get(10)?,
                    created_at: row.get(11)?,
                    updated_at: row.get(12)?,
                })
            })?;
            for r in rows {
                let row = r?;
                by_slug.insert(row.slug.clone(), row.provider_id.clone());
                providers.insert(row.provider_id.clone(), row);
            }
        }

        let mut by_model: HashMap<String, Vec<ProviderModelRow>> = HashMap::new();
        {
            let mut stmt = conn.prepare(
                "SELECT provider_id, model_id, pricing_prompt_usd, pricing_completion_usd,
                        pricing_request_usd, min_context, context_length, max_output_tokens,
                        supported_features, input_modalities, deprecation_date
                 FROM provider_models",
            )?;
            let rows = stmt.query_map([], |row| {
                let features_json: Option<String> = row.get(8)?;
                let modalities_json: Option<String> = row.get(9)?;
                Ok(ProviderModelRow {
                    provider_id: row.get(0)?,
                    model_id: row.get(1)?,
                    pricing_prompt_usd: row.get(2)?,
                    pricing_completion_usd: row.get(3)?,
                    pricing_request_usd: row.get(4)?,
                    min_context: row
                        .get::<_, Option<i64>>(5)?
                        .and_then(|v| u32::try_from(v).ok()),
                    context_length: row.get::<_, i64>(6)? as u32,
                    max_output_tokens: row
                        .get::<_, Option<i64>>(7)?
                        .and_then(|v| u32::try_from(v).ok()),
                    supported_features: features_json
                        .and_then(|s| serde_json::from_str(&s).ok())
                        .unwrap_or_default(),
                    input_modalities: modalities_json
                        .and_then(|s| serde_json::from_str(&s).ok())
                        .unwrap_or_default(),
                    deprecation_date: row.get(10)?,
                })
            })?;
            for r in rows {
                let row = r?;
                by_model.entry(row.model_id.clone()).or_default().push(row);
            }
        }

        let mut inner = self.inner.write();
        inner.providers = providers;
        inner.by_slug = by_slug;
        inner.by_model = by_model;
        Ok(())
    }

    pub fn get(&self, provider_id: &str) -> Option<ProviderRow> {
        self.inner.read().providers.get(provider_id).cloned()
    }

    pub fn by_slug(&self, slug: &str) -> Option<ProviderRow> {
        let inner = self.inner.read();
        inner
            .by_slug
            .get(slug)
            .and_then(|pid| inner.providers.get(pid).cloned())
    }

    /// All active providers serving `model_id` paired with their per-model
    /// row. Disabled providers are filtered out so routing never picks them.
    pub fn lookup_model(&self, model_id: &str) -> Vec<(ProviderRow, ProviderModelRow)> {
        let inner = self.inner.read();
        let candidates = inner.by_model.get(model_id).cloned().unwrap_or_default();
        candidates
            .into_iter()
            .filter_map(|m| {
                let p = inner.providers.get(&m.provider_id)?.clone();
                if p.status != ProviderStatus::Active {
                    return None;
                }
                Some((p, m))
            })
            .collect()
    }

    pub fn list_active_providers(&self) -> Vec<ProviderRow> {
        let inner = self.inner.read();
        inner
            .providers
            .values()
            .filter(|p| p.status == ProviderStatus::Active)
            .cloned()
            .collect()
    }

    pub fn list_models_for(&self, provider_id: &str) -> Vec<ProviderModelRow> {
        let inner = self.inner.read();
        inner
            .by_model
            .values()
            .flatten()
            .filter(|m| m.provider_id == provider_id)
            .cloned()
            .collect()
    }
}

/// Insert or update a provider row. The caller refreshes the registry
/// snapshot afterward.
#[allow(clippy::too_many_arguments)]
pub fn upsert_provider(
    pool: &DbPool,
    provider_id: &str,
    slug: &str,
    display_name: &str,
    base_url: &str,
    wire_format: ProviderWireFormat,
    auth_header_name: &str,
    auth_secret_ref: &str,
    data_collection: &str,
    zdr: bool,
    quantization: Option<&str>,
) -> anyhow::Result<()> {
    let now = crate::db::unix_now();
    let conn = pool.lock();
    conn.execute(
        "INSERT INTO providers
            (provider_id, slug, display_name, base_url, wire_format,
             auth_header_name, auth_secret_ref, status, data_collection,
             zdr, quantization, created_at, updated_at)
         VALUES (?, ?, ?, ?, ?, ?, ?, 'active', ?, ?, ?, ?, ?)
         ON CONFLICT(provider_id) DO UPDATE SET
            slug = excluded.slug,
            display_name = excluded.display_name,
            base_url = excluded.base_url,
            wire_format = excluded.wire_format,
            auth_header_name = excluded.auth_header_name,
            auth_secret_ref = excluded.auth_secret_ref,
            data_collection = excluded.data_collection,
            zdr = excluded.zdr,
            quantization = excluded.quantization,
            updated_at = excluded.updated_at",
        params![
            provider_id,
            slug,
            display_name,
            base_url,
            wire_format.as_str(),
            auth_header_name,
            auth_secret_ref,
            data_collection,
            zdr as i64,
            quantization,
            now,
            now
        ],
    )?;
    Ok(())
}

pub fn set_status(pool: &DbPool, provider_id: &str, status: ProviderStatus) -> anyhow::Result<()> {
    let now = crate::db::unix_now();
    let conn = pool.lock();
    conn.execute(
        "UPDATE providers SET status = ?, updated_at = ? WHERE provider_id = ?",
        params![status.as_str(), now, provider_id],
    )?;
    Ok(())
}

#[allow(clippy::too_many_arguments)]
pub fn upsert_provider_model(
    pool: &DbPool,
    provider_id: &str,
    model_id: &str,
    pricing_prompt_usd: &str,
    pricing_completion_usd: &str,
    pricing_request_usd: Option<&str>,
    min_context: Option<u32>,
    context_length: u32,
    max_output_tokens: Option<u32>,
    supported_features: &[String],
    input_modalities: &[String],
    deprecation_date: Option<&str>,
) -> anyhow::Result<()> {
    let features_json = serde_json::to_string(supported_features)?;
    let modalities_json = serde_json::to_string(input_modalities)?;
    let conn = pool.lock();
    conn.execute(
        "INSERT INTO provider_models
            (provider_id, model_id, pricing_prompt_usd, pricing_completion_usd,
             pricing_request_usd, min_context, context_length, max_output_tokens,
             supported_features, input_modalities, deprecation_date)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
         ON CONFLICT(provider_id, model_id) DO UPDATE SET
            pricing_prompt_usd = excluded.pricing_prompt_usd,
            pricing_completion_usd = excluded.pricing_completion_usd,
            pricing_request_usd = excluded.pricing_request_usd,
            min_context = excluded.min_context,
            context_length = excluded.context_length,
            max_output_tokens = excluded.max_output_tokens,
            supported_features = excluded.supported_features,
            input_modalities = excluded.input_modalities,
            deprecation_date = excluded.deprecation_date",
        params![
            provider_id,
            model_id,
            pricing_prompt_usd,
            pricing_completion_usd,
            pricing_request_usd,
            min_context.map(|v| v as i64),
            context_length as i64,
            max_output_tokens.map(|v| v as i64),
            features_json,
            modalities_json,
            deprecation_date
        ],
    )?;
    Ok(())
}

pub fn delete_provider_model(
    pool: &DbPool,
    provider_id: &str,
    model_id: &str,
) -> anyhow::Result<()> {
    let conn = pool.lock();
    conn.execute(
        "DELETE FROM provider_models WHERE provider_id = ? AND model_id = ?",
        params![provider_id, model_id],
    )?;
    Ok(())
}
