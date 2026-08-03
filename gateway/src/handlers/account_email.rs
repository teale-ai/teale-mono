//! Email-code account verification for gateway human accounts.
//!
//! These endpoints are protected by the normal device bearer middleware. The
//! email code proves control of an address; the device bearer proves the app
//! instance that is asking to link the account.

use axum::{extract::State, Json};
use rand::Rng;
use serde::{Deserialize, Serialize};
use serde_json::json;

use crate::error::GatewayError;
use crate::ledger;
use crate::state::AppState;

#[derive(Debug, Deserialize)]
pub struct EmailCodeRequestReq {
    pub email: String,
}

#[derive(Debug, Serialize)]
pub struct EmailCodeRequestRes {
    pub email: String,
    #[serde(rename = "expiresAt")]
    pub expires_at: i64,
}

#[derive(Debug, Deserialize)]
pub struct EmailCodeVerifyReq {
    pub email: String,
    pub code: String,
}

#[derive(Debug, Serialize)]
pub struct EmailCodeVerifyRes {
    #[serde(rename = "accountUserID")]
    pub account_user_id: String,
    pub email: String,
}

pub async fn request(
    State(state): State<AppState>,
    Json(req): Json<EmailCodeRequestReq>,
) -> Result<Json<EmailCodeRequestRes>, GatewayError> {
    let pool = state
        .db
        .as_ref()
        .ok_or_else(|| GatewayError::Other(anyhow::anyhow!("db not initialized")))?;
    let email = ledger::normalize_account_email(&req.email)
        .ok_or_else(|| GatewayError::BadRequest("valid email is required".into()))?;
    let code = format!("{:06}", rand::thread_rng().gen_range(0..1_000_000));
    let created = ledger::create_account_email_code(pool, &email, &code)
        .map_err(|err| GatewayError::BadRequest(err.to_string()))?;
    send_email_code(&email, &code).await?;
    Ok(Json(EmailCodeRequestRes {
        email: created.email,
        expires_at: created.expires_at,
    }))
}

pub async fn verify(
    State(state): State<AppState>,
    Json(req): Json<EmailCodeVerifyReq>,
) -> Result<Json<EmailCodeVerifyRes>, GatewayError> {
    let pool = state
        .db
        .as_ref()
        .ok_or_else(|| GatewayError::Other(anyhow::anyhow!("db not initialized")))?;
    let verified = ledger::verify_account_email_code(pool, &req.email, &req.code)
        .map_err(|err| GatewayError::BadRequest(err.to_string()))?;
    Ok(Json(EmailCodeVerifyRes {
        account_user_id: verified.account_user_id,
        email: verified.email,
    }))
}

async fn send_email_code(email: &str, code: &str) -> Result<(), GatewayError> {
    let api_key = std::env::var("GATEWAY_EMAIL_RESEND_API_KEY").unwrap_or_default();
    let from = std::env::var("GATEWAY_EMAIL_FROM").unwrap_or_default();
    if api_key.trim().is_empty() || from.trim().is_empty() {
        if std::env::var("GATEWAY_EMAIL_DEV_LOG_CODES").ok().as_deref() == Some("1") {
            tracing::warn!(email = %email, code = %code, "gateway email code generated");
            return Ok(());
        }
        return Err(GatewayError::Other(anyhow::anyhow!(
            "gateway email sender is not configured"
        )));
    }

    let subject = format!("{code} is your Teale verification code");
    let body = format!(
        "Your Teale verification code is {code}. It expires in 10 minutes.\n\nIf you did not request this code, you can ignore this email."
    );
    let payload = json!({
        "from": from,
        "to": [email],
        "subject": subject,
        "text": body,
    });
    let response = reqwest::Client::new()
        .post("https://api.resend.com/emails")
        .bearer_auth(api_key)
        .json(&payload)
        .send()
        .await
        .map_err(|err| GatewayError::Other(anyhow::anyhow!("send email code: {err}")))?;
    if !response.status().is_success() {
        let status = response.status();
        let detail = response.text().await.unwrap_or_default();
        return Err(GatewayError::Upstream(format!(
            "email provider returned {status}: {detail}"
        )));
    }
    Ok(())
}
