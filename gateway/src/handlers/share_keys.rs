//! Share keys — temporary scoped bearer tokens minted by a device.
//!
//! Motivation: let community members (X/Twitter developers, researchers)
//! try Teale-supplied inference against newly released models without
//! needing their own hardware or an account. An authenticated device
//! mints a key with an expiry and a credit budget; the key owns a funded
//! pool that can receive additional credits via a public funding identifier,
//! and the key is rejected at auth time once its budget is exhausted or its
//! window closes.
//!
//! Endpoints (all but `preview` require a device bearer — static and
//! share-key bearers are rejected so share holders can't daisy-chain):
//!
//!   POST   /v1/auth/keys/share
//!   GET    /v1/auth/keys/share
//!   POST   /v1/auth/keys/share/fund
//!   DELETE /v1/auth/keys/share/:key_id
//!   GET    /v1/auth/keys/share/preview/:token   (public, no auth)
//!   GET    /v1/auth/keys/share/funding/:funding_id   (public, no auth)

use axum::{
    extract::{Path, State},
    Extension, Json,
};
use serde::{Deserialize, Serialize};

use crate::auth::{AuthPrincipal, PrincipalKind};
use crate::catalog;
use crate::db::DbPool;
use crate::error::GatewayError;
use crate::ledger;
use crate::state::AppState;

