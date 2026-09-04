//! GET /v1/pool - public availability-pool health.
//!
//! Exposes the mint pool's remaining credits, the accrued (un-recycled)
//! ops-fee balance, and the latest drip-tick snapshot written by
//! `reconcile_availability_sessions`. Powers the operator low-pool alert
//! watch; aggregate network health only, no per-device data.

use axum::{extract::State, Json};
use serde_json::{json, Value};

use crate::error::GatewayError;
use crate::state::AppState;

pub async fn pool(State(state): State<AppState>) -> Result<Json<Value>, GatewayError> {
    let db = state
        .db
        .as_ref()
        .ok_or_else(|| GatewayError::Other(anyhow::anyhow!("db not initialized")))?;
    let conn = db.lock();
    let (total_minted, remaining): (i64, i64) = conn
        .query_row("SELECT total_minted, remaining FROM mint_pool WHERE id = 1", [], |r| {
            Ok((r.get(0)?, r.get(1)?))
        })
        .unwrap_or((0, 0));
    let ops_balance: i64 = conn
        .query_row(
            "SELECT balance FROM balances WHERE device_id = '__ops__'",
            [],
            |r| r.get(0),
        )
        .unwrap_or(0);
    let status = conn
        .query_row(
            "SELECT updated_at, tick_total, recycled_credits, low_pool FROM pool_status WHERE id = 1",
            [],
            |r| {
                Ok((
                    r.get::<_, i64>(0)?,
                    r.get::<_, i64>(1)?,
                    r.get::<_, i64>(2)?,
                    r.get::<_, i64>(3)?,
                ))
            },
        )
        .ok();
    let (updated_at, tick_total, recycled_credits, low_pool) = status.unwrap_or((0, 0, 0, 0));
    Ok(Json(json!({
        "mintPoolTotalMinted": total_minted,
        "mintPoolRemaining": remaining,
        "opsFeesAccrued": ops_balance,
        "lastTickTotal": tick_total,
        "lastTickRecycled": recycled_credits,
        "lowPool": low_pool != 0,
        "updatedAt": updated_at,
        "creditsPerUsd": 1_000_000,
    })))
}
