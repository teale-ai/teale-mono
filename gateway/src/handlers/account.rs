//! Account-level wallet and linked-device endpoints.
//!
//! These routes are protected by bearer auth. Linked Teale devices remain the
//! authority for account-linking and device-management actions, while
//! account-scoped API keys may read/send from the owning human account.

use axum::{
    extract::{Query, State},
    http::HeaderMap,
    Extension, Json,
};
use serde::Deserialize;

use crate::auth::{AuthPrincipal, PrincipalKind};
use crate::db::DbPool;
use crate::error::GatewayError;
use crate::ledger::{self, AccountLinkMetadata};
use crate::solana::{self, DepositVerificationError, WithdrawalVerificationError};
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
    #[serde(rename = "referralCode")]
    referral_code: Option<String>,
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
pub struct WithdrawalsQuery {
    #[serde(default = "default_withdrawal_limit")]
    limit: i64,
}

fn default_withdrawal_limit() -> i64 {
    50
}

#[derive(Debug, serde::Serialize)]
pub struct WithdrawalsRes {
    withdrawals: Vec<ledger::AccountWithdrawalRecord>,
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

fn require_pool(state: &AppState) -> Result<&DbPool, GatewayError> {
    state
        .db
        .as_ref()
        .ok_or_else(|| GatewayError::Other(anyhow::anyhow!("db not initialized")))
}

fn require_device(principal: &AuthPrincipal) -> Result<&str, GatewayError> {
    match &principal.kind {
        PrincipalKind::Device { device_id } => Ok(device_id.as_str()),
        PrincipalKind::ApiKey { .. } => Err(GatewayError::Unauthorized(
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
    let _ = ledger::apply_account_join_rewards(
        pool,
        requester_device_id,
        req.account_user_id.trim(),
        req.referral_code.as_deref(),
    )
    .map_err(map_referral_error)?;

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
        PrincipalKind::ApiKey {
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

pub async fn onchain(
    State(state): State<AppState>,
    headers: HeaderMap,
) -> Result<Json<ledger::AccountOnchainSnapshot>, GatewayError> {
    let requester_device_id = device_from_header(&state, &headers)?;
    let pool = state
        .db
        .as_ref()
        .ok_or_else(|| GatewayError::Other(anyhow::anyhow!("db not initialized")))?;
    let summary = ledger::account_onchain_summary_for_device(pool, &requester_device_id)
        .map_err(map_onchain_error)?;
    Ok(Json(summary))
}

pub async fn deposit_intent(
    State(state): State<AppState>,
    headers: HeaderMap,
    Json(mut req): Json<ledger::AccountOnchainDepositIntent>,
) -> Result<Json<ledger::AccountOnchainSnapshot>, GatewayError> {
    let requester_device_id = device_from_header(&state, &headers)?;
    let pool = state
        .db
        .as_ref()
        .ok_or_else(|| GatewayError::Other(anyhow::anyhow!("db not initialized")))?;
    if let Some(tx_signature) = normalized_optional_string(req.tx_signature.as_deref()) {
        let effective_address = ledger::resolve_account_onchain_address_for_device(
            pool,
            &requester_device_id,
            req.solana_address.as_deref(),
        )
        .map_err(map_onchain_error)?;
        let verified = solana::verify_usdc_deposit(
            &state.config.solana,
            &effective_address,
            &tx_signature,
            req.amount_usdc_cents,
            req.source_address.as_deref(),
        )
        .await
        .map_err(map_deposit_verification_error)?;
        req.solana_address = Some(effective_address);
        req.tx_signature = Some(verified.tx_signature);
        req.source_address = verified.source_address;
        req.amount_usdc_cents = Some(verified.amount_usdc_cents);
    }
    let summary = ledger::record_account_onchain_deposit(pool, &requester_device_id, &req)
        .map_err(map_onchain_error)?;
    Ok(Json(summary))
}

pub async fn withdraw(
    State(state): State<AppState>,
    headers: HeaderMap,
    Json(mut req): Json<ledger::AccountWithdrawalRequest>,
) -> Result<Json<ledger::AccountWithdrawalRecord>, GatewayError> {
    let requester_device_id = device_from_header(&state, &headers)?;
    let pool = state
        .db
        .as_ref()
        .ok_or_else(|| GatewayError::Other(anyhow::anyhow!("db not initialized")))?;
    if let Some(tx_signature) = normalized_optional_string(req.tx_signature.as_deref()) {
        let source_address =
            ledger::resolve_account_onchain_address_for_device(pool, &requester_device_id, None)
                .map_err(map_onchain_error)?;
        let verified = solana::verify_usdc_withdrawal(
            &state.config.solana,
            &source_address,
            req.destination_address.as_str(),
            req.amount_usdc_cents,
            &tx_signature,
        )
        .await
        .map_err(map_withdrawal_verification_error)?;
        req.tx_signature = Some(verified.tx_signature);
        req.destination_address = verified.destination_address;
        req.amount_usdc_cents = verified.gross_amount_usdc_cents;
    }
    let record = ledger::submit_account_withdrawal(pool, &requester_device_id, &req)
        .map_err(map_onchain_error)?;
    Ok(Json(record))
}

pub async fn withdrawals(
    State(state): State<AppState>,
    headers: HeaderMap,
    Query(q): Query<WithdrawalsQuery>,
) -> Result<Json<WithdrawalsRes>, GatewayError> {
    let requester_device_id = device_from_header(&state, &headers)?;
    let pool = state
        .db
        .as_ref()
        .ok_or_else(|| GatewayError::Other(anyhow::anyhow!("db not initialized")))?;
    let withdrawals =
        ledger::list_account_withdrawals_for_device(pool, &requester_device_id, q.limit)
            .map_err(map_onchain_error)?;
    Ok(Json(WithdrawalsRes { withdrawals }))
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
        PrincipalKind::ApiKey {
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

fn map_onchain_error(err: ledger::AccountOnchainError) -> GatewayError {
    match err {
        ledger::AccountOnchainError::AccountNotLinked => GatewayError::NotFound(err.to_string()),
        ledger::AccountOnchainError::InvalidUsdcAmount
        | ledger::AccountOnchainError::DepositAmountRequired
        | ledger::AccountOnchainError::MissingRequestId
        | ledger::AccountOnchainError::MissingDestinationAddress
        | ledger::AccountOnchainError::SolanaAddressRequired => {
            GatewayError::BadRequest(err.to_string())
        }
        ledger::AccountOnchainError::SolanaAddressMismatch
        | ledger::AccountOnchainError::SolanaWalletNotEnabled
        | ledger::AccountOnchainError::DepositConflict
        | ledger::AccountOnchainError::WithdrawalConflict
        | ledger::AccountOnchainError::WithdrawalSignatureConflict => {
            GatewayError::Conflict(err.to_string())
        }
        ledger::AccountOnchainError::InsufficientWithdrawable {
            balance,
            redeemable_credits,
            required,
        } => GatewayError::InsufficientCredits {
            balance: balance.min(redeemable_credits),
            required,
        },
        ledger::AccountOnchainError::Other(err) => GatewayError::Other(err),
    }
}

fn map_referral_error(err: ledger::ReferralError) -> GatewayError {
    match err {
        ledger::ReferralError::InvalidCode => GatewayError::BadRequest(err.to_string()),
        ledger::ReferralError::SelfReferral
        | ledger::ReferralError::DeviceAlreadyClaimed
        | ledger::ReferralError::AccountAlreadyClaimed => GatewayError::Conflict(err.to_string()),
        ledger::ReferralError::AccountNotLinked => GatewayError::NotFound(err.to_string()),
        ledger::ReferralError::Other(err) => GatewayError::Other(err),
    }
}

fn map_deposit_verification_error(err: DepositVerificationError) -> GatewayError {
    let message = err.to_string();
    match err {
        DepositVerificationError::MissingSignature
        | DepositVerificationError::TransactionNotFound
        | DepositVerificationError::TransactionNotSettled { .. }
        | DepositVerificationError::TransactionFailed
        | DepositVerificationError::NoMatchingDeposit
        | DepositVerificationError::AmountMismatch { .. }
        | DepositVerificationError::SourceMismatch { .. }
        | DepositVerificationError::FractionalCents
        | DepositVerificationError::UnexpectedDecimals { .. } => GatewayError::BadRequest(message),
        DepositVerificationError::Rpc(_) => GatewayError::Upstream(message),
    }
}

fn map_withdrawal_verification_error(err: WithdrawalVerificationError) -> GatewayError {
    let message = err.to_string();
    match err {
        WithdrawalVerificationError::MissingSignature
        | WithdrawalVerificationError::TransactionNotFound
        | WithdrawalVerificationError::TransactionNotSettled { .. }
        | WithdrawalVerificationError::TransactionFailed
        | WithdrawalVerificationError::NoMatchingWithdrawal
        | WithdrawalVerificationError::SourceMismatch { .. }
        | WithdrawalVerificationError::DestinationMismatch { .. }
        | WithdrawalVerificationError::AmountMismatch { .. }
        | WithdrawalVerificationError::TreasuryFeeMismatch { .. }
        | WithdrawalVerificationError::DestinationAmountMismatch { .. }
        | WithdrawalVerificationError::UnexpectedDecimals { .. } => {
            GatewayError::BadRequest(message)
        }
        WithdrawalVerificationError::Rpc(_) => GatewayError::Upstream(message),
    }
}

fn normalized_optional_string(value: Option<&str>) -> Option<String> {
    value.and_then(|raw| {
        let trimmed = raw.trim();
        (!trimmed.is_empty()).then_some(trimmed.to_string())
    })
}