fn require_device(principal: &AuthPrincipal) -> Result<&str, GatewayError> {
    match &principal.kind {
        PrincipalKind::Device { device_id } => Ok(device_id.as_str()),
        PrincipalKind::Account { .. } => Err(GatewayError::Unauthorized(
            "account API keys cannot call device-only share-key endpoints".into(),
        )),
        PrincipalKind::Share { .. } => Err(GatewayError::Unauthorized(
            "share keys cannot call device-only share-key endpoints".into(),
        )),
        PrincipalKind::Static { .. } => {
            Err(GatewayError::Unauthorized("device bearer required".into()))
        }
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

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct FundReq {
    funding_id: String,
    amount_credits: i64,
}

/// POST /v1/auth/keys/share/fund
pub async fn fund(
    State(state): State<AppState>,
    Extension(principal): Extension<AuthPrincipal>,
    Json(req): Json<FundReq>,
) -> Result<Json<ledger::ShareKeyFundingReceipt>, GatewayError> {
    let sender = require_device(&principal)?;
    if req.amount_credits <= 0 {
        return Err(GatewayError::BadRequest("amountCredits must be > 0".into()));
    }
    let pool = require_pool(&state)?;
    let receipt = ledger::transfer_to_share_key(pool, sender, &req.funding_id, req.amount_credits)
        .map_err(|e| match e {
            ledger::FundShareKeyError::NotFound => {
                GatewayError::NotFound("share key funding target not found".into())
            }
            ledger::FundShareKeyError::Revoked => {
                GatewayError::Conflict("share key is revoked".into())
            }
            ledger::FundShareKeyError::Expired => {
                GatewayError::Conflict("share key is expired".into())
            }
            ledger::FundShareKeyError::NotMigrated => GatewayError::Conflict(
                "share key is not yet migrated to the funded-pool model".into(),
            ),
            ledger::FundShareKeyError::InsufficientBalance { balance, required } => {
                GatewayError::InsufficientCredits { balance, required }
            }
        })?;
    tracing::info!(
        sender = %sender,
        funding_id = %receipt.funding_id,
        key_id = %receipt.key_id,
        funded_credits = receipt.funded_credits,
        "funded share key"
    );
    Ok(Json(receipt))
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
    /// Availability tier computed from live fleet state:
    /// `ready` (loaded now), `warm` (swappable on disk), `cold` (can fit, not cached),
    /// or `unavailable` (no device can fit the model).
    status: &'static str,
    /// Rough size estimate in GB used to compute `status`. Lets the client
    /// annotate rows without re-deriving the heuristic.
    estimated_size_gb: f64,
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
        .map(|m| {
            let size_gb = catalog::estimated_size_gb(m.params_b, m.quantization.as_deref());
            let status = state.registry.model_availability(&m.id, size_gb).as_str();
            PreviewModel {
                id: m.id.clone(),
                params_b: m.params_b,
                quantization: m.quantization.clone(),
                status,
                estimated_size_gb: (size_gb * 10.0).round() / 10.0,
            }
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

/// GET /v1/auth/keys/share/funding/:funding_id — public, no auth.
pub async fn funding_preview(
    State(state): State<AppState>,
    Path(funding_id): Path<String>,
) -> Result<Json<ledger::ShareKeyFundingPreview>, GatewayError> {
    let pool = require_pool(&state)?;
    let preview = ledger::preview_share_key_funding(pool, &funding_id)
        .ok_or_else(|| GatewayError::NotFound("share key funding target not found".into()))?;
    Ok(Json(preview))
}

#[cfg(test)]
mod tests {
    use std::sync::Arc;

    use axum::{extract::Path, Extension, Json};
    use tokio::sync::broadcast;

    use crate::auth::TokenTable;
    use crate::config::Config;
    use crate::db::open_in_memory;
    use crate::ledger;
    use crate::model_metrics::ModelMetricsTracker;
    use crate::registry::Registry;
    use crate::relay_client::RelayHandle;
    use crate::scheduler::Scheduler;
    use crate::state::ShareKeyIssuers;

    use super::*;

    fn test_state(pool: DbPool, issuer_env_value: Option<&str>) -> AppState {
        let cfg = Config::defaults();
        let env_name = "TEALE_TEST_SHARE_KEY_ISSUERS";
        match issuer_env_value {
            Some(value) => std::env::set_var(env_name, value),
            None => std::env::remove_var(env_name),
        }
        let share_key_issuers = ShareKeyIssuers::from_env(env_name);
        std::env::remove_var(env_name);

        AppState {
            config: cfg.clone(),
            tokens: TokenTable::default(),
            registry: Registry::new(cfg.reliability.clone()),
            scheduler: Arc::new(Scheduler::new(cfg.scheduler.clone())),
            relay: RelayHandle::test_handle(),
            catalog: Arc::new(vec![]),
            db: Some(pool),
            group_tx: broadcast::channel(8).0,
            model_metrics: Arc::new(ModelMetricsTracker::new()),
            share_key_issuers,
            providers: crate::providers::ProvidersHandle::empty_for_test(),
        }
    }

    #[tokio::test]
    async fn fund_handler_rejects_non_device_bearers() {
        let pool = open_in_memory().unwrap();
        let state = test_state(pool, None);
        let req = FundReq {
            funding_id: "skf_missing".into(),
            amount_credits: 10,
        };

        let static_err = fund(
            State(state.clone()),
            Extension(AuthPrincipal {
                kind: PrincipalKind::Static {
                    scope: "admin".into(),
                },
            }),
            Json(FundReq {
                funding_id: req.funding_id.clone(),
                amount_credits: req.amount_credits,
            }),
        )
        .await
        .unwrap_err();
        assert!(matches!(static_err, GatewayError::Unauthorized(_)));

        let share_err = fund(
            State(state),
            Extension(AuthPrincipal {
                kind: PrincipalKind::Share {
                    issuer_device_id: "issuer".into(),
                    key_id: "key".into(),
                    budget_remaining: 10,
                },
            }),
            Json(req),
        )
        .await
        .unwrap_err();
        assert!(matches!(share_err, GatewayError::Unauthorized(_)));
    }

    #[tokio::test]
    async fn fund_handler_accepts_device_bearer() {
        let pool = open_in_memory().unwrap();
        for device in &["issuer", "donor"] {
            ledger::upsert_device(&pool, device).unwrap();
        }
        ledger::record_bonus(&pool, "issuer", 100).unwrap();
        ledger::record_bonus(&pool, "donor", 25).unwrap();
        let minted = ledger::mint_share_key(&pool, "issuer", None, 3600, 100).unwrap();
        let state = test_state(pool, None);

        let Json(res) = fund(
            State(state),
            Extension(AuthPrincipal {
                kind: PrincipalKind::Device {
                    device_id: "donor".into(),
                },
            }),
            Json(FundReq {
                funding_id: minted.funding_id.clone(),
                amount_credits: 25,
            }),
        )
        .await
        .unwrap();
        assert_eq!(res.funding_id, minted.funding_id);
        assert_eq!(res.sender_balance_credits, 0);
        assert_eq!(res.remaining_credits, 125);
    }

    #[tokio::test]
    async fn funding_preview_never_exposes_raw_token() {
        let pool = open_in_memory().unwrap();
        ledger::upsert_device(&pool, "issuer").unwrap();
        ledger::record_bonus(&pool, "issuer", 100).unwrap();
        let minted = ledger::mint_share_key(&pool, "issuer", Some("demo"), 3600, 100).unwrap();
        let state = test_state(pool, None);

        let Json(preview) = funding_preview(State(state), Path(minted.funding_id.clone()))
            .await
            .unwrap();
        let body = serde_json::to_string(&preview).unwrap();
        assert!(body.contains(&minted.funding_id));
        assert!(!body.contains(&minted.token));
    }

    #[tokio::test]
    async fn mint_and_list_include_funding_id() {
        let pool = open_in_memory().unwrap();
        ledger::upsert_device(&pool, "issuer").unwrap();
        ledger::record_bonus(&pool, "issuer", 100).unwrap();
        let state = test_state(pool, Some("issuer"));

        let Json(minted) = mint(
            State(state.clone()),
            Extension(AuthPrincipal {
                kind: PrincipalKind::Device {
                    device_id: "issuer".into(),
                },
            }),
            Json(MintReq {
                label: Some("demo".into()),
                expires_in_seconds: 3600,
                budget_credits: 100,
            }),
        )
        .await
        .unwrap();
        assert!(minted.funding_id.starts_with("skf_"));

        let Json(listed) = list(
            State(state),
            Extension(AuthPrincipal {
                kind: PrincipalKind::Device {
                    device_id: "issuer".into(),
                },
            }),
        )
        .await
        .unwrap();
        assert_eq!(listed.keys.len(), 1);
        assert_eq!(listed.keys[0].funding_id, minted.funding_id);
    }
}
