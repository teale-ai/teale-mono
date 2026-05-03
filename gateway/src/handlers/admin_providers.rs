//! Admin endpoints for the centralized 3rd-party provider marketplace.
//!
//! All routes require the same admin scope used by `/v1/admin/mint` etc.

use axum::{
    extract::{Path, State},
    http::StatusCode,
    Extension, Json,
};
use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::auth::{AuthPrincipal, PrincipalKind};
use crate::error::GatewayError;
use crate::ledger;
use crate::providers::registry::{self as provreg, ProviderStatus, ProviderWireFormat};
use crate::state::AppState;

fn require_admin(principal: &AuthPrincipal) -> Result<(), GatewayError> {
    match &principal.kind {
        PrincipalKind::Static { .. } => Ok(()),
        _ => Err(GatewayError::Forbidden(
            "admin endpoints require a static bearer".into(),
        )),
    }
}

#[derive(Debug, Deserialize)]
pub struct CreateProviderBody {
    pub slug: String,
    #[serde(rename = "displayName")]
    pub display_name: String,
    #[serde(rename = "baseURL")]
    pub base_url: String,
    #[serde(rename = "wireFormat", default)]
    pub wire_format: Option<String>,
    #[serde(rename = "authHeaderName", default)]
    pub auth_header_name: Option<String>,
    /// Env var name that holds the secret. Never the raw secret.
    #[serde(rename = "authSecretRef")]
    pub auth_secret_ref: String,
    #[serde(rename = "dataCollection", default)]
    pub data_collection: Option<String>,
    #[serde(default)]
    pub zdr: Option<bool>,
    #[serde(default)]
    pub quantization: Option<String>,
}

#[derive(Debug, Serialize)]
pub struct CreateProviderResponse {
    #[serde(rename = "providerID")]
    pub provider_id: String,
}

pub async fn create_provider(
    State(state): State<AppState>,
    Extension(principal): Extension<AuthPrincipal>,
    Json(body): Json<CreateProviderBody>,
) -> Result<Json<CreateProviderResponse>, GatewayError> {
    require_admin(&principal)?;
    let pool = state
        .db
        .as_ref()
        .ok_or_else(|| GatewayError::Other(anyhow::anyhow!("ledger not initialized")))?;

    let provider_id = format!("prov_{}", uuid::Uuid::new_v4().simple());
    let wire = body
        .wire_format
        .as_deref()
        .map(ProviderWireFormat::parse)
        .unwrap_or(ProviderWireFormat::Openai);

    provreg::upsert_provider(
        pool,
        &provider_id,
        &body.slug,
        &body.display_name,
        &body.base_url,
        wire,
        body.auth_header_name.as_deref().unwrap_or("Authorization"),
        &body.auth_secret_ref,
        body.data_collection.as_deref().unwrap_or("allow"),
        body.zdr.unwrap_or(false),
        body.quantization.as_deref(),
    )
    .map_err(|e| GatewayError::Other(anyhow::anyhow!(format!("upsert provider: {}", e))))?;

    state
        .providers
        .registry
        .refresh()
        .map_err(|e| GatewayError::Other(anyhow::anyhow!(format!("refresh: {}", e))))?;

    Ok(Json(CreateProviderResponse { provider_id }))
}

#[derive(Debug, Deserialize)]
pub struct ProviderModelEntry {
    /// OpenRouter shape: `id`, `pricing.prompt`, `pricing.completion`, etc.
    pub id: String,
    pub pricing: PricingShape,
    #[serde(default, rename = "context_length")]
    pub context_length: Option<u32>,
    #[serde(default, rename = "max_output_tokens")]
    pub max_output_tokens: Option<u32>,
    #[serde(default, rename = "min_context")]
    pub min_context: Option<u32>,
    #[serde(default, rename = "supported_features")]
    pub supported_features: Vec<String>,
    #[serde(default, rename = "input_modalities")]
    pub input_modalities: Vec<String>,
    #[serde(default, rename = "deprecation_date")]
    pub deprecation_date: Option<String>,
}

#[derive(Debug, Deserialize)]
pub struct PricingShape {
    pub prompt: String,
    pub completion: String,
    #[serde(default)]
    pub request: Option<String>,
}

