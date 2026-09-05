//! GET /v1/solvency - public proof-of-reserves view: outstanding credit
//! liabilities vs the on-chain USDC treasury that backs them. Anyone can
//! cross-check the treasury figure against a Solana explorer.

use axum::{extract::State, Json};
use serde_json::{json, Value};

use crate::db::unix_now;

/// Live SOL/USD spot price from Coinbase's public market-data API (no auth).
/// Source: https://api.coinbase.com/v2/prices/SOL-USD/spot
async fn fetch_sol_usd_price() -> Result<f64, String> {
    let client = reqwest::Client::builder()
        .timeout(std::time::Duration::from_secs(10))
        .build()
        .map_err(|e| e.to_string())?;
    let resp: Value = client
        .get("https://api.coinbase.com/v2/prices/SOL-USD/spot")
        .send()
        .await
        .map_err(|e| e.to_string())?
        .json()
        .await
        .map_err(|e| e.to_string())?;
    resp["data"]["amount"]
        .as_str()
        .and_then(|s| s.parse::<f64>().ok())
        .filter(|p| *p > 0.0)
        .ok_or_else(|| format!("coinbase spot: unexpected response: {resp}"))
}
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

    // Treasury backing = SPL USDC + native SOL marked to a live public spot
    // price (source cited in the response). Tradeoff: SOL is volatile
    // backing vs the USDC-stable denomination - if the treasury later holds
    // USDC only, this same computation keeps working (SOL leg goes to 0).
    // A price-feed or balance-fetch failure degrades honestly: the SOL leg
    // is excluded from backing and the error is surfaced, never silently
    // counted as zero-balance or inflated.
    let sol_lamports = solana::treasury_sol_balance_lamports(&state.config.solana)
        .await
        .map_err(|e| format!("sol balance: {e}"));
    let sol_price = fetch_sol_usd_price().await;
    let sol_value_micro = match (&sol_lamports, &sol_price) {
        (Ok(lamports), Ok(price)) => {
            Some((*lamports as f64 / 1e9 * price * 1_000_000.0).round() as i64)
        }
        _ => None,
    };
    let backing_micro = treasury_micro + sol_value_micro.unwrap_or(0);

    // Credits are 1M per $1 = 10k per cent; USDC micro are 1M per $1.
    // So credits and USDC-micro share the same scale: 1 credit == 1 micro-USDC.
    let outstanding_credits = liabilities.device_credits + liabilities.account_credits;
    let pending_micro = liabilities.pending_withdrawal_usdc_cents * 10_000;
    let total_liabilities_micro = outstanding_credits + pending_micro;
    let coverage_bps = if total_liabilities_micro > 0 {
        backing_micro.saturating_mul(10_000) / total_liabilities_micro
    } else {
        10_000
    };

    Ok(Json(json!({
        "treasuryAddress": state.config.solana.treasury_address,
        "treasuryUsdcMicro": treasury_micro,
        "treasuryUsdc": treasury_micro as f64 / 1_000_000.0,
        "treasurySolLamports": sol_lamports.as_ref().ok(),
        "treasurySol": sol_lamports.as_ref().ok().map(|l| *l as f64 / 1e9),
        "treasurySolPriceUsd": sol_price.as_ref().ok(),
        "treasurySolPriceSource": "coinbase-spot SOL-USD (https://api.coinbase.com/v2/prices/SOL-USD/spot)",
        "treasurySolValueUsdcMicro": sol_value_micro,
        "treasurySolValuationError": match (&sol_lamports, &sol_price) {
            (Ok(_), Ok(_)) => None,
            (Err(e), _) => Some(e.clone()),
            (_, Err(e)) => Some(e.clone()),
        },
        "treasuryBackingUsdcMicro": backing_micro,
        "treasuryBackingModel": "SPL USDC balance + native SOL marked to the cited live spot price; SOL is volatile backing vs the USDC-stable denomination",
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
