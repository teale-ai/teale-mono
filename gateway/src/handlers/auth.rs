//! Device-auth endpoints: challenge + exchange + username binding.
//!
//! POST /v1/auth/device/challenge
//!   Body:   { "deviceID": "<hex-pubkey>" }
//!   Return: { "nonce": "<base64>", "expiresAt": <unix> }
//!
//! POST /v1/auth/device/exchange
//!   Body:   { "deviceID", "nonce", "signature" (hex ed25519 over nonce bytes), "referralCode"? }
//!   Return: { "token": "tok_dev_<uuid>", "expiresAt": <unix> }
//!   Side-effect: welcome bonus on first exchange for this deviceID.
//!
//! PATCH /v1/auth/device/username
//!   Header: Authorization: Bearer <device token>
//!   Body:   { "username": "<alias>" }
//!   Return: { "deviceID", "username" }
//!
//! GET /v1/auth/referrals/code
//!   Header: Authorization: Bearer <device token>
//!   Return: { "code", "ownerKind", "ownerID" }

use axum::{extract::State, http::HeaderMap, Json};
use base64::Engine;
use ed25519_dalek::{Signature, Verifier, VerifyingKey};
use rand::RngCore;
use serde::{Deserialize, Serialize};
use uuid::Uuid;

use crate::error::GatewayError;
use crate::ledger;
use crate::state::AppState;

#[derive(Deserialize)]
pub struct ChallengeReq {
    #[serde(rename = "deviceID")]
    device_id: String,
}

#[derive(Serialize)]
pub struct ChallengeRes {
    nonce: String,
    #[serde(rename = "expiresAt")]
    expires_at: i64,
}

#[derive(Deserialize)]
pub struct ExchangeReq {
    #[serde(rename = "deviceID")]
    device_id: String,
    nonce: String,
    signature: String,
    #[serde(rename = "referralCode")]
    referral_code: Option<String>,
}

#[derive(Serialize)]
pub struct ExchangeRes {
    token: String,
    #[serde(rename = "expiresAt")]
    expires_at: i64,
    #[serde(rename = "welcomeBonus", skip_serializing_if = "Option::is_none")]
    welcome_bonus: Option<i64>,
    #[serde(rename = "referralBonus", skip_serializing_if = "Option::is_none")]
    referral_bonus: Option<i64>,
}

fn is_hex_pubkey(s: &str) -> bool {
    s.len() == 64 && s.chars().all(|c| c.is_ascii_hexdigit())
}

pub async fn challenge(
    State(state): State<AppState>,
    Json(req): Json<ChallengeReq>,
) -> Result<Json<ChallengeRes>, GatewayError> {
    if !is_hex_pubkey(&req.device_id) {
        return Err(GatewayError::BadRequest(
            "deviceID must be 64-char hex pubkey".into(),
        ));
    }

    let pool = state
        .db
        .as_ref()
        .ok_or_else(|| GatewayError::Other(anyhow::anyhow!("db not initialized")))?;

    // Upsert device record (we may not have seen this device before)
    ledger::upsert_device(pool, &req.device_id)
        .map_err(|e| GatewayError::Other(anyhow::anyhow!("upsert device: {}", e)))?;

    // Generate a random 32-byte nonce
    let mut bytes = [0u8; 32];
    rand::thread_rng().fill_bytes(&mut bytes);
    let nonce = base64::engine::general_purpose::STANDARD.encode(bytes);

    let expires_at = ledger::create_challenge(pool, &req.device_id, &nonce)
        .map_err(|e| GatewayError::Other(anyhow::anyhow!("create challenge: {}", e)))?;

    Ok(Json(ChallengeRes { nonce, expires_at }))
}

