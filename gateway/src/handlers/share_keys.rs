//! Share keys — temporary scoped bearer tokens minted by a device.
//!
//! Motivation: let community members (X/Twitter developers, researchers)
//! try Teale-supplied inference against newly released models without
//! needing their own hardware or an account. An authenticated device
//! mints a key with an expiry and a credit budget; spend is debited from
//! the issuer's wallet and the key is rejected at auth time once its
//! budget is exhausted or its window closes.
//!
//! Endpoints (all but `preview` require a device bearer — static and
//! share-key bearers are rejected so share holders can't daisy-chain):
//!
//!   POST   /v1/auth/keys/share
//!   GET    /v1/auth/keys/share
//!   DELETE /v1/auth/keys/share/:key_id
//!   GET    /v1/auth/keys/share/preview/:token   (public, no auth)

use axum::{
    extract::{Path, State},
    Extension, Json,
};
use serde::{Deserialize, Serialize};

use crate::auth::{AuthPrincipal, PrincipalKind};
use crate::db::DbPool;
use crate::error::GatewayError;
use crate::ledger;
use crate::state::AppState;

fn require_device(principal: &AuthPrincipal) -> Result<&str, GatewayError> {
    match &principal.kind {
        PrincipalKind::Device { device_id } => Ok(device_id.as_str()),
        PrincipalKind::Share { .. } => Err(GatewayError::Unauthorized(
            "share keys cannot mint share keys".into(),
        )),
        PrincipalKind::Static { .. } => Err(GatewayError::Unauthorized(
            "device bearer required".into(),
        )),
    }
}

fn require_pool(state: &AppState) -> Result<&DbPool, GatewayError> {
    state
        .db
        .as_ref()
        .ok_or_else(|| GatewayError::Other(anyhow::anyhow!("db not initialized")))
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MintReq {
    #[serde(default)]
    label: Option<String>,
    expires_in_seconds: i64,
    budget_credits: i64,
}

/// POST /v1/auth/keys/share
pub async fn mint(
    State(state): State<AppState>,
    Extension(principal): Extension<AuthPrincipal>,
    Json(req): Json<MintReq>,
) -> Result<Json<ledger::ShareKeyMinted>, GatewayError> {
    let issuer = require_device(&principal)?;

    // Allowlist gate: only configured issuer devices can mint share keys.
    // Fail-closed when the env var is empty so a deploy without the secret
    // can't be abused.
    if state.share_key_issuers.is_empty() {
        tracing::warn!(
            device = %issuer,
            "share-key mint attempted but GATEWAY_SHARE_KEY_ISSUERS is empty"
        );
        return Err(GatewayError::Forbidden(
            "share-key issuance is not configured on this gateway".into(),
        ));
    }
    if !state.share_key_issuers.is_allowed(issuer) {
        tracing::info!(
            device = %issuer,
            "share-key mint rejected — device not in GATEWAY_SHARE_KEY_ISSUERS"
        );
        return Err(GatewayError::Forbidden(
            "this device is not permitted to mint share keys".into(),
        ));
    }

    let pool = require_pool(&state)?;
    let minted = ledger::mint_share_key(
        pool,
        issuer,
        req.label.as_deref(),
        req.expires_in_seconds,
        req.budget_credits,
    )
    .map_err(|e| GatewayError::BadRequest(e.to_string()))?;
    tracing::info!(
        issuer = %issuer,
        key_id = %minted.key_id,
        budget = %minted.budget_credits,
        expires_at = %minted.expires_at,
        "minted share key"
    );
    Ok(Json(minted))
}

#[derive(Debug, Serialize)]
pub struct ListRes {
    keys: Vec<ledger::ShareKeyPublic>,
}

/// GET /v1/auth/keys/share
pub async fn list(
    State(state): State<AppState>,
    Extension(principal): Extension<AuthPrincipal>,
) -> Result<Json<ListRes>, GatewayError> {
    let issuer = require_device(&principal)?;
    let pool = require_pool(&state)?;
    Ok(Json(ListRes {
        keys: ledger::list_share_keys(pool, issuer),
    }))
}

#[derive(Debug, Serialize)]
pub struct RevokeRes {
    revoked: bool,
}

/// DELETE /v1/auth/keys/share/:key_id
pub async fn revoke(
    State(state): State<AppState>,
    Extension(principal): Extension<AuthPrincipal>,
    Path(key_id): Path<String>,
) -> Result<Json<RevokeRes>, GatewayError> {
    let issuer = require_device(&principal)?;
    let pool = require_pool(&state)?;
    let revoked = ledger::revoke_share_key(pool, issuer, &key_id)
        .map_err(|e| GatewayError::Other(anyhow::anyhow!("revoke: {}", e)))?;
    if !revoked {
        return Err(GatewayError::NotFound("share key not found".into()));
    }
    tracing::info!(issuer = %issuer, key_id = %key_id, "revoked share key");
    Ok(Json(RevokeRes { revoked: true }))
}

/// Preview payload for the public landing page: share-key fields plus a
/// snapshot of the catalog so the page can show "available models" and
/// let the holder swap into the curl snippet without a second round trip.
#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PreviewResponse {
    label: Option<String>,
    budget_credits: i64,
    consumed_credits: i64,
    expires_at: i64,
    issuer_display_name: Option<String>,
    available_models: Vec<PreviewModel>,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PreviewModel {
    id: String,
    params_b: f64,
    #[serde(skip_serializing_if = "Option::is_none")]
    quantization: Option<String>,
}

/// GET /v1/auth/keys/share/preview/:token — public, no auth.
///
/// Returns fields the `/try/:token` landing page needs: the share-key
/// metadata plus the gateway's current catalog (id + params + quantization).
/// The token is the capability — holding it already grants strictly more
/// than the preview, so exposing these fields to anyone with the token is
/// intentional.
pub async fn preview(
    State(state): State<AppState>,
    Path(token): Path<String>,
) -> Result<Json<PreviewResponse>, GatewayError> {
    let pool = require_pool(&state)?;
    let p = ledger::preview_share_key(pool, &token)
        .ok_or_else(|| GatewayError::NotFound("share key not found".into()))?;
    let available_models = state
        .catalog
        .iter()
        .map(|m| PreviewModel {
            id: m.id.clone(),
            params_b: m.params_b,
            quantization: m.quantization.clone(),
        })
        .collect();
    Ok(Json(PreviewResponse {
        label: p.label,
        budget_credits: p.budget_credits,
        consumed_credits: p.consumed_credits,
        expires_at: p.expires_at,
        issuer_display_name: p.issuer_display_name,
        available_models,
    }))
}
