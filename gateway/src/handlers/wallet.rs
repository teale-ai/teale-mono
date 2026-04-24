//! Wallet endpoints — read-only views of the ledger for the calling device.
//!
//! GET /v1/wallet/balance
//! GET /v1/wallet/transactions?limit=50
//! POST /v1/wallet/send

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
    #[serde(default)]
    include_availability: bool,
}

fn default_limit() -> i64 {
    50
}

#[derive(Serialize)]
pub struct TxListRes {
    transactions: Vec<ledger::LedgerEntry>,
}

#[derive(Debug, Deserialize)]
pub struct SendReq {
    asset: String,
    recipient: String,
    amount: i64,
    memo: Option<String>,
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
    let list = if q.include_availability {
        ledger::list_transactions(pool, &device_id, limit)
    } else {
        ledger::list_transactions_without_availability(pool, &device_id, limit)
    };
    Ok(Json(TxListRes { transactions: list }))
}

pub async fn send(
    State(state): State<AppState>,
    headers: HeaderMap,
    Json(req): Json<SendReq>,
) -> Result<Json<ledger::TransferReceipt>, GatewayError> {
    let device_id = device_from_header(&state, &headers)?;
    if !req.asset.eq_ignore_ascii_case("credits") {
        return Err(GatewayError::BadRequest(
            ledger::TransferError::UnsupportedAsset.to_string(),
        ));
    }
    let pool = state
        .db
        .as_ref()
        .ok_or_else(|| GatewayError::Other(anyhow::anyhow!("db not initialized")))?;
    let receipt = ledger::transfer_from_device_wallet(
        pool,
        &device_id,
        &req.recipient,
        req.amount,
        req.memo.as_deref(),
    )
    .map_err(map_transfer_error)?;
    Ok(Json(receipt))
}

fn map_transfer_error(err: ledger::TransferError) -> GatewayError {
    match err {
        ledger::TransferError::UnsupportedAsset
        | ledger::TransferError::InvalidAmount
        | ledger::TransferError::MissingRecipient => GatewayError::BadRequest(err.to_string()),
        ledger::TransferError::RecipientAccountNotFound
        | ledger::TransferError::RecipientDeviceNotFound => GatewayError::NotFound(err.to_string()),
        ledger::TransferError::AmbiguousRecipient
        | ledger::TransferError::SameWallet
        | ledger::TransferError::AccountNotLinked => GatewayError::Conflict(err.to_string()),
        ledger::TransferError::InsufficientBalance { balance, required } => {
            GatewayError::InsufficientCredits { balance, required }
        }
        ledger::TransferError::Other(err) => GatewayError::Other(err),
    }
}
