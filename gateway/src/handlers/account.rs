//! Account-level wallet and linked-device endpoints.
//!
//! These routes are protected by device bearer auth. The current device is the
//! authority for linking itself to a human account, listing other linked
//! devices on that account, and sweeping a device wallet into the account
//! wallet.

use axum::{extract::State, http::HeaderMap, Json};
use serde::Deserialize;

use crate::error::GatewayError;
use crate::ledger::{self, AccountLinkMetadata};
use crate::state::AppState;

#[derive(Debug, Deserialize)]
pub struct LinkAccountReq {
    #[serde(rename = "accountUserID")]
    account_user_id: String,
    #[serde(rename = "deviceName")]
    device_name: Option<String>,
    platform: Option<String>,
    #[serde(rename = "displayName")]
    display_name: Option<String>,
    phone: Option<String>,
    email: Option<String>,
    #[serde(rename = "githubUsername")]
    github_username: Option<String>,
}

#[derive(Debug, Deserialize)]
pub struct SweepReq {
    #[serde(rename = "deviceID")]
    device_id: String,
}

#[derive(Debug, Deserialize)]
pub struct RemoveDeviceReq {
    #[serde(rename = "deviceID")]
    device_id: String,
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

pub async fn link_account(
    State(state): State<AppState>,
    headers: HeaderMap,
    Json(req): Json<LinkAccountReq>,
) -> Result<Json<ledger::AccountWalletSnapshot>, GatewayError> {
    let requester_device_id = device_from_header(&state, &headers)?;
    let pool = state
        .db
        .as_ref()
        .ok_or_else(|| GatewayError::Other(anyhow::anyhow!("db not initialized")))?;
    if req.account_user_id.trim().is_empty() {
        return Err(GatewayError::BadRequest("accountUserID is required".into()));
    }

    ledger::link_device_to_account(
        pool,
        &requester_device_id,
        req.account_user_id.trim(),
        &AccountLinkMetadata {
            device_name: req.device_name,
            platform: req.platform,
            display_name: req.display_name,
            phone: req.phone,
            email: req.email,
            github_username: req.github_username,
        },
    )
    .map_err(GatewayError::Other)?;

    let summary = ledger::account_summary_for_device(pool, &requester_device_id)
        .map_err(GatewayError::Other)?;
    Ok(Json(summary))
}

pub async fn summary(
    State(state): State<AppState>,
    headers: HeaderMap,
) -> Result<Json<ledger::AccountWalletSnapshot>, GatewayError> {
    let requester_device_id = device_from_header(&state, &headers)?;
    let pool = state
        .db
        .as_ref()
        .ok_or_else(|| GatewayError::Other(anyhow::anyhow!("db not initialized")))?;
    let summary = ledger::account_summary_for_device(pool, &requester_device_id)
        .map_err(|err| GatewayError::NotFound(err.to_string()))?;
    Ok(Json(summary))
}

pub async fn sweep_device(
    State(state): State<AppState>,
    headers: HeaderMap,
    Json(req): Json<SweepReq>,
) -> Result<Json<ledger::AccountSweepResult>, GatewayError> {
    let requester_device_id = device_from_header(&state, &headers)?;
    let pool = state
        .db
        .as_ref()
        .ok_or_else(|| GatewayError::Other(anyhow::anyhow!("db not initialized")))?;
    if req.device_id.trim().is_empty() {
        return Err(GatewayError::BadRequest("deviceID is required".into()));
    }
    let result = ledger::sweep_device_to_account(pool, &requester_device_id, req.device_id.trim())
        .map_err(GatewayError::Other)?;
    Ok(Json(result))
}

pub async fn remove_device(
    State(state): State<AppState>,
    headers: HeaderMap,
    Json(req): Json<RemoveDeviceReq>,
) -> Result<Json<ledger::AccountWalletSnapshot>, GatewayError> {
    let requester_device_id = device_from_header(&state, &headers)?;
    let pool = state
        .db
        .as_ref()
        .ok_or_else(|| GatewayError::Other(anyhow::anyhow!("db not initialized")))?;
    if req.device_id.trim().is_empty() {
        return Err(GatewayError::BadRequest("deviceID is required".into()));
    }
    let summary =
        ledger::remove_device_from_account(pool, &requester_device_id, req.device_id.trim())
            .map_err(GatewayError::Other)?;
    Ok(Json(summary))
}
