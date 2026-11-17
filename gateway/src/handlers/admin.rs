//! Admin-only endpoints.
//!
//! Operator endpoints for credit top-ups and share-key maintenance. Gated by
//! a **static** bearer (from `GATEWAY_TOKENS` env) whose scope is `admin` or
//! `internal`. Device, share-key, session and partner-scoped (e.g.
//! `openrouter`) bearers are rejected so they can never mint.

use axum::{extract::State, Extension, Json};
use serde::{Deserialize, Serialize};

use crate::auth::{self, AuthPrincipal};
use crate::db::DbPool;
use crate::error::GatewayError;
use crate::ledger;
use crate::solana;
use crate::state::AppState;

fn require_static(principal: &AuthPrincipal) -> Result<(), GatewayError> {
    auth::require_admin_scope(principal)
}

/// Env var that must be `1` for `/v1/admin/reset-genesis` to run at all.
pub const RESET_GENESIS_ENV: &str = "TEALE_ALLOW_RESET_GENESIS";
/// Exact confirmation value required in the reset-genesis request body.
pub const RESET_GENESIS_CONFIRM: &str = "reset-genesis";

#[derive(Debug, Deserialize)]
pub struct ResetGenesisReq {
    #[serde(default)]
    pub confirm: String,
}

/// Reset-genesis wipes every wallet and ledger row, so it needs both an
/// operator opt-in on the machine and an explicit confirmation in the body.
fn check_reset_genesis_guard(
    allow_env: Option<&str>,
    body: Option<&ResetGenesisReq>,
) -> Result<(), GatewayError> {
    if allow_env.map(str::trim) != Some("1") {
        return Err(GatewayError::Forbidden(format!(
            "reset-genesis is disabled; set {RESET_GENESIS_ENV}=1 on the gateway to enable it"
        )));
    }
    match body {
        Some(req) if req.confirm == RESET_GENESIS_CONFIRM => Ok(()),
        _ => Err(GatewayError::BadRequest(format!(
            "body must be {{\"confirm\":\"{RESET_GENESIS_CONFIRM}\"}}"
        ))),
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

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CompleteWithdrawalReq {
    pub request_id: String,
    pub tx_signature: String,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PendingWithdrawalsRes {
    pub withdrawals: Vec<ledger::AccountWithdrawalRecord>,
}

/// GET /v1/admin/pending-withdrawals - ops queue of withdrawal requests
/// waiting for a manual treasury payout.
pub async fn pending_withdrawals(
    State(state): State<AppState>,
    Extension(principal): Extension<AuthPrincipal>,
) -> Result<Json<PendingWithdrawalsRes>, GatewayError> {
    require_static(&principal)?;
    let pool = require_pool(&state)?;
    let withdrawals = ledger::list_pending_withdrawals(pool, 100)
        .map_err(|e| GatewayError::Other(anyhow::anyhow!("pending-withdrawals: {}", e)))?;
    Ok(Json(PendingWithdrawalsRes { withdrawals }))
}

/// POST /v1/admin/complete-withdrawal - mark a pending withdrawal paid after
/// ops manually sends the USDC from the treasury. The tx is verified on-chain
/// (treasury debited exactly gross-minus-fee, destination credited the same,
/// no other recipients) before the ledger burns the credits.
pub async fn complete_withdrawal(
    State(state): State<AppState>,
    Extension(principal): Extension<AuthPrincipal>,
    Json(req): Json<CompleteWithdrawalReq>,
) -> Result<Json<ledger::AccountWithdrawalRecord>, GatewayError> {
    require_static(&principal)?;
    let pool = require_pool(&state)?;
    let pending = ledger::get_withdrawal_by_request(pool, &req.request_id)
        .map_err(|e| GatewayError::Other(anyhow::anyhow!("complete-withdrawal: {}", e)))?
        .filter(|w| w.status == "pending")
        .ok_or_else(|| GatewayError::BadRequest("no pending withdrawal for request id".into()))?;
    let verified = solana::verify_treasury_payout(
        &state.config.solana,
        &req.tx_signature,
        &pending.destination_address,
        pending.amount_usdc_cents,
    )
    .await
    .map_err(|e| GatewayError::BadRequest(format!("payout verification failed: {e}")))?;
    let record = ledger::complete_account_withdrawal_from_treasury(
        pool,
        &req.request_id,
        &verified.tx_signature,
    )
    .map_err(|e| GatewayError::Other(anyhow::anyhow!("complete-withdrawal: {}", e)))?;
    tracing::info!(
        request_id = %req.request_id,
        tx = %verified.tx_signature,
        gross_cents = verified.gross_amount_usdc_cents,
        "admin completed treasury payout"
    );
    Ok(Json(record))
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RejectWithdrawalReq {
    pub request_id: String,
    pub reason: Option<String>,
}

/// POST /v1/admin/reject-withdrawal - reject a pending withdrawal and refund
/// the reserved credits in full (e.g. destination failed review).
pub async fn reject_withdrawal(
    State(state): State<AppState>,
    Extension(principal): Extension<AuthPrincipal>,
    Json(req): Json<RejectWithdrawalReq>,
) -> Result<Json<ledger::AccountWithdrawalRecord>, GatewayError> {
    require_static(&principal)?;
    let pool = require_pool(&state)?;
    let record = ledger::reject_account_withdrawal(pool, &req.request_id, req.reason.as_deref())
        .map_err(|e| GatewayError::Other(anyhow::anyhow!("reject-withdrawal: {}", e)))?;
    tracing::info!(request_id = %req.request_id, "admin rejected withdrawal, reserve refunded");
    Ok(Json(record))
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

/// POST /v1/admin/reset-genesis — clear wallet, auth, referral, and on-chain
/// accounting state so the network starts from a clean slate. Requires an
/// admin-scoped static bearer, `TEALE_ALLOW_RESET_GENESIS=1` and the body
/// `{"confirm":"reset-genesis"}`.
pub async fn reset_genesis(
    State(state): State<AppState>,
    Extension(principal): Extension<AuthPrincipal>,
    body: Option<Json<ResetGenesisReq>>,
) -> Result<Json<ledger::GenesisResetReport>, GatewayError> {
    require_static(&principal)?;
    let allow_env = std::env::var(RESET_GENESIS_ENV).ok();
    check_reset_genesis_guard(allow_env.as_deref(), body.as_ref().map(|b| &b.0))?;
    let pool = require_pool(&state)?;
    let report = ledger::reset_genesis(pool)
        .map_err(|e| GatewayError::Other(anyhow::anyhow!("reset-genesis: {}", e)))?;
    tracing::warn!(
        devices_cleared = report.devices_cleared,
        account_wallets_cleared = report.account_wallets_cleared,
        "admin reset gateway state to genesis"
    );
    Ok(Json(report))
}

#[cfg(test)]
mod tests {
    use std::sync::Arc;

    use axum::Extension;
    use tokio::sync::broadcast;

    use crate::auth::{PrincipalKind, TokenTable};
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
            providers: crate::providers::ProvidersHandle::empty_for_test(),
            identity: None,
            pin_join_limiter: Default::default(),
            challenge_limiter: Default::default(),
            started_at: std::time::Instant::now(),
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

    #[tokio::test]
    async fn reset_genesis_requires_static_bearer() {
        let state = test_state();
        let err = reset_genesis(
            State(state),
            Extension(AuthPrincipal {
                kind: PrincipalKind::Device {
                    device_id: "dev".into(),
                },
            }),
            None,
        )
        .await
        .unwrap_err();
        assert!(matches!(err, GatewayError::Forbidden(_)));
    }

    fn partner() -> Extension<AuthPrincipal> {
        Extension(AuthPrincipal {
            kind: PrincipalKind::Static {
                scope: "openrouter".into(),
            },
        })
    }

    #[tokio::test]
    async fn partner_scoped_static_tokens_cannot_call_admin_endpoints() {
        let state = test_state();
        let err = mint(
            State(state.clone()),
            partner(),
            Json(MintReq {
                device_id: "dev".into(),
                amount: 1,
                note: None,
            }),
        )
        .await
        .unwrap_err();
        assert!(matches!(err, GatewayError::Forbidden(_)));
        let confirm = Json(ResetGenesisReq {
            confirm: RESET_GENESIS_CONFIRM.into(),
        });
        let err = reset_genesis(State(state), partner(), Some(confirm))
            .await
            .unwrap_err();
        assert!(matches!(err, GatewayError::Forbidden(_)));
    }

    #[test]
    fn reset_genesis_needs_env_opt_in_and_confirmation() {
        let confirmed = ResetGenesisReq {
            confirm: RESET_GENESIS_CONFIRM.into(),
        };
        let wrong = ResetGenesisReq {
            confirm: "yes".into(),
        };
        assert!(matches!(
            check_reset_genesis_guard(None, Some(&confirmed)),
            Err(GatewayError::Forbidden(_))
        ));
        assert!(matches!(
            check_reset_genesis_guard(Some("0"), Some(&confirmed)),
            Err(GatewayError::Forbidden(_))
        ));
        assert!(matches!(
            check_reset_genesis_guard(Some("1"), None),
            Err(GatewayError::BadRequest(_))
        ));
        assert!(matches!(
            check_reset_genesis_guard(Some("1"), Some(&wrong)),
            Err(GatewayError::BadRequest(_))
        ));
        assert!(check_reset_genesis_guard(Some("1"), Some(&confirmed)).is_ok());
    }
}
