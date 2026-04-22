//! Admin-only endpoints.
//!
//! Currently just credit top-ups. Gated by a **static** bearer (from
//! `GATEWAY_TOKENS` env). Device and share-key bearers are rejected so
//! user-scoped tokens can never mint.

use axum::{extract::State, Extension, Json};
use serde::{Deserialize, Serialize};

use crate::auth::{AuthPrincipal, PrincipalKind};
use crate::db::DbPool;
use crate::error::GatewayError;
use crate::ledger;
use crate::state::AppState;

fn require_static(principal: &AuthPrincipal) -> Result<(), GatewayError> {
    match &principal.kind {
        PrincipalKind::Static { .. } => Ok(()),
        _ => Err(GatewayError::Forbidden(
            "admin endpoints require a static bearer".into(),
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
    /// Target device id (64-char hex, as issued by /v1/auth/device/exchange).
    pub device_id: String,
    /// Credits to mint (1 credit = $0.000001).
    pub amount: i64,
    /// Free-form note persisted on the ledger row for audit.
    #[serde(default)]
    pub note: Option<String>,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct MintRes {
    pub device_id: String,
    pub minted_credits: i64,
    pub balance_credits: i64,
}

/// POST /v1/admin/mint — credit a device wallet from the mint pool.
pub async fn mint(
    State(state): State<AppState>,
    Extension(principal): Extension<AuthPrincipal>,
    Json(req): Json<MintReq>,
) -> Result<Json<MintRes>, GatewayError> {
    require_static(&principal)?;
    if req.amount <= 0 {
        return Err(GatewayError::BadRequest("amount must be > 0".into()));
    }
    let pool = require_pool(&state)?;
    let note = req.note.as_deref().unwrap_or("admin top-up");
    let balance = ledger::admin_mint(pool, &req.device_id, req.amount, note)
        .map_err(|e| GatewayError::Other(anyhow::anyhow!("admin_mint: {}", e)))?;
    tracing::info!(
        device_id = %req.device_id,
        amount = req.amount,
        new_balance = balance,
        "admin minted credits"
    );
    Ok(Json(MintRes {
        device_id: req.device_id,
        minted_credits: req.amount,
        balance_credits: balance,
    }))
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct MigrateShareKeysRes {
    pub funded_fully: usize,
    pub funded_partially: usize,
    pub skipped_revoked: usize,
    pub total_debited_credits: i64,
    pub total_shrunk_credits: i64,
}

/// POST /v1/admin/migrate-share-keys — retroactively pre-fund any
/// `funded=0` share keys out of their issuers' wallets. Run this AFTER
/// topping up issuer wallets so existing keys keep their original budgets
/// instead of getting shrunk by the migration.
pub async fn migrate_share_keys(
    State(state): State<AppState>,
    Extension(principal): Extension<AuthPrincipal>,
) -> Result<Json<MigrateShareKeysRes>, GatewayError> {
    require_static(&principal)?;
    let pool = require_pool(&state)?;
    let report = ledger::migrate_unfunded_share_keys(pool)
        .map_err(|e| GatewayError::Other(anyhow::anyhow!("migrate: {}", e)))?;
    tracing::info!(
        funded_fully = report.funded_fully,
        funded_partially = report.funded_partially,
        skipped_revoked = report.skipped_revoked,
        total_debited = report.total_debited_credits,
        total_shrunk = report.total_shrunk_credits,
        "admin ran share-key funding migration"
    );
    Ok(Json(MigrateShareKeysRes {
        funded_fully: report.funded_fully,
        funded_partially: report.funded_partially,
        skipped_revoked: report.skipped_revoked,
        total_debited_credits: report.total_debited_credits,
        total_shrunk_credits: report.total_shrunk_credits,
    }))
}
