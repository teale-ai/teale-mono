//! Account-level wallet and linked-device endpoints.
//!
//! These routes are protected by bearer auth. Linked Teale devices remain the
//! authority for account-linking and device-management actions, while
//! account-scoped API keys may read/send from the owning human account.

use axum::{
    extract::{Path, State},
    Extension, Json,
};
use serde::{Deserialize, Serialize};

use crate::auth::{AuthPrincipal, PrincipalKind};
use crate::db::DbPool;
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

#[derive(Debug, Deserialize)]
pub struct SendReq {
    asset: String,
    recipient: String,
    amount: i64,
    memo: Option<String>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CreateAccountApiKeyReq {
    #[serde(default)]
    label: Option<String>,
}

#[derive(Debug, Serialize)]
pub struct ListAccountApiKeysRes {
    keys: Vec<ledger::AccountApiKeyPublic>,
}

#[derive(Debug, Serialize)]
pub struct RevokeAccountApiKeyRes {
    revoked: bool,
}

fn require_pool(state: &AppState) -> Result<&DbPool, GatewayError> {
    state
        .db
        .as_ref()
        .ok_or_else(|| GatewayError::Other(anyhow::anyhow!("db not initialized")))
}

fn require_device(principal: &AuthPrincipal) -> Result<&str, GatewayError> {
    match &principal.kind {
        PrincipalKind::Device { device_id } => Ok(device_id.as_str()),
        PrincipalKind::Account { .. } => Err(GatewayError::Unauthorized(
            "account API keys cannot call device-management endpoints".into(),
        )),
        PrincipalKind::Share { .. } => Err(GatewayError::Unauthorized(
            "share keys cannot call account endpoints".into(),
        )),
        PrincipalKind::Static { .. } => {
            Err(GatewayError::Unauthorized("device bearer required".into()))
        }
    }
}

fn require_linked_account_for_device(
    pool: &DbPool,
    device_id: &str,
) -> Result<String, GatewayError> {
    ledger::account_user_id_for_device(pool, device_id)
        .ok_or_else(|| GatewayError::Conflict("device is not linked to an account".into()))
}

pub async fn link_account(
    State(state): State<AppState>,
    Extension(principal): Extension<AuthPrincipal>,
    Json(req): Json<LinkAccountReq>,
) -> Result<Json<ledger::AccountWalletSnapshot>, GatewayError> {
    let requester_device_id = require_device(&principal)?;
    let pool = require_pool(&state)?;
    if req.account_user_id.trim().is_empty() {
        return Err(GatewayError::BadRequest("accountUserID is required".into()));
    }

    ledger::link_device_to_account(
        pool,
        requester_device_id,
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

    let summary = ledger::account_summary_for_device(pool, requester_device_id)
        .map_err(GatewayError::Other)?;
    Ok(Json(summary))
}

pub async fn summary(
    State(state): State<AppState>,
    Extension(principal): Extension<AuthPrincipal>,
) -> Result<Json<ledger::AccountWalletSnapshot>, GatewayError> {
    let pool = require_pool(&state)?;
    let summary = match &principal.kind {
        PrincipalKind::Account {
            account_user_id, ..
        } => ledger::account_summary(pool, account_user_id)
            .map_err(|err| GatewayError::NotFound(err.to_string()))?,
        PrincipalKind::Device { device_id } => ledger::account_summary_for_device(pool, device_id)
            .map_err(|err| GatewayError::NotFound(err.to_string()))?,
        PrincipalKind::Share { .. } => {
            return Err(GatewayError::Unauthorized(
                "share keys cannot call account endpoints".into(),
            ));
        }
        PrincipalKind::Static { .. } => {
            return Err(GatewayError::Unauthorized(
                "human account or linked device bearer required".into(),
            ));
        }
    };
    Ok(Json(summary))
}

pub async fn sweep_device(
    State(state): State<AppState>,
    Extension(principal): Extension<AuthPrincipal>,
    Json(req): Json<SweepReq>,
) -> Result<Json<ledger::AccountSweepResult>, GatewayError> {
    let requester_device_id = require_device(&principal)?;
    let pool = require_pool(&state)?;
    if req.device_id.trim().is_empty() {
        return Err(GatewayError::BadRequest("deviceID is required".into()));
    }
    let result = ledger::sweep_device_to_account(pool, requester_device_id, req.device_id.trim())
        .map_err(GatewayError::Other)?;
    Ok(Json(result))
}

pub async fn remove_device(
    State(state): State<AppState>,
    Extension(principal): Extension<AuthPrincipal>,
    Json(req): Json<RemoveDeviceReq>,
) -> Result<Json<ledger::AccountWalletSnapshot>, GatewayError> {
    let requester_device_id = require_device(&principal)?;
    let pool = require_pool(&state)?;
    if req.device_id.trim().is_empty() {
        return Err(GatewayError::BadRequest("deviceID is required".into()));
    }
    let summary =
        ledger::remove_device_from_account(pool, requester_device_id, req.device_id.trim())
            .map_err(GatewayError::Other)?;
    Ok(Json(summary))
}

pub async fn send(
    State(state): State<AppState>,
    Extension(principal): Extension<AuthPrincipal>,
    Json(req): Json<SendReq>,
) -> Result<Json<ledger::TransferReceipt>, GatewayError> {
    if !req.asset.eq_ignore_ascii_case("credits") {
        return Err(GatewayError::BadRequest(
            ledger::TransferError::UnsupportedAsset.to_string(),
        ));
    }
    let pool = require_pool(&state)?;
    let receipt = match &principal.kind {
        PrincipalKind::Account {
            account_user_id, ..
        } => ledger::transfer_from_account_wallet_for_account(
            pool,
            account_user_id,
            &req.recipient,
            req.amount,
            req.memo.as_deref(),
            None,
        ),
        PrincipalKind::Device { device_id } => ledger::transfer_from_account_wallet(
            pool,
            device_id,
            &req.recipient,
            req.amount,
            req.memo.as_deref(),
        ),
        PrincipalKind::Share { .. } => {
            return Err(GatewayError::Unauthorized(
                "share keys cannot call account endpoints".into(),
            ));
        }
        PrincipalKind::Static { .. } => {
            return Err(GatewayError::Unauthorized(
                "human account or linked device bearer required".into(),
            ));
        }
    }
    .map_err(map_transfer_error)?;
    Ok(Json(receipt))
}

pub async fn list_api_keys(
    State(state): State<AppState>,
    Extension(principal): Extension<AuthPrincipal>,
) -> Result<Json<ListAccountApiKeysRes>, GatewayError> {
    let pool = require_pool(&state)?;
    let requester_device_id = require_device(&principal)?;
    let account_user_id = require_linked_account_for_device(pool, requester_device_id)?;
    let keys =
        ledger::list_account_api_keys(pool, &account_user_id).map_err(GatewayError::Other)?;
    Ok(Json(ListAccountApiKeysRes { keys }))
}

pub async fn create_api_key(
    State(state): State<AppState>,
    Extension(principal): Extension<AuthPrincipal>,
    Json(req): Json<CreateAccountApiKeyReq>,
) -> Result<Json<ledger::AccountApiKeyMinted>, GatewayError> {
    let pool = require_pool(&state)?;
    let requester_device_id = require_device(&principal)?;
    let account_user_id = require_linked_account_for_device(pool, requester_device_id)?;
    let minted = ledger::mint_account_api_key(pool, &account_user_id, req.label.as_deref())
        .map_err(GatewayError::Other)?;
    Ok(Json(minted))
}

pub async fn revoke_api_key(
    State(state): State<AppState>,
    Extension(principal): Extension<AuthPrincipal>,
    Path(key_id): Path<String>,
) -> Result<Json<RevokeAccountApiKeyRes>, GatewayError> {
    let pool = require_pool(&state)?;
    let requester_device_id = require_device(&principal)?;
    let account_user_id = require_linked_account_for_device(pool, requester_device_id)?;
    let revoked = ledger::revoke_account_api_key(pool, &account_user_id, key_id.trim())
        .map_err(GatewayError::Other)?;
    if !revoked {
        return Err(GatewayError::NotFound("account API key not found".into()));
    }
    Ok(Json(RevokeAccountApiKeyRes { revoked }))
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
