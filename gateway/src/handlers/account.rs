//! Account-level wallet and linked-device endpoints.
//!
//! These routes are protected by bearer auth. `/v1/account/link` is
//! device-bound (it links the calling device) and requires an account-session
//! ownership proof for existing accounts (see `link_account`). Summary, send,
//! sweep and device removal also accept the account's own session; wallet
//! on-chain endpoints stay device-bound. Account-scoped API keys may
//! read/send from the owning human account.

use axum::{
    extract::{Query, State},
    http::{HeaderMap, StatusCode},
    response::{IntoResponse, Response},
    Extension, Json,
};
use serde::Deserialize;
use serde_json::json;

use crate::auth::{AuthPrincipal, PrincipalKind};
use crate::db::DbPool;
use crate::error::GatewayError;
use crate::ledger::{self, AccountLinkMetadata, LinkProof};
use crate::solana::{self, DepositVerificationError, WithdrawalVerificationError};
use crate::state::AppState;

/// Header carrying the account-session ownership proof on `/v1/account/link`
/// (contract B). Value: a `tsess_…` token from the email verify / magic-link
/// flow.
pub const ACCOUNT_SESSION_HEADER: &str = "x-teale-account-session";

/// Error code returned (403) when a link needs an account-session proof.
pub const ACCOUNT_SESSION_REQUIRED: &str = "account_session_required";

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
    // `email` is intentionally not accepted: account emails are only bound
    // by verified email flows. Older clients that still send it are ignored.
    #[serde(rename = "githubUsername")]
    github_username: Option<String>,
    #[serde(rename = "referralCode")]
    referral_code: Option<String>,
}

/// Errors from `/v1/account/link`: ordinary gateway errors, or a 403 with the
/// stable `account_session_required` code clients key on.
#[derive(Debug)]
pub enum LinkAccountError {
    Gateway(GatewayError),
    SessionRequired(String),
}

impl From<GatewayError> for LinkAccountError {
    fn from(err: GatewayError) -> Self {
        Self::Gateway(err)
    }
}

impl IntoResponse for LinkAccountError {
    fn into_response(self) -> Response {
        match self {
            Self::Gateway(err) => err.into_response(),
            Self::SessionRequired(message) => {
                let body = json!({
                    "error": {
                        "message": message,
                        "type": ACCOUNT_SESSION_REQUIRED,
                        "code": ACCOUNT_SESSION_REQUIRED,
                    }
                });
                (StatusCode::FORBIDDEN, Json(body)).into_response()
            }
        }
    }
}

fn account_session_header(headers: &HeaderMap) -> Option<&str> {
    headers
        .get(ACCOUNT_SESSION_HEADER)
        .and_then(|v| v.to_str().ok())
        .map(str::trim)
        .filter(|v| !v.is_empty())
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
        PrincipalKind::Static { .. } | PrincipalKind::AccountSession { .. } => {
            Err(GatewayError::Unauthorized("device bearer required".into()))
        }
    }
}

