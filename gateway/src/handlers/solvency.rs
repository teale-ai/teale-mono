//! GET /v1/solvency - public proof-of-reserves view: outstanding credit
//! liabilities vs the on-chain USDC treasury that backs them. Anyone can
//! cross-check the treasury figure against a Solana explorer.

use axum::{extract::State, Json};
use serde_json::{json, Value};

use crate::db::unix_now;
use crate::error::GatewayError;
use crate::ledger;
use crate::solana;
use crate::state::AppState;

pub async fn solvency(State(state): State<AppState>) -> Result<Json<Value>, GatewayError> {
    let pool = state
        .db
        .as_ref()
        .ok_or_else(|| GatewayError::Other(anyhow::anyhow!("db not initialized")))?;
    let liabilities = ledger::solvency_liabilities(pool)
        .map_err(|e| GatewayError::Other(anyhow::anyhow!("solvency: {}", e)))?;

    let treasury_micro = solana::treasury_usdc_balance_micro(&state.config.solana)
        .await
        .map_err(GatewayError::Upstream)?;

    // Credits are 1M per $1 = 10k per cent; USDC micro are 1M per $1.
    // So credits and USDC-micro share the same scale: 1 credit == 1 micro-USDC.
    let outstanding_credits = liabilities.device_credits + liabilities.account_credits;
    let pending_micro = liabilities.pending_withdrawal_usdc_cents * 10_000;
    let total_liabilities_micro = outstanding_credits + pending_micro;
    let coverage_bps = if total_liabilities_micro > 0 {
        treasury_micro.saturating_mul(10_000) / total_liabilities_micro
    } else {
        10_000
    };

    Ok(Json(json!({
        "treasuryAddress": state.config.solana.treasury_address,
        "treasuryUsdcMicro": treasury_micro,
        "treasuryUsdc": treasury_micro as f64 / 1_000_000.0,
        "deviceCreditsOutstanding": liabilities.device_credits,
        "accountCreditsOutstanding": liabilities.account_credits,
        "pendingWithdrawalUsdcCents": liabilities.pending_withdrawal_usdc_cents,
        "outstandingCreditsTotal": outstanding_credits,
        "totalLiabilitiesUsdcMicro": total_liabilities_micro,
        "coverageBps": coverage_bps,
        "coverageRatio": coverage_bps as f64 / 10_000.0,
        "creditsPerUsdc": 1_000_000i64,
        "explorerUrl": format!(
            "https://solscan.io/account/{}",
            state.config.solana.treasury_address
        ),
        "computedAt": unix_now(),
    })))
}
