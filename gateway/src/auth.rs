//! Bearer-token auth middleware.
//!
//! Four token paths are supported in parallel:
//!
//! 1. **Static tokens** from env (`GATEWAY_TOKENS`), loaded at startup. Format
//!    is comma-separated `token:scope` pairs, e.g.
//!    `GATEWAY_TOKENS=tok_abc:openrouter,tok_dev:internal`.
//!    These keep existing OpenRouter / internal integrations working.
//!
//! 2. **Device tokens** issued by `/v1/auth/device/exchange`, persisted in
//!    SQLite. The middleware queries the DB for these after the static table
//!    misses. Valid device tokens are also bound to a `deviceID` which we
//!    stash in a request extension so downstream handlers can attribute
//!    spend / earn.
//!
//! 3. **Programmatic API keys** (`tk_live_…` / `tk_prov_…`) minted for linked
//!    human accounts. Spending debits the account_wallet and is attributed
//!    back to the originating key for usage rollups.
//!
//! 4. **Share keys** — short-lived scoped bearers minted by a device for
//!    community previews; the key carries its own funded budget.
//!
//! On success, the middleware attaches an `AuthPrincipal` request extension.

use std::collections::HashMap;
use std::sync::Arc;

use axum::{
    extract::{Request, State},
    http::{header, HeaderMap, StatusCode},
    middleware::Next,
    response::Response,
};

use crate::api_keys::{self, ApiKeyRole};
use crate::ledger;
use crate::state::AppState;

#[derive(Debug, Clone, Default)]
pub struct TokenTable {
    /// Map: token → scope (tag).
    tokens: Arc<HashMap<String, String>>,
}

/// Identity resolved from a bearer token. Stashed in the request extensions
/// by the `require_bearer` middleware so handlers can call
/// `req.extensions().get::<AuthPrincipal>()`.
#[derive(Debug, Clone)]
pub struct AuthPrincipal {
    pub kind: PrincipalKind,
}

#[derive(Debug, Clone)]
pub enum PrincipalKind {
    /// Static token (from GATEWAY_TOKENS env)
    Static { scope: String },
    /// Device-bound token issued by /v1/auth/device/exchange
    Device { device_id: String },
    /// Temporary share key minted by a device for community previews.
    /// Spending debits the key's funded pool and ticks the key's
    /// `consumed_credits`; exhaustion/expiry/revoke is enforced in middleware.
    Share {
        issuer_device_id: String,
        key_id: String,
        /// Snapshot at auth time; `settle_request` re-reads under lock for truth.
        budget_remaining: i64,
    },
    /// Programmatic API key bound to an account. Spending debits the
    /// account_wallet's credit balance and increments `api_keys.usage_credits`.
    /// Provisioning keys can additionally manage other keys.
    ApiKey {
        key_id: String,
        account_user_id: String,
        role: ApiKeyRole,
        /// Snapshot at auth time; settle re-checks under lock.
        credit_limit: Option<i64>,
        /// Snapshot at auth time.
        usage_credits: i64,
    },
}

impl AuthPrincipal {
    pub fn device_id(&self) -> Option<&str> {
        match &self.kind {
            PrincipalKind::Device { device_id } => Some(device_id),
            _ => None,
        }
    }

    /// Returns `(issuer_device_id, key_id)` for share-key principals.
    pub fn share_key(&self) -> Option<(&str, &str)> {
        match &self.kind {
            PrincipalKind::Share {
                issuer_device_id,
                key_id,
                ..
            } => Some((issuer_device_id.as_str(), key_id.as_str())),
            _ => None,
        }
    }

    /// Returns `(key_id, account_user_id, role)` for API-key principals.
    pub fn api_key(&self) -> Option<(&str, &str, ApiKeyRole)> {
        match &self.kind {
            PrincipalKind::ApiKey {
                key_id,
                account_user_id,
                role,
                ..
            } => Some((key_id.as_str(), account_user_id.as_str(), *role)),
            _ => None,
        }
    }
}

impl TokenTable {
    pub fn from_env(var: &str) -> Self {
        let raw = std::env::var(var).unwrap_or_default();
        let mut map: HashMap<String, String> = HashMap::new();
        for entry in raw.split(',').map(str::trim).filter(|s| !s.is_empty()) {
            if let Some((tok, scope)) = entry.split_once(':') {
                map.insert(tok.trim().to_string(), scope.trim().to_string());
            } else {
                map.insert(entry.to_string(), "default".to_string());
            }
        }
        if map.is_empty() {
            tracing::warn!(
                "{} is empty — static-token path disabled; only device-issued \
                 tokens will be accepted (and anonymous fallback for dev).",
                var
            );
        } else {
            tracing::info!("Loaded {} static bearer token(s) from {}", map.len(), var);
        }
        Self {
            tokens: Arc::new(map),
        }
    }

