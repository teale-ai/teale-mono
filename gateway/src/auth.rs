//! Bearer-token auth middleware.
//!
//! Tokens are loaded from env (`GATEWAY_TOKENS`) at startup. Format is
//! comma-separated `token:scope` pairs, e.g.:
//!   GATEWAY_TOKENS=tok_abc:openrouter,tok_dev:internal
//!
//! Scopes aren't checked today — the presence of any valid token is enough.
//! When we need to gate by scope (e.g. admin endpoints), extend here.

use std::collections::HashMap;
use std::sync::Arc;

use axum::{
    extract::Request,
    http::{header, StatusCode},
    middleware::Next,
    response::Response,
};

#[derive(Debug, Clone, Default)]
pub struct TokenTable {
    /// Map: token → scope (tag).
    tokens: Arc<HashMap<String, String>>,
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
                "{} is empty — gateway will accept any bearer token. DO NOT run this in production.",
                var
            );
        } else {
            tracing::info!("Loaded {} bearer token(s) from {}", map.len(), var);
        }
        Self {
            tokens: Arc::new(map),
        }
    }

    pub fn is_valid(&self, token: &str) -> bool {
        if self.tokens.is_empty() {
            return true; // permissive for dev (logged warning at startup)
        }
        self.tokens.contains_key(token)
    }

    pub fn scope(&self, token: &str) -> Option<&str> {
        self.tokens.get(token).map(String::as_str)
    }
}

/// Axum middleware: require `Authorization: Bearer <token>` where token is
/// in the TokenTable. Rejects with 401 otherwise.
pub async fn require_bearer(
    axum::extract::State(table): axum::extract::State<TokenTable>,
    req: Request,
    next: Next,
) -> Result<Response, StatusCode> {
    let header = req
        .headers()
        .get(header::AUTHORIZATION)
        .and_then(|h| h.to_str().ok())
        .unwrap_or("");

    let token = header.strip_prefix("Bearer ").unwrap_or("").trim();

    if token.is_empty() || !table.is_valid(token) {
        return Err(StatusCode::UNAUTHORIZED);
    }

    Ok(next.run(req).await)
}
