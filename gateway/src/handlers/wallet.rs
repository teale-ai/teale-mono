//! Wallet endpoints — read-only views of the ledger for the calling device.
//!
//! GET /v1/wallet/balance
//! GET /v1/wallet/transactions?limit=50

use axum::{
    extract::{Query, State},
    http::HeaderMap,
    Json,
};
use serde::{Deserialize, Serialize};

use crate::error::GatewayError;
use crate::ledger;
use crate::state::AppState;

#[derive(Deserialize)]
pub struct TxQuery {
    #[serde(default = "default_limit")]
    limit: i64,
}

fn default_limit() -> i64 {
    50
}

#[derive(Serialize)]
pub struct TxListRes {
    transactions: Vec<ledger::LedgerEntry>,
}

fn device_from_header(state: &AppState, headers: &HeaderMap) -> Result<String, GatewayError> {
    let header = headers
        .get(axum::http::header::AUTHORIZATION)
        .and_then(|h| h.to_str().ok())
        .unwrap_or("");
    let token = header.strip_prefix("Bearer ").unwrap_or("").trim();
    if token.is_empty() {
        return Err(GatewayError::Unauthorized("missing bearer".into()));
    }
    let pool = state
        .db
        .as_ref()
        .ok_or_else(|| GatewayError::Other(anyhow::anyhow!("db not initialized")))?;
    ledger::resolve_token(pool, token)
        .ok_or_else(|| GatewayError::Unauthorized("unknown or expired device token".into()))
}

pub async fn balance(
    State(state): State<AppState>,
    headers: HeaderMap,
) -> Result<Json<ledger::BalanceSnapshot>, GatewayError> {
    let device_id = device_from_header(&state, &headers)?;
    let pool = state
        .db
        .as_ref()
        .ok_or_else(|| GatewayError::Other(anyhow::anyhow!("db not initialized")))?;
    Ok(Json(ledger::get_balance(pool, &device_id)))
}

pub async fn transactions(
    State(state): State<AppState>,
    headers: HeaderMap,
    Query(q): Query<TxQuery>,
) -> Result<Json<TxListRes>, GatewayError> {
    let device_id = device_from_header(&state, &headers)?;
    let pool = state
        .db
        .as_ref()
        .ok_or_else(|| GatewayError::Other(anyhow::anyhow!("db not initialized")))?;
    let limit = q.limit.clamp(1, 500);
    let list = ledger::list_transactions(pool, &device_id, limit);
    Ok(Json(TxListRes { transactions: list }))
}
