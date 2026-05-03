//! Programmatic API keys scoped to an account.
//!
//! Live keys can call inference; provisioning keys can additionally manage
//! other keys (CRUD on `/v1/keys`). Spend is debited from the owning
//! `account_wallet`'s credit balance and attributed back to the calling key
//! via `api_keys.usage_credits` plus an `api_key_id` stamp on the
//! `account_ledger` row.
//!
//! Tokens are hashed at rest (SHA-256). The plaintext is returned to the
//! caller exactly once at creation time.

use rand::RngCore;
use rusqlite::{params, OptionalExtension};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use thiserror::Error;
use uuid::Uuid;

use crate::db::{unix_now, DbPool};

/// Token prefix for live (inference-only) keys.
pub const LIVE_PREFIX: &str = "tk_live_";
/// Token prefix for provisioning keys (can mint/list/update/revoke other keys).
pub const PROVISIONING_PREFIX: &str = "tk_prov_";
/// Number of random bytes (pre-base32) in a freshly minted token.
const SECRET_BYTES: usize = 24;
/// Display-prefix length kept after the `tk_<role>_` marker. Just enough to
/// identify a key in dashboards without exposing the secret.
const PREFIX_DISPLAY_LEN: usize = 8;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum ApiKeyRole {
    Live,
    Provisioning,
}

impl ApiKeyRole {
    pub fn as_str(&self) -> &'static str {
        match self {
            ApiKeyRole::Live => "live",
            ApiKeyRole::Provisioning => "provisioning",
        }
    }

    pub fn parse(s: &str) -> Option<Self> {
        match s {
            "live" => Some(ApiKeyRole::Live),
            "provisioning" => Some(ApiKeyRole::Provisioning),
            _ => None,
        }
    }

    fn token_prefix(&self) -> &'static str {
        match self {
            ApiKeyRole::Live => LIVE_PREFIX,
            ApiKeyRole::Provisioning => PROVISIONING_PREFIX,
        }
    }
}

#[derive(Debug, Clone, Serialize)]
pub struct ApiKeyPublic {
    #[serde(rename = "keyID")]
    pub key_id: String,
    #[serde(rename = "accountUserID")]
    pub account_user_id: String,
    pub prefix: String,
    pub name: Option<String>,
    pub role: ApiKeyRole,
    #[serde(rename = "creditLimit", skip_serializing_if = "Option::is_none")]
    pub credit_limit: Option<i64>,
    #[serde(rename = "usageCredits")]
    pub usage_credits: i64,
    pub disabled: bool,
    #[serde(rename = "createdAt")]
    pub created_at: i64,
    #[serde(rename = "lastUsedAt", skip_serializing_if = "Option::is_none")]
    pub last_used_at: Option<i64>,
}

#[derive(Debug, Clone, Serialize)]
pub struct ApiKeyMinted {
    #[serde(flatten)]
    pub public: ApiKeyPublic,
    /// The plaintext token. Only ever returned at creation time; never stored.
    pub token: String,
}

/// Resolved at auth time from a bearer token.
#[derive(Debug, Clone)]
pub struct ResolvedApiKey {
    pub key_id: String,
    pub account_user_id: String,
    pub role: ApiKeyRole,
    pub credit_limit: Option<i64>,
    pub usage_credits: i64,
    pub disabled: bool,
}

impl ResolvedApiKey {
    pub fn remaining_credit_limit(&self) -> Option<i64> {
        self.credit_limit
            .map(|limit| (limit - self.usage_credits).max(0))
    }
}