pub async fn exchange(
    State(state): State<AppState>,
    Json(req): Json<ExchangeReq>,
) -> Result<Json<ExchangeRes>, GatewayError> {
    if !is_hex_pubkey(&req.device_id) {
        return Err(GatewayError::BadRequest(
            "deviceID must be 64-char hex pubkey".into(),
        ));
    }

    let pool = state
        .db
        .as_ref()
        .ok_or_else(|| GatewayError::Other(anyhow::anyhow!("db not initialized")))?;

    // Verify signature: pubkey = bytes of deviceID hex
    let pubkey_bytes = hex::decode(&req.device_id)
        .map_err(|_| GatewayError::BadRequest("bad deviceID hex".into()))?;
    let pubkey_arr: [u8; 32] = pubkey_bytes
        .as_slice()
        .try_into()
        .map_err(|_| GatewayError::BadRequest("deviceID length".into()))?;
    let verifying_key = VerifyingKey::from_bytes(&pubkey_arr)
        .map_err(|e| GatewayError::BadRequest(format!("invalid pubkey: {}", e)))?;

    let sig_bytes = hex::decode(&req.signature)
        .map_err(|_| GatewayError::BadRequest("bad signature hex".into()))?;
    let sig_arr: [u8; 64] = sig_bytes
        .as_slice()
        .try_into()
        .map_err(|_| GatewayError::BadRequest("signature length".into()))?;
    let signature = Signature::from_bytes(&sig_arr);

    // The message signed is the nonce (base64-decoded bytes).
    let nonce_bytes = base64::engine::general_purpose::STANDARD
        .decode(&req.nonce)
        .map_err(|_| GatewayError::BadRequest("bad nonce b64".into()))?;

    verifying_key
        .verify(&nonce_bytes, &signature)
        .map_err(|_| GatewayError::Unauthorized("signature verification failed".into()))?;

    // Consume the challenge (returns true if it existed + not expired)
    let ok = ledger::consume_challenge(pool, &req.device_id, &req.nonce)
        .map_err(|e| GatewayError::Other(anyhow::anyhow!("consume challenge: {}", e)))?;
    if !ok {
        return Err(GatewayError::Unauthorized(
            "challenge not found or expired".into(),
        ));
    }

    let rewards =
        ledger::apply_device_join_rewards(pool, &req.device_id, req.referral_code.as_deref())
            .map_err(map_referral_error)?;
    let welcome_bonus =
        (rewards.welcome_bonus_credits > 0).then_some(rewards.welcome_bonus_credits);
    let referral_bonus =
        (rewards.referral_bonus_credits > 0).then_some(rewards.referral_bonus_credits);

    let token = format!("tok_dev_{}", Uuid::new_v4().simple());
    let expires_at = ledger::issue_token(pool, &req.device_id, &token)
        .map_err(|e| GatewayError::Other(anyhow::anyhow!("issue token: {}", e)))?;

    tracing::info!(
        device = %req.device_id,
        bonus = ?welcome_bonus,
        referral_bonus = ?referral_bonus,
        "issued device token"
    );

    Ok(Json(ExchangeRes {
        token,
        expires_at,
        welcome_bonus,
        referral_bonus,
    }))
}

#[derive(Deserialize)]
pub struct UsernameReq {
    username: String,
}

#[derive(Serialize)]
pub struct UsernameRes {
    #[serde(rename = "deviceID")]
    device_id: String,
    username: String,
}

pub async fn set_username(
    State(state): State<AppState>,
    headers: HeaderMap,
    Json(req): Json<UsernameReq>,
) -> Result<Json<UsernameRes>, GatewayError> {
    let trimmed = req.username.trim();
    if trimmed.is_empty() || trimmed.len() > 64 {
        return Err(GatewayError::BadRequest(
            "username must be 1-64 chars".into(),
        ));
    }
    let pool = state
        .db
        .as_ref()
        .ok_or_else(|| GatewayError::Other(anyhow::anyhow!("db not initialized")))?;
    let bearer = headers
        .get(axum::http::header::AUTHORIZATION)
        .and_then(|h| h.to_str().ok())
        .and_then(|s| s.strip_prefix("Bearer "))
        .map(str::trim)
        .unwrap_or("");
    let device_id = ledger::resolve_token(pool, bearer)
        .ok_or_else(|| GatewayError::Unauthorized("unknown or expired device token".into()))?;
    ledger::set_username(pool, &device_id, trimmed)
        .map_err(|e| GatewayError::Other(anyhow::anyhow!("set username: {}", e)))?;
    Ok(Json(UsernameRes {
        device_id,
        username: trimmed.to_string(),
    }))
}

pub async fn referral_code(
    State(state): State<AppState>,
    headers: HeaderMap,
) -> Result<Json<ledger::ReferralCodeSnapshot>, GatewayError> {
    let pool = state
        .db
        .as_ref()
        .ok_or_else(|| GatewayError::Other(anyhow::anyhow!("db not initialized")))?;
    let bearer = headers
        .get(axum::http::header::AUTHORIZATION)
        .and_then(|h| h.to_str().ok())
        .and_then(|s| s.strip_prefix("Bearer "))
        .map(str::trim)
        .unwrap_or("");
    let device_id = ledger::resolve_token(pool, bearer)
        .ok_or_else(|| GatewayError::Unauthorized("unknown or expired device token".into()))?;
    let snapshot = ledger::referral_code_for_device(pool, &device_id)
        .map_err(|e| GatewayError::Other(anyhow::anyhow!("referral code: {}", e)))?;
    Ok(Json(snapshot))
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