#[derive(Debug, Deserialize)]
pub struct UpsertModelsBody {
    pub data: Vec<ProviderModelEntry>,
}

#[derive(Debug, Serialize)]
pub struct UpsertModelsResponse {
    pub upserted: usize,
}

pub async fn upsert_models(
    State(state): State<AppState>,
    Path(provider_id): Path<String>,
    Extension(principal): Extension<AuthPrincipal>,
    Json(body): Json<UpsertModelsBody>,
) -> Result<Json<UpsertModelsResponse>, GatewayError> {
    require_admin(&principal)?;
    let pool = state
        .db
        .as_ref()
        .ok_or_else(|| GatewayError::Other(anyhow::anyhow!("ledger not initialized")))?;

    if state.providers.registry.get(&provider_id).is_none() {
        return Err(GatewayError::BadRequest(format!(
            "unknown provider {}",
            provider_id
        )));
    }

    let mut upserted = 0;
    for m in &body.data {
        provreg::upsert_provider_model(
            pool,
            &provider_id,
            &m.id,
            &m.pricing.prompt,
            &m.pricing.completion,
            m.pricing.request.as_deref(),
            m.min_context,
            m.context_length.unwrap_or(0),
            m.max_output_tokens,
            &m.supported_features,
            &m.input_modalities,
            m.deprecation_date.as_deref(),
        )
        .map_err(|e| GatewayError::Other(anyhow::anyhow!(format!("upsert model: {}", e))))?;
        upserted += 1;
    }

    state
        .providers
        .registry
        .refresh()
        .map_err(|e| GatewayError::Other(anyhow::anyhow!(format!("refresh: {}", e))))?;

    Ok(Json(UpsertModelsResponse { upserted }))
}

pub async fn enable_provider(
    State(state): State<AppState>,
    Path(provider_id): Path<String>,
    Extension(principal): Extension<AuthPrincipal>,
) -> Result<StatusCode, GatewayError> {
    set_provider_status(state, principal, &provider_id, ProviderStatus::Active).await
}

pub async fn disable_provider(
    State(state): State<AppState>,
    Path(provider_id): Path<String>,
    Extension(principal): Extension<AuthPrincipal>,
) -> Result<StatusCode, GatewayError> {
    set_provider_status(state, principal, &provider_id, ProviderStatus::Disabled).await
}

async fn set_provider_status(
    state: AppState,
    principal: AuthPrincipal,
    provider_id: &str,
    status: ProviderStatus,
) -> Result<StatusCode, GatewayError> {
    require_admin(&principal)?;
    let pool = state
        .db
        .as_ref()
        .ok_or_else(|| GatewayError::Other(anyhow::anyhow!("ledger not initialized")))?;
    provreg::set_status(pool, provider_id, status)
        .map_err(|e| GatewayError::Other(anyhow::anyhow!(format!("set status: {}", e))))?;
    state
        .providers
        .registry
        .refresh()
        .map_err(|e| GatewayError::Other(anyhow::anyhow!(format!("refresh: {}", e))))?;
    Ok(StatusCode::NO_CONTENT)
}

#[derive(Debug, Deserialize)]
pub struct PayoutBody {
    pub amount: i64,
    #[serde(default)]
    pub destination: Option<String>,
}

pub async fn payout_provider(
    State(state): State<AppState>,
    Path(provider_id): Path<String>,
    Extension(principal): Extension<AuthPrincipal>,
    Json(body): Json<PayoutBody>,
) -> Result<Json<Value>, GatewayError> {
    require_admin(&principal)?;
    let pool = state
        .db
        .as_ref()
        .ok_or_else(|| GatewayError::Other(anyhow::anyhow!("ledger not initialized")))?;
    if state.providers.registry.get(&provider_id).is_none() {
        return Err(GatewayError::BadRequest(format!(
            "unknown provider {}",
            provider_id
        )));
    }
    ledger::record_provider_payout(pool, &provider_id, body.amount, body.destination.as_deref())
        .map_err(|e| GatewayError::BadRequest(format!("payout: {}", e)))?;
    Ok(Json(serde_json::json!({ "ok": true })))
}
