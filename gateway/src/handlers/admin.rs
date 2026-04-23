//! Admin-only endpoints.
//!
//! Operator endpoints for credit top-ups and share-key maintenance. Gated by a **static** bearer (from
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

/// POST /v1/admin/refund-expired-share-keys — refund any expired, still-open
/// funded share keys back to their original funders.
pub async fn refund_expired_share_keys(
    State(state): State<AppState>,
    Extension(principal): Extension<AuthPrincipal>,
) -> Result<Json<ledger::ExpiredShareKeyRefundReport>, GatewayError> {
    require_static(&principal)?;
    let pool = require_pool(&state)?;
    let report = ledger::refund_expired_share_keys(pool)
        .map_err(|e| GatewayError::Other(anyhow::anyhow!("refund-expired-share-keys: {}", e)))?;
    tracing::info!(
        keys_closed = report.keys_closed,
        contributions_refunded = report.contributions_refunded,
        credits_refunded = report.credits_refunded,
        "admin refunded expired share keys"
    );
    Ok(Json(report))
}

#[cfg(test)]
mod tests {
    use std::sync::Arc;

    use axum::Extension;
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

    fn test_state() -> AppState {
        let cfg = Config::defaults();
        AppState {
            config: cfg.clone(),
            tokens: TokenTable::default(),
            registry: Registry::new(cfg.reliability.clone()),
            scheduler: Arc::new(Scheduler::new(cfg.scheduler.clone())),
            relay: RelayHandle::test_handle(),
            catalog: Arc::new(vec![]),
            db: Some(open_in_memory().unwrap()),
            group_tx: broadcast::channel(8).0,
            model_metrics: Arc::new(ModelMetricsTracker::new()),
            share_key_issuers: ShareKeyIssuers::from_env("TEALE_ADMIN_TEST_ISSUERS"),
        }
    }

    #[tokio::test]
    async fn refund_expired_share_keys_requires_static_bearer() {
        let state = test_state();
        let err = refund_expired_share_keys(
            State(state),
            Extension(AuthPrincipal {
                kind: PrincipalKind::Device {
                    device_id: "dev".into(),
                },
            }),
        )
        .await
        .unwrap_err();
        assert!(matches!(err, GatewayError::Forbidden(_)));
    }

    #[tokio::test]
    async fn refund_expired_share_keys_returns_report_for_static_bearer() {
        let state = test_state();
        let pool = state.db.as_ref().unwrap().clone();
        ledger::upsert_device(&pool, "issuer").unwrap();
        ledger::record_bonus(&pool, "issuer", 50).unwrap();
        let minted = ledger::mint_share_key(&pool, "issuer", None, 3600, 50).unwrap();
        {
            let conn = pool.lock();
            conn.execute(
                "UPDATE share_keys SET expires_at = ? WHERE key_id = ?",
                rusqlite::params![crate::db::unix_now() - 1, minted.key_id],
            )
            .unwrap();
        }

        let Json(report) = refund_expired_share_keys(
            State(state),
            Extension(AuthPrincipal {
                kind: PrincipalKind::Static {
                    scope: "admin".into(),
                },
            }),
        )
        .await
        .unwrap();
        assert_eq!(report.keys_closed, 1);
        assert_eq!(report.credits_refunded, 50);
    }
}