    pub fn lookup_static(&self, token: &str) -> Option<String> {
        self.tokens.get(token).cloned()
    }

    pub fn is_empty(&self) -> bool {
        self.tokens.is_empty()
    }
}

/// Axum middleware: require a valid bearer (static OR device token). On
/// success, attaches an `AuthPrincipal` extension to the request.
pub async fn require_bearer(
    State(state): State<AppState>,
    mut req: Request,
    next: Next,
) -> Result<Response, StatusCode> {
    let token = token_from_headers(req.headers());

    if token.is_empty() {
        return Err(StatusCode::UNAUTHORIZED);
    }

    // 1) Static-token match
    if let Some(scope) = state.tokens.lookup_static(&token) {
        req.extensions_mut().insert(AuthPrincipal {
            kind: PrincipalKind::Static { scope },
        });
        return Ok(next.run(req).await);
    }

    // 2) Device-token match (via DB)
    if let Some(pool) = state.db.as_ref() {
        if let Some(device_id) = ledger::resolve_token(pool, &token) {
            req.extensions_mut().insert(AuthPrincipal {
                kind: PrincipalKind::Device { device_id },
            });
            return Ok(next.run(req).await);
        }
    }

    // 2a) Programmatic API-key match. Disabled keys are rejected with 401;
    //     credit-limit exhaustion is enforced at settle time, not auth time
    //     (so /v1/keys, /v1/credits, /v1/key still work for inspection).
    if let Some(pool) = state.db.as_ref() {
        if let Some(resolved) = api_keys::resolve_api_key(pool, &token) {
            if resolved.disabled {
                return Err(StatusCode::UNAUTHORIZED);
            }
            api_keys::touch_last_used(pool, &resolved.key_id);
            req.extensions_mut().insert(AuthPrincipal {
                kind: PrincipalKind::ApiKey {
                    key_id: resolved.key_id,
                    account_user_id: resolved.account_user_id,
                    role: resolved.role,
                    credit_limit: resolved.credit_limit,
                    usage_credits: resolved.usage_credits,
                },
            });
            return Ok(next.run(req).await);
        }
    }

    // 2b) Share-key match — temporary scoped bearers minted by a device.
    //     Rejection reasons (expired/revoked/exhausted) short-circuit here
    //     with the right status; a miss falls through.
    if let Some(pool) = state.db.as_ref() {
        match ledger::resolve_share_key(pool, &token) {
            Ok(Some(resolved)) => {
                let budget_remaining = resolved.remaining();
                req.extensions_mut().insert(AuthPrincipal {
                    kind: PrincipalKind::Share {
                        issuer_device_id: resolved.issuer_device_id,
                        key_id: resolved.key_id,
                        budget_remaining,
                    },
                });
                return Ok(next.run(req).await);
            }
            Ok(None) => { /* not a share key — fall through */ }
            Err(ledger::ShareKeyRejection::Exhausted) => {
                return Err(StatusCode::PAYMENT_REQUIRED);
            }
            Err(ledger::ShareKeyRejection::Expired) | Err(ledger::ShareKeyRejection::Revoked) => {
                return Err(StatusCode::UNAUTHORIZED);
            }
        }
    }

    // 3) Dev fallback: if *no* static tokens are configured at all, accept
    //    any non-empty bearer (matches previous permissive behaviour). Real
    //    deployments should set GATEWAY_TOKENS or require device auth.
    if state.tokens.is_empty() && state.db.is_none() {
        req.extensions_mut().insert(AuthPrincipal {
            kind: PrincipalKind::Static {
                scope: "dev-open".into(),
            },
        });
        return Ok(next.run(req).await);
    }

    Err(StatusCode::UNAUTHORIZED)
}

fn token_from_headers(headers: &HeaderMap) -> String {
    let header_val = headers
        .get(header::AUTHORIZATION)
        .and_then(|h| h.to_str().ok())
        .unwrap_or("");
    let bearer_token = header_val.strip_prefix("Bearer ").unwrap_or("").trim();
    if !bearer_token.is_empty() {
        return bearer_token.to_string();
    }
    headers
        .get("x-api-key")
        .and_then(|h| h.to_str().ok())
        .unwrap_or("")
        .trim()
        .to_string()
}

#[cfg(test)]
mod tests {
    use super::*;
    use axum::http::HeaderValue;

    #[test]
    fn token_from_headers_accepts_x_api_key_and_prefers_bearer() {
        let mut headers = HeaderMap::new();
        headers.insert("x-api-key", HeaderValue::from_static("anthropic-key"));
        assert_eq!(token_from_headers(&headers), "anthropic-key");

        headers.insert(
            header::AUTHORIZATION,
            HeaderValue::from_static("Bearer bearer-key"),
        );
        assert_eq!(token_from_headers(&headers), "bearer-key");
    }
}