#[derive(Debug, Error)]
pub enum ApiKeyError {
    #[error("api key not found")]
    NotFound,
    #[error("invalid name")]
    InvalidName,
    #[error("invalid credit limit")]
    InvalidCreditLimit,
    #[error("provisioning role required")]
    ProvisioningRequired,
    #[error(transparent)]
    Db(#[from] rusqlite::Error),
    #[error(transparent)]
    Other(#[from] anyhow::Error),
}

pub fn hash_token(token: &str) -> String {
    let digest = Sha256::digest(token.as_bytes());
    hex::encode(digest)
}

fn random_token(role: ApiKeyRole) -> String {
    let mut bytes = [0u8; SECRET_BYTES];
    rand::thread_rng().fill_bytes(&mut bytes);
    format!("{}{}", role.token_prefix(), hex::encode(bytes))
}

fn display_prefix(token: &str) -> String {
    let role_prefix_len = if token.starts_with(PROVISIONING_PREFIX) {
        PROVISIONING_PREFIX.len()
    } else if token.starts_with(LIVE_PREFIX) {
        LIVE_PREFIX.len()
    } else {
        0
    };
    let take = role_prefix_len + PREFIX_DISPLAY_LEN.min(token.len() - role_prefix_len);
    let take = take.min(token.len());
    token[..take].to_string()
}

pub fn looks_like_api_key(token: &str) -> bool {
    token.starts_with(LIVE_PREFIX) || token.starts_with(PROVISIONING_PREFIX)
}

#[derive(Debug, Clone, Default)]
pub struct CreateApiKeyParams {
    pub name: Option<String>,
    pub role: Option<ApiKeyRole>,
    pub credit_limit: Option<i64>,
}

pub fn create_api_key(
    pool: &DbPool,
    account_user_id: &str,
    params: CreateApiKeyParams,
) -> Result<ApiKeyMinted, ApiKeyError> {
    let role = params.role.unwrap_or(ApiKeyRole::Live);
    if let Some(limit) = params.credit_limit {
        if limit < 0 {
            return Err(ApiKeyError::InvalidCreditLimit);
        }
    }
    let name = params
        .name
        .as_deref()
        .map(|n| n.trim())
        .filter(|n| !n.is_empty())
        .map(str::to_string);
    if let Some(ref n) = name {
        if n.len() > 128 {
            return Err(ApiKeyError::InvalidName);
        }
    }

    let token = random_token(role);
    let key_hash = hash_token(&token);
    let key_id = Uuid::new_v4().to_string();
    let prefix = display_prefix(&token);
    let created_at = unix_now();

    let conn = pool.lock();
    conn.execute(
        "INSERT INTO api_keys (key_id, account_user_id, key_hash, prefix, name, role,
                               credit_limit, usage_credits, disabled, created_at, last_used_at)
         VALUES (?, ?, ?, ?, ?, ?, ?, 0, 0, ?, NULL)",
        params![
            key_id,
            account_user_id,
            key_hash,
            prefix,
            name,
            role.as_str(),
            params.credit_limit,
            created_at,
        ],
    )?;
    drop(conn);

    let public = ApiKeyPublic {
        key_id,
        account_user_id: account_user_id.to_string(),
        prefix,
        name,
        role,
        credit_limit: params.credit_limit,
        usage_credits: 0,
        disabled: false,
        created_at,
        last_used_at: None,
    };
    Ok(ApiKeyMinted { public, token })
}

pub fn list_api_keys(
    pool: &DbPool,
    account_user_id: &str,
) -> Result<Vec<ApiKeyPublic>, ApiKeyError> {
    let conn = pool.lock();
    let mut stmt = conn.prepare(
        "SELECT key_id, prefix, name, role, credit_limit, usage_credits, disabled,
                created_at, last_used_at
         FROM api_keys
         WHERE account_user_id = ?
         ORDER BY created_at DESC, key_id ASC",
    )?;
    let rows = stmt.query_map([account_user_id], |r| {
        Ok((
            r.get::<_, String>(0)?,
            r.get::<_, String>(1)?,
            r.get::<_, Option<String>>(2)?,
            r.get::<_, String>(3)?,
            r.get::<_, Option<i64>>(4)?,
            r.get::<_, i64>(5)?,
            r.get::<_, i64>(6)?,
            r.get::<_, i64>(7)?,
            r.get::<_, Option<i64>>(8)?,
        ))
    })?;
    let mut out = Vec::new();
    for row in rows {
        let (
            key_id,
            prefix,
            name,
            role_s,
            credit_limit,
            usage_credits,
            disabled,
            created_at,
            last_used_at,
        ) = row?;
        let role = ApiKeyRole::parse(&role_s).unwrap_or(ApiKeyRole::Live);
        out.push(ApiKeyPublic {
            key_id,
            account_user_id: account_user_id.to_string(),
            prefix,
            name,
            role,
            credit_limit,
            usage_credits,
            disabled: disabled != 0,
            created_at,
            last_used_at,
        });
    }
    Ok(out)
}

pub fn get_api_key(
    pool: &DbPool,
    account_user_id: &str,
    key_id: &str,
) -> Result<ApiKeyPublic, ApiKeyError> {
    let conn = pool.lock();
    let row = conn
        .query_row(
            "SELECT prefix, name, role, credit_limit, usage_credits, disabled,
                    created_at, last_used_at
             FROM api_keys
             WHERE key_id = ? AND account_user_id = ?",
            params![key_id, account_user_id],
            |r| {
                Ok((
                    r.get::<_, String>(0)?,
                    r.get::<_, Option<String>>(1)?,
                    r.get::<_, String>(2)?,
                    r.get::<_, Option<i64>>(3)?,
                    r.get::<_, i64>(4)?,
                    r.get::<_, i64>(5)?,
                    r.get::<_, i64>(6)?,
                    r.get::<_, Option<i64>>(7)?,
                ))
            },
        )
        .optional()?;
    let (prefix, name, role_s, credit_limit, usage_credits, disabled, created_at, last_used_at) =
        row.ok_or(ApiKeyError::NotFound)?;
    let role = ApiKeyRole::parse(&role_s).unwrap_or(ApiKeyRole::Live);
    Ok(ApiKeyPublic {
        key_id: key_id.to_string(),
        account_user_id: account_user_id.to_string(),
        prefix,
        name,
        role,
        credit_limit,
        usage_credits,
        disabled: disabled != 0,
        created_at,
        last_used_at,
    })
}

#[derive(Debug, Clone, Default)]
pub struct UpdateApiKeyParams {
    pub name: Option<Option<String>>,
    pub credit_limit: Option<Option<i64>>,
    pub disabled: Option<bool>,
}

pub fn update_api_key(
    pool: &DbPool,
    account_user_id: &str,
    key_id: &str,
    params: UpdateApiKeyParams,
) -> Result<ApiKeyPublic, ApiKeyError> {
    if let Some(Some(limit)) = params.credit_limit {
        if limit < 0 {
            return Err(ApiKeyError::InvalidCreditLimit);
        }
    }
    if let Some(Some(ref n)) = params.name {
        if n.trim().is_empty() || n.len() > 128 {
            return Err(ApiKeyError::InvalidName);
        }
    }

    let conn = pool.lock();
    let exists: bool = conn
        .query_row(
            "SELECT 1 FROM api_keys WHERE key_id = ? AND account_user_id = ?",
            params![key_id, account_user_id],
            |_| Ok(true),
        )
        .optional()?
        .unwrap_or(false);
    if !exists {
        return Err(ApiKeyError::NotFound);
    }

    if let Some(name_change) = params.name {
        let normalized = name_change.map(|n| n.trim().to_string());
        conn.execute(
            "UPDATE api_keys SET name = ? WHERE key_id = ?",
            params![normalized, key_id],
        )?;
    }
    if let Some(limit_change) = params.credit_limit {
        conn.execute(
            "UPDATE api_keys SET credit_limit = ? WHERE key_id = ?",
            params![limit_change, key_id],
        )?;
    }
    if let Some(disabled) = params.disabled {
        conn.execute(
            "UPDATE api_keys SET disabled = ? WHERE key_id = ?",
            params![if disabled { 1i64 } else { 0i64 }, key_id],
        )?;
    }
    drop(conn);

    get_api_key(pool, account_user_id, key_id)
}

pub fn delete_api_key(
    pool: &DbPool,
    account_user_id: &str,
    key_id: &str,
) -> Result<(), ApiKeyError> {
    let conn = pool.lock();
    let rows = conn.execute(
        "DELETE FROM api_keys WHERE key_id = ? AND account_user_id = ?",
        params![key_id, account_user_id],
    )?;
    if rows == 0 {
        return Err(ApiKeyError::NotFound);
    }
    Ok(())
}

/// Auth middleware path: look up a key by its plaintext bearer.
pub fn resolve_api_key(pool: &DbPool, token: &str) -> Option<ResolvedApiKey> {
    if !looks_like_api_key(token) {
        return None;
    }
    let key_hash = hash_token(token);
    let conn = pool.lock();
    let row = conn
        .query_row(
            "SELECT key_id, account_user_id, role, credit_limit, usage_credits, disabled
             FROM api_keys WHERE key_hash = ?",
            [key_hash],
            |r| {
                Ok((
                    r.get::<_, String>(0)?,
                    r.get::<_, String>(1)?,
                    r.get::<_, String>(2)?,
                    r.get::<_, Option<i64>>(3)?,
                    r.get::<_, i64>(4)?,
                    r.get::<_, i64>(5)?,
                ))
            },
        )
        .ok()?;
    let (key_id, account_user_id, role_s, credit_limit, usage_credits, disabled) = row;
    let role = ApiKeyRole::parse(&role_s)?;
    Some(ResolvedApiKey {
        key_id,
        account_user_id,
        role,
        credit_limit,
        usage_credits,
        disabled: disabled != 0,
    })
}

/// Bump `last_used_at` to "now". Best-effort; ignores errors.
pub fn touch_last_used(pool: &DbPool, key_id: &str) {
    let conn = pool.lock();
    let _ = conn.execute(
        "UPDATE api_keys SET last_used_at = ? WHERE key_id = ?",
        params![unix_now(), key_id],
    );
}