/// POST /v1/account/link — link the calling device to an account
/// (contract B). With an `X-Teale-Account-Session` header the session must
/// belong to exactly `accountUserID`; the link may then also re-point the
/// device. Without it the link may only create a brand-new, empty account
/// for a device that is not linked elsewhere. Anything else is a 403
/// `account_session_required`. Links never mint a welcome bonus; a referral
/// code is honoured only on a session-backed link of the account's first
/// device.
pub async fn link_account(
    State(state): State<AppState>,
    Extension(principal): Extension<AuthPrincipal>,
    headers: HeaderMap,
    Json(req): Json<LinkAccountReq>,
) -> Result<Json<ledger::AccountWalletSnapshot>, LinkAccountError> {
    let requester_device_id = require_device(&principal)?;
    let pool = require_pool(&state)?;
    if req.account_user_id.trim().is_empty() {
        return Err(GatewayError::BadRequest("accountUserID is required".into()).into());
    }

    let account_user_id = ledger::normalize_account_user_id(&req.account_user_id);
    // Pre-#173 lowercase UUID accounts are renamed (never merged) to the
    // canonical uppercase id before ownership is checked.
    ledger::canonicalize_legacy_account_id(pool, &account_user_id).map_err(GatewayError::Other)?;

    let proof = match account_session_header(&headers) {
        Some(token) => {
            let session =
                ledger::try_resolve_account_session(pool, token).map_err(GatewayError::Other)?;
            let Some(session) = session else {
                return Err(LinkAccountError::SessionRequired(
                    "account session is invalid or expired; sign in again".into(),
                ));
            };
            if session.account_user_id != account_user_id {
                return Err(LinkAccountError::SessionRequired(
                    "account session belongs to a different account".into(),
                ));
            }
            LinkProof::AccountSession
        }
        None => LinkProof::None,
    };

    let outcome = ledger::link_device_to_account_with_proof(
        pool,
        requester_device_id,
        &account_user_id,
        &AccountLinkMetadata {
            device_name: req.device_name,
            platform: req.platform,
            display_name: req.display_name,
            phone: req.phone,
            github_username: req.github_username,
        },
        proof,
    )
    .map_err(|err| match err {
        ledger::LinkDeviceError::SessionRequired(message) => {
            LinkAccountError::SessionRequired(message.to_string())
        }
        ledger::LinkDeviceError::Other(err) => GatewayError::Other(err).into(),
    })?;

    if proof == LinkProof::AccountSession && outcome.first_device {
        if let Some(code) = req.referral_code.as_deref() {
            ledger::apply_account_referral(pool, requester_device_id, &account_user_id, code)
                .map_err(map_referral_error)?;
        }
    }

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
        }
        | PrincipalKind::AccountSession {
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

#[derive(Debug, Deserialize)]
pub struct TreasuryDepositReq {
    #[serde(rename = "txSignature")]
    pub tx_signature: String,
}

/// Custodial deposit: USDC sent to the treasury with the account's deposit
/// memo. The memo binds the payment to the account, so anyone can pay in.
pub async fn deposit_treasury(
    State(state): State<AppState>,
    headers: HeaderMap,
    Json(req): Json<TreasuryDepositReq>,
) -> Result<Json<ledger::AccountOnchainSnapshot>, GatewayError> {
    let requester_device_id = device_from_header(&state, &headers)?;
    let pool = state
        .db
        .as_ref()
        .ok_or_else(|| GatewayError::Other(anyhow::anyhow!("db not initialized")))?;
    let account_user_id = ledger::account_user_id_for_device(pool, &requester_device_id).ok_or(
        GatewayError::BadRequest("device is not linked to an account".into()),
    )?;
    let expected_memo = ledger::treasury_deposit_memo(&account_user_id);
    let verified =
        solana::verify_treasury_deposit(&state.config.solana, &req.tx_signature, &expected_memo)
            .await
            .map_err(map_treasury_deposit_error)?;
    let summary = ledger::record_account_treasury_deposit(
        pool,
        &requester_device_id,
        &verified.tx_signature,
        verified.amount_usdc_cents,
        verified.source_address.as_deref(),
        &state.config.solana.treasury_address,
    )
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
    // The account's own session may sweep any device linked to it; otherwise
    // the caller must be a linked device.
    if principal.account_session().is_none() {
        require_device(&principal)?;
    }
    let pool = require_pool(&state)?;
    let target = req.device_id.trim();
    if target.is_empty() {
        return Err(GatewayError::BadRequest("deviceID is required".into()));
    }
    let result = match principal.account_session() {
        Some((account_user_id, _)) => {
            ledger::sweep_device_into_account(pool, account_user_id, target)
        }
        None => {
            let requester_device_id = require_device(&principal)?;
            ledger::sweep_device_to_account(pool, requester_device_id, target)
        }
    }
    .map_err(GatewayError::Other)?;
    Ok(Json(result))
}

pub async fn remove_device(
    State(state): State<AppState>,
    Extension(principal): Extension<AuthPrincipal>,
    Json(req): Json<RemoveDeviceReq>,
) -> Result<Json<ledger::AccountWalletSnapshot>, GatewayError> {
    // The account's own session may unlink any of its devices; a device
    // bearer may unlink sibling devices (but not itself).
    if principal.account_session().is_none() {
        require_device(&principal)?;
    }
    let pool = require_pool(&state)?;
    let target = req.device_id.trim();
    if target.is_empty() {
        return Err(GatewayError::BadRequest("deviceID is required".into()));
    }
    let summary = match principal.account_session() {
        Some((account_user_id, _)) => {
            ledger::remove_device_from_account_for_account(pool, account_user_id, target)
        }
        None => {
            let requester_device_id = require_device(&principal)?;
            ledger::remove_device_from_account(pool, requester_device_id, target)
        }
    }
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
        }
        | PrincipalKind::AccountSession {
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
        | ledger::AccountOnchainError::WithdrawalSignatureConflict
        | ledger::AccountOnchainError::WithdrawalNotPending => {
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

fn map_treasury_deposit_error(err: solana::TreasuryDepositError) -> GatewayError {
    use solana::TreasuryDepositError as E;
    let message = err.to_string();
    match err {
        E::MissingSignature
        | E::TransactionNotFound
        | E::TransactionNotSettled { .. }
        | E::TransactionFailed
        | E::NoMemoInstruction
        | E::MemoMismatch => GatewayError::BadRequest(message),
        E::Deposit(inner) => map_deposit_verification_error(inner),
        E::Rpc(_) => GatewayError::Upstream(message),
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

#[cfg(test)]
mod tests {
    use std::sync::Arc;

    use axum::http::HeaderValue;
    use tokio::sync::broadcast;

    use crate::auth::TokenTable;
    use crate::config::Config;
    use crate::db::open_in_memory;
    use crate::model_metrics::ModelMetricsTracker;
    use crate::registry::Registry;
    use crate::relay_client::RelayHandle;
    use crate::scheduler::Scheduler;

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
            share_key_issuers: Default::default(),
            providers: crate::providers::ProvidersHandle::empty_for_test(),
            identity: None,
            pin_join_limiter: Default::default(),
            challenge_limiter: Default::default(),
            started_at: std::time::Instant::now(),
        }
    }

    fn device(device_id: &str) -> Extension<AuthPrincipal> {
        Extension(AuthPrincipal {
            kind: PrincipalKind::Device {
                device_id: device_id.into(),
            },
        })
    }

    fn link_req(account_user_id: &str) -> Json<LinkAccountReq> {
        Json(LinkAccountReq {
            account_user_id: account_user_id.into(),
            device_name: None,
            platform: None,
            display_name: None,
            phone: None,
            github_username: None,
            referral_code: None,
        })
    }

    fn session_headers(token: &str) -> HeaderMap {
        let mut headers = HeaderMap::new();
        headers.insert(
            ACCOUNT_SESSION_HEADER,
            HeaderValue::from_str(token).unwrap(),
        );
        headers
    }

    /// Verified email login: creates the account and returns a session token.
    fn sign_in(state: &AppState, email: &str) -> (String, String) {
        let pool = state.db.as_ref().unwrap();
        let login = ledger::resolve_login_account(pool, email).unwrap();
        let session =
            ledger::create_account_session(pool, &login.account_user_id, None, None).unwrap();
        (login.account_user_id, session.token)
    }

    fn assert_session_required(err: LinkAccountError) {
        assert!(
            matches!(err, LinkAccountError::SessionRequired(_)),
            "{err:?}"
        );
        assert_eq!(err.into_response().status(), StatusCode::FORBIDDEN);
    }

    #[tokio::test]
    async fn link_with_a_valid_session_links_the_device() {
        let state = test_state();
        let (account, token) = sign_in(&state, "owner@example.com");
        let Json(summary) = link_account(
            State(state.clone()),
            device("dev-1"),
            session_headers(&token),
            link_req(&account),
        )
        .await
        .unwrap();
        assert_eq!(summary.account_user_id, account);
        assert_eq!(summary.devices.len(), 1);
        // The verified first login's welcome bonus is the only mint.
        assert_eq!(summary.balance_credits, ledger::WELCOME_BONUS_CREDITS);
    }

    #[tokio::test]
    async fn link_with_a_session_for_another_account_is_forbidden() {
        let state = test_state();
        let (_, token) = sign_in(&state, "owner@example.com");
        let (victim, _) = sign_in(&state, "victim@example.com");
        let err = link_account(
            State(state.clone()),
            device("dev-1"),
            session_headers(&token),
            link_req(&victim),
        )
        .await
        .unwrap_err();
        assert_session_required(err);
    }

    #[tokio::test]
    async fn link_without_session_creates_an_empty_new_account() {
        let state = test_state();
        let account = "8D7C6B5A-4E3F-4A2B-9C1D-0E1F2A3B4C5D";
        let Json(summary) = link_account(
            State(state.clone()),
            device("dev-1"),
            HeaderMap::new(),
            link_req(account),
        )
        .await
        .unwrap();
        assert_eq!(summary.account_user_id, account);
        assert_eq!(summary.balance_credits, 0, "no link-time welcome bonus");
        assert!(summary.transactions.is_empty());
    }

    #[tokio::test]
    async fn link_without_session_to_an_existing_account_is_forbidden() {
        let state = test_state();
        let (account, _) = sign_in(&state, "owner@example.com");
        let err = link_account(
            State(state.clone()),
            device("attacker-dev"),
            HeaderMap::new(),
            link_req(&account),
        )
        .await
        .unwrap_err();
        assert_session_required(err);
    }

    #[tokio::test]
    async fn repointing_a_linked_device_without_session_is_forbidden() {
        let state = test_state();
        let Json(_) = link_account(
            State(state.clone()),
            device("dev-1"),
            HeaderMap::new(),
            link_req("acct-original"),
        )
        .await
        .unwrap();
        let err = link_account(
            State(state.clone()),
            device("dev-1"),
            HeaderMap::new(),
            link_req("acct-new"),
        )
        .await
        .unwrap_err();
        assert_session_required(err);
        let pool = state.db.as_ref().unwrap();
        assert_eq!(
            ledger::account_user_id_for_device(pool, "dev-1").as_deref(),
            Some("acct-original")
        );
    }

    #[tokio::test]
    async fn session_can_sweep_and_remove_its_own_devices() {
        let state = test_state();
        let (account, token) = sign_in(&state, "owner@example.com");
        let Json(_) = link_account(
            State(state.clone()),
            device("dev-1"),
            session_headers(&token),
            link_req(&account),
        )
        .await
        .unwrap();
        let principal = Extension(AuthPrincipal {
            kind: PrincipalKind::AccountSession {
                account_user_id: account.clone(),
                session_id: "session-1".into(),
            },
        });
        let Json(swept) = sweep_device(
            State(state.clone()),
            principal.clone(),
            Json(SweepReq {
                device_id: "dev-1".into(),
            }),
        )
        .await
        .unwrap();
        assert_eq!(swept.swept_credits, 0);
        let Json(summary) = remove_device(
            State(state.clone()),
            principal,
            Json(RemoveDeviceReq {
                device_id: "dev-1".into(),
            }),
        )
        .await
        .unwrap();
        assert!(summary.devices.is_empty());
    }
}
