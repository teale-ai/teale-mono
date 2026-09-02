//! Passwordless email auth for gateway human accounts.
//!
//! These endpoints own the full login flow in the gateway: request a code
//! (plus a magic link) over Resend, verify it, and mint an opaque session
//! token (`tsess_…`, SHA-256 hashed at rest). No passwords, no Supabase.
//! See docs/passwordless-auth-migration.md.

use axum::{
    extract::{Path, State},
    http::{header, HeaderMap, StatusCode},
    response::{Html, IntoResponse, Redirect, Response},
    Extension, Json,
};
use rand::Rng;
use serde::{Deserialize, Serialize};
use serde_json::json;

use crate::auth::AuthPrincipal;
use crate::error::GatewayError;
use crate::ledger;
use crate::state::AppState;

#[derive(Debug, Deserialize)]
pub struct EmailLoginRequestReq {
    pub email: String,
}

#[derive(Debug, Serialize)]
pub struct EmailLoginRequestRes {
    pub email: String,
    #[serde(rename = "expiresAt")]
    pub expires_at: i64,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct EmailLoginVerifyReq {
    pub email: String,
    pub code: String,
    pub device_id: Option<String>,
    pub device_name: Option<String>,
}

#[derive(Debug, Serialize)]
pub struct EmailLoginVerifyRes {
    #[serde(rename = "sessionToken")]
    pub session_token: String,
    #[serde(rename = "expiresAt")]
    pub expires_at: i64,
    #[serde(rename = "accountUserID")]
    pub account_user_id: String,
    pub email: String,
}

#[derive(Debug, Serialize)]
pub struct SessionInfoRes {
    #[serde(rename = "accountUserID")]
    pub account_user_id: String,
    pub email: Option<String>,
    #[serde(rename = "sessionId")]
    pub session_id: String,
}

/// POST /v1/auth/email/request — send a sign-in email with a 6-digit code
/// and a magic link. Same response shape whether or not the address has an
/// account; accounts are resolved at verify time.
pub async fn request(
    State(state): State<AppState>,
    Json(req): Json<EmailLoginRequestReq>,
) -> Result<Json<EmailLoginRequestRes>, GatewayError> {
    let pool = state
        .db
        .as_ref()
        .ok_or_else(|| GatewayError::Other(anyhow::anyhow!("db not initialized")))?;
    let email = ledger::normalize_account_email(&req.email)
        .ok_or_else(|| GatewayError::BadRequest("valid email is required".into()))?;
    let code = format!("{:06}", rand::thread_rng().gen_range(0..1_000_000));
    let link_token = ledger::generate_account_session_token();
    let created = ledger::create_account_email_login_code(pool, &email, &code, &link_token)
        .map_err(|err| GatewayError::BadRequest(err.to_string()))?;
    send_login_email(&email, &code, &link_token).await?;
    Ok(Json(EmailLoginRequestRes {
        email: created.email,
        expires_at: created.expires_at,
    }))
}

/// POST /v1/auth/email/verify — consume a 6-digit code and mint a session.
pub async fn verify(
    State(state): State<AppState>,
    Json(req): Json<EmailLoginVerifyReq>,
) -> Result<Json<EmailLoginVerifyRes>, GatewayError> {
    let pool = state
        .db
        .as_ref()
        .ok_or_else(|| GatewayError::Other(anyhow::anyhow!("db not initialized")))?;
    let verified = ledger::verify_account_email_code(pool, &req.email, &req.code)
        .map_err(|err| GatewayError::BadRequest(err.to_string()))?;
    let account_user_id =
        ledger::account_user_id_for_login(pool, &verified.email).map_err(GatewayError::Other)?;
    let issued = ledger::create_account_session(
        pool,
        &account_user_id,
        req.device_id.as_deref(),
        req.device_name.as_deref(),
    )
    .map_err(GatewayError::Other)?;
    Ok(Json(EmailLoginVerifyRes {
        session_token: issued.token,
        expires_at: issued.expires_at,
        account_user_id,
        email: verified.email,
    }))
}

/// GET /v1/auth/link/:token — magic-link sign-in. Consumes the link token,
/// mints a session, and redirects to the app deep link. Browsers without the
/// app get a minimal HTML page showing the token for manual entry.
pub async fn link(
    State(state): State<AppState>,
    Path(token): Path<String>,
    headers: HeaderMap,
) -> Result<Response, GatewayError> {
    let pool = state
        .db
        .as_ref()
        .ok_or_else(|| GatewayError::Other(anyhow::anyhow!("db not initialized")))?;
    let verified = ledger::verify_account_email_link_token(pool, &token)
        .map_err(|err| GatewayError::BadRequest(err.to_string()))?;
    let account_user_id =
        ledger::account_user_id_for_login(pool, &verified.email).map_err(GatewayError::Other)?;
    let issued = ledger::create_account_session(pool, &account_user_id, None, None)
        .map_err(GatewayError::Other)?;

    let wants_html = headers
        .get(header::ACCEPT)
        .and_then(|v| v.to_str().ok())
        .map(|v| v.contains("text/html"))
        .unwrap_or(false);
    if wants_html {
        let deep_link = format!("teale://auth/session?token={}", issued.token);
        let page = format!(
            "<!doctype html><html><head><meta charset=\"utf-8\">\
             <meta http-equiv=\"refresh\" content=\"0;url={deep_link}\">\
             <title>Teale sign-in</title></head><body>\
             <p>Signed in as {}. <a href=\"{deep_link}\">Open Teale</a></p>\
             <p>If the app did not open, paste this token into it:<br><code>{}</code></p>\
             </body></html>",
            html_escape(&verified.email),
            issued.token
        );
        return Ok(Html(page).into_response());
    }
    Ok(
        Redirect::temporary(&format!("teale://auth/session?token={}", issued.token))
            .into_response(),
    )
}

/// GET /v1/auth/session — validate a session bearer and return the identity.
/// Sliding renewal is a side effect of resolution.
pub async fn session(
    State(state): State<AppState>,
    Extension(principal): Extension<AuthPrincipal>,
) -> Result<Json<SessionInfoRes>, GatewayError> {
    let (account_user_id, session_id) = principal
        .account_session()
        .ok_or_else(|| GatewayError::Unauthorized("account session bearer required".into()))?;
    let pool = state
        .db
        .as_ref()
        .ok_or_else(|| GatewayError::Other(anyhow::anyhow!("db not initialized")))?;
    let email = ledger::account_email_for_user(pool, account_user_id);
    Ok(Json(SessionInfoRes {
        account_user_id: account_user_id.to_string(),
        email,
        session_id: session_id.to_string(),
    }))
}

/// POST /v1/auth/logout — revoke the session presented in the bearer header.
pub async fn logout(
    State(state): State<AppState>,
    Extension(principal): Extension<AuthPrincipal>,
    headers: HeaderMap,
) -> Result<StatusCode, GatewayError> {
    let _ = principal
        .account_session()
        .ok_or_else(|| GatewayError::Unauthorized("account session bearer required".into()))?;
    let pool = state
        .db
        .as_ref()
        .ok_or_else(|| GatewayError::Other(anyhow::anyhow!("db not initialized")))?;
    let token = headers
        .get(header::AUTHORIZATION)
        .and_then(|h| h.to_str().ok())
        .and_then(|v| v.strip_prefix("Bearer "))
        .map(str::trim)
        .unwrap_or("");
    ledger::revoke_account_session(pool, token);
    Ok(StatusCode::NO_CONTENT)
}

/// Minimal HTML escaping for values interpolated into the fallback page.
fn html_escape(value: &str) -> String {
    value
        .replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
        .replace('"', "&quot;")
}

fn public_base_url() -> String {
    std::env::var("GATEWAY_PUBLIC_BASE_URL")
        .ok()
        .map(|v| v.trim_end_matches('/').to_string())
        .filter(|v| !v.is_empty())
        .unwrap_or_else(|| "https://gateway.teale.com".to_string())
}

async fn send_login_email(email: &str, code: &str, link_token: &str) -> Result<(), GatewayError> {
    let api_key = std::env::var("GATEWAY_EMAIL_RESEND_API_KEY").unwrap_or_default();
    let from = std::env::var("GATEWAY_EMAIL_FROM").unwrap_or_default();
    if api_key.trim().is_empty() || from.trim().is_empty() {
        if std::env::var("GATEWAY_EMAIL_DEV_LOG_CODES").ok().as_deref() == Some("1") {
            tracing::warn!(email = %email, code = %code, link_token = %link_token, "gateway login email generated");
            return Ok(());
        }
        return Err(GatewayError::Other(anyhow::anyhow!(
            "gateway email sender is not configured"
        )));
    }

    let link = format!("{}/v1/auth/link/{}", public_base_url(), link_token);
    let subject = format!("{code} is your Teale sign-in code");
    let body = format!(
        "Your Teale sign-in code is {code}. It expires in 10 minutes.\n\n\
         Or click to sign in: {link}\n\n\
         If you did not request this, you can ignore this email."
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
        .map_err(|err| GatewayError::Other(anyhow::anyhow!("send login email: {err}")))?;
    if !response.status().is_success() {
        let status = response.status();
        let detail = response.text().await.unwrap_or_default();
        return Err(GatewayError::Upstream(format!(
            "email provider returned {status}: {detail}"
        )));
    }
    Ok(())
}
