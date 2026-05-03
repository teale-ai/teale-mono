//! Teale Credit ledger operations.
//!
//! The gateway is the source of truth for balances. All credit flows
//! (bonus, direct earn, availability earn, availability session, spent, ops fee)
//! are recorded as append-only rows in the `ledger` table, with a denormalized
//! `balances` table kept in sync for fast reads.
//!
//! Pricing peg: 1 Teale Credit = $0.000001 USD. Consumer cost per chat turn is
//! derived from the catalog's per-token USD prices: `credits = round((tokens_in
//! * prompt_price + tokens_out * completion_price) * 1_000_000)`.
//!
//! Settlement split: 70% direct provider / 25% availability pool (pro-rata to
//! other eligible online devices) / 5% teale network operator. Every balance
//! is non-negative; if the consumer's balance at settlement time is less than
//! the computed cost (concurrent-request edge case), all earners' shares are
//! reduced proportionally to what the consumer can actually pay and the
//! shortfall is noted on the SPENT row.

use std::cmp::Ordering;
use std::collections::HashMap;
use std::sync::Arc;

use rusqlite::params;
use serde::{Deserialize, Serialize};

use crate::db::{unix_now, DbPool};

pub const WELCOME_BONUS_CREDITS: i64 = 1_000;
pub const CHALLENGE_TTL_SECONDS: i64 = 300;
pub const TOKEN_TTL_SECONDS: i64 = 86_400;

/// Share-key bounds. Enforced by `mint_share_key`.
pub const SHARE_KEY_MIN_EXPIRES_IN: i64 = 60; // 1 minute
pub const SHARE_KEY_MAX_EXPIRES_IN: i64 = 30 * 86_400; // 30 days
pub const SHARE_KEY_MIN_BUDGET: i64 = 1;
pub const SHARE_KEY_MAX_BUDGET: i64 = 50_000_000; // $50
pub const SHARE_KEY_MAX_ACTIVE_PER_ISSUER: i64 = 50;
pub const SHARE_KEY_MAX_LABEL_LEN: usize = 64;

// Availability drip is priced off model cost. Hermes 3 / Llama 3.1 8B is the
// calibration point: 1 credit every 10 seconds while the model is available.
pub const DRIP_INTERVAL_SECS: u64 = 1;
pub const HERMES_REFERENCE_PROMPT_PRICE_USD: f64 = 0.00000010;
pub const HERMES_REFERENCE_COMPLETION_PRICE_USD: f64 = 0.00000020;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DripRecipient {
    pub device_id: String,
    pub credits: i64,
    pub model_id: Option<String>,
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "SCREAMING_SNAKE_CASE")]
pub enum LedgerType {
    Bonus,
    DirectEarn,
    AvailabilityEarn,
    AvailabilityDrip,
    AvailabilitySession,
    Spent,
    OpsFee,
    /// Issuer → share-key pool transfer at mint time (pre-funds the key).
    /// Not counted toward total_spent: the funds may be refunded on revoke.
    ShareKeyFund,
    /// Share-key pool → issuer transfer at revoke time (unused remainder).
    /// Not counted toward total_earned.
    ShareKeyRefund,
    /// Admin-initiated mint into a device wallet. Tracked separately from
    /// BONUS so audit trails distinguish operator top-ups from welcome bonuses.
    AdminMint,
    /// Centralized 3rd-party provider's 95% share of a settled request.
    /// Lives in `provider_ledger` (not the device `ledger`) since providers
    /// have their own wallet table. The OPS_FEE row that pairs with this
    /// (the 5% Teale take) still goes to the device ledger under `__ops__`.
    ProviderEarn,
    /// Off-ramp marker for provider payouts. Internal-only in v1 (no real
    /// USDC settlement), parity with `account_wallets.usdc_cents`.
    ProviderPayout,
}

impl LedgerType {
    pub fn as_str(&self) -> &'static str {
        match self {
            LedgerType::Bonus => "BONUS",
            LedgerType::DirectEarn => "DIRECT_EARN",
            LedgerType::AvailabilityEarn => "AVAILABILITY_EARN",
            LedgerType::AvailabilityDrip => "AVAILABILITY_DRIP",
            LedgerType::AvailabilitySession => "AVAILABILITY_SESSION",
            LedgerType::Spent => "SPENT",
            LedgerType::OpsFee => "OPS_FEE",
            LedgerType::ShareKeyFund => "SHARE_KEY_FUND",
            LedgerType::ShareKeyRefund => "SHARE_KEY_REFUND",
            LedgerType::AdminMint => "ADMIN_MINT",
            LedgerType::ProviderEarn => "PROVIDER_EARN",
            LedgerType::ProviderPayout => "PROVIDER_PAYOUT",
        }
    }
}

/// Who served the request and gets paid. Devices are members of the
/// distributed fleet; Providers are centralized 3rd-party vendors registered
/// via the marketplace onboarding flow.
#[derive(Debug, Clone)]
pub enum EarnerPrincipal {
    /// A registered Teale device served the request. Pays the existing
    /// 70/25/5 split (direct earner / availability pool / ops).
    Device { device_id: String },
    /// A centralized 3rd-party provider served the request. Pays 95/5
    /// (provider / ops). No availability pool — there is no idle co-serving
    /// fleet to share with on this path.
    Provider { provider_id: String },
}

#[derive(Debug, Clone, Serialize)]
pub struct LedgerEntry {
    pub id: i64,
    pub device_id: String,
    #[serde(rename = "type")]
    pub type_: String,
    pub amount: i64,
    pub timestamp: i64,
    #[serde(rename = "refRequestID")]
    pub ref_request_id: Option<String>,
    pub note: Option<String>,
}

/// Who is being charged for an inference request. Device spenders are
/// ordinary device-bound tokens; Share spenders are holders of a temporary
/// share key minted by a device — in that case the ledger attributes spend to
/// the issuer while debiting the share key's funded pool.
#[derive(Debug, Clone)]
pub enum ConsumerPrincipal {
    Device(String),
    Account {
        account_user_id: String,
    },
    Share {
        issuer_device_id: String,
        key_id: String,
    },
}

impl ConsumerPrincipal {
    /// Stable ledger-side identifier for logs and receipts.
    pub fn ledger_actor_id(&self) -> &str {
        match self {
            Self::Device(d) => d,
            Self::Account { account_user_id } => account_user_id,
            Self::Share {
                issuer_device_id, ..
            } => issuer_device_id,
        }
    }

    /// Device ID whose balance is debited for this spend, when the spender is
    /// still device-backed.
    pub fn paying_device_id(&self) -> Option<&str> {
        match self {
            Self::Device(d) => Some(d),
            Self::Account { .. } => None,
            Self::Share {
                issuer_device_id, ..
            } => Some(issuer_device_id),
        }
    }
}

/// Why a share-key bearer was rejected by the auth layer.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ShareKeyRejection {
    Expired,
    Revoked,
    Exhausted,
}

/// Share-key row resolved from a bearer at auth time.
#[derive(Debug, Clone)]
pub struct ResolvedShareKey {
    pub key_id: String,
    pub issuer_device_id: String,
    pub budget_credits: i64,
    pub consumed_credits: i64,
    pub expires_at: i64,
}

impl ResolvedShareKey {
    pub fn remaining(&self) -> i64 {
        (self.budget_credits - self.consumed_credits).max(0)
    }
}

/// Returned at mint time — the only moment the raw token is exposed.
#[derive(Debug, Clone, Serialize)]
pub struct ShareKeyMinted {
    #[serde(rename = "keyID")]
    pub key_id: String,
    #[serde(rename = "fundingID")]
    pub funding_id: String,
    pub token: String,
    pub label: Option<String>,
    #[serde(rename = "budgetCredits")]
    pub budget_credits: i64,
    #[serde(rename = "expiresAt")]
    pub expires_at: i64,
    #[serde(rename = "createdAt")]
    pub created_at: i64,
}

/// Issuer-visible view of a key; never includes the raw token.
#[derive(Debug, Clone, Serialize)]
pub struct ShareKeyPublic {
    #[serde(rename = "keyID")]
    pub key_id: String,
    #[serde(rename = "fundingID")]
    pub funding_id: String,
    pub label: Option<String>,
    #[serde(rename = "budgetCredits")]
    pub budget_credits: i64,
    #[serde(rename = "consumedCredits")]
    pub consumed_credits: i64,
    #[serde(rename = "remainingCredits")]
    pub remaining_credits: i64,
    #[serde(rename = "expiresAt")]
    pub expires_at: i64,
    #[serde(rename = "createdAt")]
    pub created_at: i64,
    #[serde(rename = "revokedAt", skip_serializing_if = "Option::is_none")]
    pub revoked_at: Option<i64>,
}

/// Returned when an account-scoped API key is created. The raw token is only
/// exposed once at mint time.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AccountApiKeyMinted {
    #[serde(rename = "keyID")]
    pub key_id: String,
    pub token: String,
    pub label: Option<String>,
    #[serde(rename = "createdAt")]
    pub created_at: i64,
}

/// Account-visible API key metadata; never includes the raw token after mint.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AccountApiKeyPublic {
    #[serde(rename = "keyID")]
    pub key_id: String,
    #[serde(rename = "tokenPreview")]
    pub token_preview: String,
    pub label: Option<String>,
    #[serde(rename = "createdAt")]
    pub created_at: i64,
    #[serde(rename = "lastUsedAt", skip_serializing_if = "Option::is_none")]
    pub last_used_at: Option<i64>,
    #[serde(rename = "revokedAt", skip_serializing_if = "Option::is_none")]
    pub revoked_at: Option<i64>,
}

#[derive(Debug, Clone)]
pub struct ResolvedAccountApiKey {
    pub key_id: String,
    pub account_user_id: String,
}

/// Payload served by the public preview endpoint; no auth required.
#[derive(Debug, Clone, Serialize)]
pub struct ShareKeyPreview {
    pub label: Option<String>,
    #[serde(rename = "budgetCredits")]
    pub budget_credits: i64,
    #[serde(rename = "consumedCredits")]
    pub consumed_credits: i64,
    #[serde(rename = "expiresAt")]
    pub expires_at: i64,
    #[serde(rename = "issuerDisplayName")]
    pub issuer_display_name: Option<String>,
}

/// Public discovery payload for a share key's non-secret funding identifier.
#[derive(Debug, Clone, Serialize)]
pub struct ShareKeyFundingPreview {
    #[serde(rename = "fundingID")]
    pub funding_id: String,
    pub label: Option<String>,
    #[serde(rename = "issuerDisplayName")]
    pub issuer_display_name: Option<String>,
    #[serde(rename = "budgetCredits")]
    pub budget_credits: i64,
    #[serde(rename = "consumedCredits")]
    pub consumed_credits: i64,
    #[serde(rename = "remainingCredits")]
    pub remaining_credits: i64,
    #[serde(rename = "expiresAt")]
    pub expires_at: i64,
}

#[derive(Debug, Clone, Serialize)]
pub struct ShareKeyFundingReceipt {
    #[serde(rename = "fundingID")]
    pub funding_id: String,
    #[serde(rename = "keyID")]
    pub key_id: String,
    #[serde(rename = "fundedCredits")]
    pub funded_credits: i64,
    #[serde(rename = "budgetCredits")]
    pub budget_credits: i64,
    #[serde(rename = "consumedCredits")]
    pub consumed_credits: i64,
    #[serde(rename = "remainingCredits")]
    pub remaining_credits: i64,
    #[serde(rename = "senderBalanceCredits")]
    pub sender_balance_credits: i64,
    #[serde(rename = "expiresAt")]
    pub expires_at: i64,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FundShareKeyError {
    NotFound,
    Revoked,
    Expired,
    NotMigrated,
    InsufficientBalance { balance: i64, required: i64 },
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize)]
pub struct ExpiredShareKeyRefundReport {
    #[serde(rename = "keysClosed")]
    pub keys_closed: usize,
    #[serde(rename = "contributionsRefunded")]
    pub contributions_refunded: usize,
    #[serde(rename = "creditsRefunded")]
    pub credits_refunded: i64,
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct ShareKeyContributionBackfillReport {
    pub keys_backfilled: usize,
    pub funding_ids_backfilled: usize,
    pub contributions_backfilled: usize,
}

#[derive(Debug, Clone, Serialize)]
pub struct BalanceSnapshot {
    #[serde(rename = "deviceID")]
    pub device_id: String,
    pub balance_credits: i64,
    pub total_earned_credits: i64,
    pub total_spent_credits: i64,
    pub usdc_cents: i64,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct AccountLinkMetadata {
    pub device_name: Option<String>,
    pub platform: Option<String>,
    pub display_name: Option<String>,
    pub phone: Option<String>,
    pub email: Option<String>,
    pub github_username: Option<String>,
}

#[derive(Debug, Clone)]
struct ActiveAvailabilitySession {
    device_id: String,
    model_id: Option<String>,
    started_at: i64,
    _last_accrued_at: i64,
    accrued_credits: i64,
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct AvailabilityReconcileReport {
    pub credited_devices: usize,
    pub finalized_sessions: usize,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AccountDeviceSnapshot {
    pub device_id: String,
    pub device_name: Option<String>,
    pub platform: Option<String>,
    pub linked_at: i64,
    pub last_seen: i64,
    pub wallet_balance_credits: i64,
    pub wallet_usdc_cents: i64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AccountLedgerEntry {
    pub id: i64,
    pub account_user_id: String,
    pub asset: String,
    pub amount: i64,
    #[serde(rename = "type")]
    pub type_: String,
    pub timestamp: i64,
    pub device_id: Option<String>,
    pub note: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AccountWalletSnapshot {
    pub account_user_id: String,
    pub balance_credits: i64,
    pub usdc_cents: i64,
    pub display_name: Option<String>,
    pub phone: Option<String>,
    pub email: Option<String>,
    pub github_username: Option<String>,
    pub devices: Vec<AccountDeviceSnapshot>,
    pub transactions: Vec<AccountLedgerEntry>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AccountSweepResult {
    pub swept_credits: i64,
    pub swept_usdc_cents: i64,
    pub account: AccountWalletSnapshot,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TransferRecipientSummary {
    pub kind: String,
    pub id: String,
    pub display_name: Option<String>,
    pub device_id: Option<String>,
    pub account_user_id: Option<String>,
    pub phone: Option<String>,
    pub email: Option<String>,
    pub github_username: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TransferReceipt {
    pub asset: String,
    pub amount: i64,
    pub memo: Option<String>,
    pub sender_kind: String,
    pub sender_id: String,
    pub sender_balance_credits: i64,
    pub recipient: TransferRecipientSummary,
}

#[derive(Debug, thiserror::Error)]
pub enum TransferError {
    #[error("asset must be 'credits'")]
    UnsupportedAsset,
    #[error("amount must be greater than zero")]
    InvalidAmount,
    #[error("recipient is required")]
    MissingRecipient,
    #[error("recipient account not found")]
    RecipientAccountNotFound,
    #[error("recipient device not found")]
    RecipientDeviceNotFound,
    #[error("recipient matched multiple accounts")]
    AmbiguousRecipient,
    #[error("cannot transfer to the same wallet")]
    SameWallet,
    #[error("requesting device is not linked to an account")]
    AccountNotLinked,
    #[error("insufficient credits: balance {balance}, need {required}")]
    InsufficientBalance { balance: i64, required: i64 },
    #[error(transparent)]
    Other(#[from] anyhow::Error),
}

impl From<rusqlite::Error> for TransferError {
    fn from(err: rusqlite::Error) -> Self {
        Self::Other(err.into())
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct NetworkLedgerTotals {
    pub total_credits_earned: i64,
    pub total_credits_spent: i64,
    pub total_usdc_distributed_cents: i64,
}

pub fn availability_credits_per_tick(prompt_price_usd: f64, completion_price_usd: f64) -> i64 {
    let combined_price = prompt_price_usd.max(0.0) + completion_price_usd.max(0.0);
    let hermes_reference =
        HERMES_REFERENCE_PROMPT_PRICE_USD + HERMES_REFERENCE_COMPLETION_PRICE_USD;

    if combined_price <= 0.0 {
        return 1;
    }

    ((combined_price / hermes_reference).round() as i64).max(1)
}

/// Credit cost in Teale credits for a completed chat turn, driven by the
/// per-token USD prices in `models.yaml`. Returned as an integer ≥1.
///
/// `prompt_price_usd` and `completion_price_usd` are USD *per single token*
/// (e.g. "0.00000010" from the catalog = $0.10/M tokens). Converting to
/// credits: 1 credit = $0.000001, so credits_per_token = usd_per_token * 1e6.
pub fn cost_credits(
    tokens_in: u64,
    tokens_out: u64,
    prompt_price_usd: f64,
    completion_price_usd: f64,
) -> i64 {
    let usd = tokens_in as f64 * prompt_price_usd.max(0.0)
        + tokens_out as f64 * completion_price_usd.max(0.0);
    let credits = (usd * 1_000_000.0).round() as i64;
    credits.max(1)
}

pub fn upsert_device(pool: &DbPool, device_id: &str) -> anyhow::Result<bool> {
    let mut conn = pool.lock();
    let now = unix_now();
    let tx = conn.transaction()?;
    let is_new: bool = {
        let existing: Option<i64> = tx
            .query_row(
                "SELECT first_seen FROM devices WHERE device_id = ?",
                [device_id],
                |r| r.get(0),
            )
            .ok();
        if existing.is_none() {
            tx.execute(
                "INSERT INTO devices (device_id, first_seen, last_seen) VALUES (?, ?, ?)",
                params![device_id, now, now],
            )?;
            tx.execute(
                "INSERT OR IGNORE INTO balances (device_id) VALUES (?)",
                [device_id],
            )?;
            true
        } else {
            tx.execute(
                "UPDATE devices SET last_seen = ? WHERE device_id = ?",
                params![now, device_id],
            )?;
            false
        }
    };
    tx.commit()?;
    Ok(is_new)
}

pub fn set_username(pool: &DbPool, device_id: &str, username: &str) -> anyhow::Result<()> {
    let conn = pool.lock();
    conn.execute(
        "UPDATE devices SET username = ? WHERE device_id = ?",
        params![username, device_id],
    )?;
    Ok(())
}

/// Issue a challenge nonce for device auth.
pub fn create_challenge(pool: &DbPool, device_id: &str, nonce: &str) -> anyhow::Result<i64> {
    let conn = pool.lock();
    let now = unix_now();
    let expires = now + CHALLENGE_TTL_SECONDS;
    conn.execute(
        "INSERT OR REPLACE INTO challenges (device_id, nonce, expires_at) VALUES (?, ?, ?)",
        params![device_id, nonce, expires],
    )?;
    Ok(expires)
}

/// Returns true + deletes the row if nonce matches and not expired.
pub fn consume_challenge(pool: &DbPool, device_id: &str, nonce: &str) -> anyhow::Result<bool> {
    let mut conn = pool.lock();
    let now = unix_now();
    let tx = conn.transaction()?;
    let expires: Option<i64> = tx
        .query_row(
            "SELECT expires_at FROM challenges WHERE device_id = ? AND nonce = ?",
            params![device_id, nonce],
            |r| r.get(0),
        )
        .ok();
    let ok = expires.map(|t| t > now).unwrap_or(false);
    if ok {
        tx.execute(
            "DELETE FROM challenges WHERE device_id = ? AND nonce = ?",
            params![device_id, nonce],
        )?;
    }
    tx.commit()?;
    Ok(ok)
}

pub fn issue_token(pool: &DbPool, device_id: &str, token: &str) -> anyhow::Result<i64> {
    let conn = pool.lock();
    let now = unix_now();
    let expires = now + TOKEN_TTL_SECONDS;
    conn.execute(
        "INSERT INTO tokens (token, device_id, expires_at) VALUES (?, ?, ?)",
        params![token, device_id, expires],
    )?;
    Ok(expires)
}

pub fn resolve_token(pool: &DbPool, token: &str) -> Option<String> {
    let conn = pool.lock();
    let now = unix_now();
    conn.query_row(
        "SELECT device_id FROM tokens WHERE token = ? AND expires_at > ?",
        params![token, now],
        |r| r.get::<_, String>(0),
    )
    .ok()
}

fn account_api_token_preview(token: &str) -> String {
    if token.len() <= 16 {
        return token.to_string();
    }
    format!("{}...{}", &token[..12], &token[token.len() - 4..])
}

pub fn mint_account_api_key(
    pool: &DbPool,
    account_user_id: &str,
    label: Option<&str>,
) -> anyhow::Result<AccountApiKeyMinted> {
    let mut conn = pool.lock();
    let now = unix_now();
    let tx = conn.transaction()?;

    tx.query_row(
        "SELECT account_user_id FROM account_wallets WHERE account_user_id = ?",
        [account_user_id],
        |_r| Ok(()),
    )?;

    let key_id = format!("ak_{}", uuid::Uuid::new_v4().simple());
    let token = format!("tok_acct_{}", uuid::Uuid::new_v4().simple());
    let cleaned_label = label
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(|value| value.chars().take(64).collect::<String>());

    tx.execute(
        "INSERT INTO account_api_keys
            (key_id, token, account_user_id, label, created_at)
         VALUES (?, ?, ?, ?, ?)",
        params![key_id, token, account_user_id, cleaned_label, now],
    )?;

    tx.commit()?;

    Ok(AccountApiKeyMinted {
        key_id,
        token,
        label: cleaned_label,
        created_at: now,
    })
}

pub fn list_account_api_keys(
    pool: &DbPool,
    account_user_id: &str,
) -> anyhow::Result<Vec<AccountApiKeyPublic>> {
    let conn = pool.lock();
    let mut stmt = conn.prepare(
        "SELECT key_id, token, label, created_at, last_used_at, revoked_at
         FROM account_api_keys
         WHERE account_user_id = ?
         ORDER BY created_at DESC, key_id DESC",
    )?;
    let rows = stmt.query_map([account_user_id], |r| {
        let token: String = r.get(1)?;
        Ok(AccountApiKeyPublic {
            key_id: r.get(0)?,
            token_preview: account_api_token_preview(&token),
            label: r.get(2)?,
            created_at: r.get(3)?,
            last_used_at: r.get(4)?,
            revoked_at: r.get(5)?,
        })
    })?;
    Ok(rows.filter_map(|row| row.ok()).collect())
}

pub fn revoke_account_api_key(
    pool: &DbPool,
    account_user_id: &str,
    key_id: &str,
) -> anyhow::Result<bool> {
    let conn = pool.lock();
    let now = unix_now();
    let changed = conn.execute(
        "UPDATE account_api_keys
         SET revoked_at = COALESCE(revoked_at, ?)
         WHERE key_id = ? AND account_user_id = ? AND revoked_at IS NULL",
        params![now, key_id, account_user_id],
    )?;
    Ok(changed > 0)
}

pub fn resolve_account_api_key(
    pool: &DbPool,
    token: &str,
) -> anyhow::Result<Option<ResolvedAccountApiKey>> {
    let mut conn = pool.lock();
    let now = unix_now();
    let tx = conn.transaction()?;
    let resolved = tx
        .query_row(
            "SELECT key_id, account_user_id
             FROM account_api_keys
             WHERE token = ? AND revoked_at IS NULL",
            [token],
            |r| {
                Ok(ResolvedAccountApiKey {
                    key_id: r.get(0)?,
                    account_user_id: r.get(1)?,
                })
            },
        )
        .ok();
    if let Some(resolved) = &resolved {
        tx.execute(
            "UPDATE account_api_keys SET last_used_at = ? WHERE key_id = ?",
            params![now, resolved.key_id],
        )?;
    }
    tx.commit()?;
    Ok(resolved)
}

/// Record a bonus and mint-pool debit atomically. Returns the balance after.
pub fn record_bonus(pool: &DbPool, device_id: &str, amount: i64) -> anyhow::Result<i64> {
    let mut conn = pool.lock();
    let now = unix_now();
    let tx = conn.transaction()?;

    // Debit mint pool (skip if would go negative — bonus still granted out of "reserves")
    tx.execute(
        "UPDATE mint_pool SET remaining = MAX(0, remaining - ?) WHERE id = 1",
        params![amount],
    )?;

    tx.execute(
        "INSERT INTO ledger (device_id, type, amount, timestamp, note)
         VALUES (?, 'BONUS', ?, ?, 'Welcome to Teale')",
        params![device_id, amount, now],
    )?;

    tx.execute(
        "UPDATE balances SET balance = balance + ?, total_earned = total_earned + ?
         WHERE device_id = ?",
        params![amount, amount, device_id],
    )?;

    let balance: i64 = tx.query_row(
        "SELECT balance FROM balances WHERE device_id = ?",
        [device_id],
        |r| r.get(0),
    )?;
    tx.commit()?;
    Ok(balance)
}

#[derive(Debug, Clone)]
struct ShareKeyContributionState {
    contribution_id: String,
    remaining_credits: i64,
    created_at: i64,
}

#[derive(Debug, Clone)]
struct ShareKeyFundingTarget {
    key_id: String,
    budget_credits: i64,
    consumed_credits: i64,
    expires_at: i64,
    revoked_at: Option<i64>,
    funded: i64,
}

fn new_share_key_funding_id() -> String {
    format!("skf_{}", uuid::Uuid::new_v4().simple())
}

fn new_share_key_contribution_id() -> String {
    format!("skc_{}", uuid::Uuid::new_v4().simple())
}

#[allow(clippy::too_many_arguments)]
fn insert_share_key_contribution_tx(
    tx: &rusqlite::Transaction<'_>,
    key_id: &str,
    funder_device_id: &str,
    funded_credits: i64,
    remaining_credits: i64,
    created_at: i64,
    refunded_at: Option<i64>,
    refund_reason: Option<&str>,
) -> anyhow::Result<()> {
    tx.execute(
        "INSERT INTO share_key_contributions
         (contribution_id, key_id, funder_device_id, funded_credits, remaining_credits,
          created_at, refunded_at, refund_reason)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
        params![
            new_share_key_contribution_id(),
            key_id,
            funder_device_id,
            funded_credits,
            remaining_credits.max(0),
            created_at,
            refunded_at,
            refund_reason,
        ],
    )?;
    Ok(())
}

type ShareKeyBackfillRow = (
    String,
    String,
    i64,
    i64,
    i64,
    Option<i64>,
    Option<String>,
    Option<i64>,
    i64,
);

type ShareKeyMigrationRow = (String, String, i64, i64, i64, Option<i64>, Option<String>);

type ShareKeyFundingPreviewRow = (Option<String>, i64, i64, i64, String, Option<i64>, i64);

fn sum_share_key_contributions_tx(
    tx: &rusqlite::Transaction<'_>,
    key_id: &str,
) -> anyhow::Result<i64> {
    Ok(tx.query_row(
        "SELECT COALESCE(SUM(remaining_credits), 0)
         FROM share_key_contributions WHERE key_id = ?",
        [key_id],
        |r| r.get(0),
    )?)
}

fn ensure_share_key_funding_id_tx(
    tx: &rusqlite::Transaction<'_>,
    key_id: &str,
    existing: Option<String>,
) -> anyhow::Result<String> {
    if let Some(id) = existing {
        return Ok(id);
    }
    let funding_id = new_share_key_funding_id();
    tx.execute(
        "UPDATE share_keys SET funding_id = ? WHERE key_id = ?",
        params![funding_id, key_id],
    )?;
    Ok(funding_id)
}

fn refund_share_key_contributions_tx(
    tx: &rusqlite::Transaction<'_>,
    key_id: &str,
    settled_at: i64,
    reason: &str,
) -> anyhow::Result<(usize, i64)> {
    let rows: Vec<(String, String, i64)> = {
        let mut stmt = tx.prepare(
            "SELECT contribution_id, funder_device_id, remaining_credits
             FROM share_key_contributions
             WHERE key_id = ? AND refunded_at IS NULL
             ORDER BY created_at ASC, contribution_id ASC",
        )?;
        let rows = stmt
            .query_map([key_id], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)))?
            .collect::<Result<Vec<_>, _>>()?;
        rows
    };

    let mut refunded_rows = 0usize;
    let mut refunded_credits = 0i64;
    for (contribution_id, funder_device_id, remaining_credits) in rows {
        tx.execute(
            "INSERT OR IGNORE INTO balances (device_id) VALUES (?)",
            [&funder_device_id],
        )?;
        if remaining_credits > 0 {
            tx.execute(
                "UPDATE balances SET balance = balance + ? WHERE device_id = ?",
                params![remaining_credits, &funder_device_id],
            )?;
            tx.execute(
                "INSERT INTO ledger (device_id, type, amount, timestamp, note)
                 VALUES (?, ?, ?, ?, ?)",
                params![
                    &funder_device_id,
                    LedgerType::ShareKeyRefund.as_str(),
                    remaining_credits,
                    settled_at,
                    format!("share_key:{} refunded ({})", key_id, reason),
                ],
            )?;
            refunded_rows += 1;
            refunded_credits += remaining_credits;
        }
        tx.execute(
            "UPDATE share_key_contributions
             SET remaining_credits = 0, refunded_at = ?, refund_reason = ?
             WHERE contribution_id = ?",
            params![settled_at, reason, contribution_id],
        )?;
    }

    Ok((refunded_rows, refunded_credits))
}

fn apply_pro_rata_share_key_spend_tx(
    tx: &rusqlite::Transaction<'_>,
    key_id: &str,
    spend: i64,
) -> anyhow::Result<()> {
    if spend <= 0 {
        return Ok(());
    }

    let contributions: Vec<ShareKeyContributionState> = {
        let mut stmt = tx.prepare(
            "SELECT contribution_id, funder_device_id, remaining_credits, created_at
             FROM share_key_contributions
             WHERE key_id = ? AND remaining_credits > 0
             ORDER BY created_at ASC, contribution_id ASC",
        )?;
        let rows = stmt
            .query_map([key_id], |r| {
                Ok(ShareKeyContributionState {
                    contribution_id: r.get(0)?,
                    remaining_credits: r.get(2)?,
                    created_at: r.get(3)?,
                })
            })?
            .collect::<Result<Vec<_>, _>>()?;
        rows
    };
    if contributions.is_empty() {
        return Ok(());
    }

    let total_remaining: i64 = contributions.iter().map(|c| c.remaining_credits).sum();
    if total_remaining <= 0 {
        return Ok(());
    }
    let spend = spend.min(total_remaining);

    let mut reductions: Vec<(String, i64, i64, i64)> = Vec::with_capacity(contributions.len());
    let mut floored_total = 0i64;
    for c in &contributions {
        let numerator = (spend as i128) * (c.remaining_credits as i128);
        let base = (numerator / total_remaining as i128) as i64;
        let remainder = (numerator % total_remaining as i128) as i64;
        floored_total += base;
        reductions.push((c.contribution_id.clone(), base, remainder, c.created_at));
    }

    let mut leftover = spend - floored_total;
    if leftover > 0 {
        let mut order: Vec<(usize, i64, i64, String)> = reductions
            .iter()
            .enumerate()
            .map(|(idx, (id, _, remainder, created_at))| (idx, *remainder, *created_at, id.clone()))
            .collect();
        order.sort_by(|a, b| match b.1.cmp(&a.1) {
            Ordering::Equal => match a.2.cmp(&b.2) {
                Ordering::Equal => a.3.cmp(&b.3),
                other => other,
            },
            other => other,
        });
        for (idx, _, _, _) in order {
            if leftover == 0 {
                break;
            }
            reductions[idx].1 += 1;
            leftover -= 1;
        }
    }

    for (c, (_, reduction, _, _)) in contributions.iter().zip(reductions.iter()) {
        let new_remaining = (c.remaining_credits - *reduction).max(0);
        tx.execute(
            "UPDATE share_key_contributions SET remaining_credits = ? WHERE contribution_id = ?",
            params![new_remaining, &c.contribution_id],
        )?;
    }

    Ok(())
}

pub fn backfill_funded_share_key_contributions(
    pool: &DbPool,
) -> anyhow::Result<ShareKeyContributionBackfillReport> {
    let mut conn = pool.lock();
    let now = unix_now();
    let tx = conn.transaction()?;

    let rows: Vec<ShareKeyBackfillRow> = {
        let mut stmt = tx.prepare(
            "SELECT sk.key_id, sk.issuer_device_id, sk.budget_credits, sk.consumed_credits,
                    sk.expires_at, sk.revoked_at, sk.funding_id, sk.refunds_settled_at,
                    (SELECT COUNT(*) FROM share_key_contributions skc WHERE skc.key_id = sk.key_id)
             FROM share_keys sk
             WHERE sk.funded = 1",
        )?;
        let rows = stmt
            .query_map([], |r| {
                Ok((
                    r.get(0)?,
                    r.get(1)?,
                    r.get(2)?,
                    r.get(3)?,
                    r.get(4)?,
                    r.get(5)?,
                    r.get(6)?,
                    r.get(7)?,
                    r.get(8)?,
                ))
            })?
            .collect::<Result<Vec<_>, _>>()?;
        rows
    };

    let mut report = ShareKeyContributionBackfillReport::default();
    for (
        key_id,
        issuer,
        budget,
        consumed,
        expires_at,
        revoked_at,
        funding_id,
        refunds_settled_at,
        contribution_count,
    ) in rows
    {
        if funding_id.is_none() {
            ensure_share_key_funding_id_tx(&tx, &key_id, None)?;
            report.funding_ids_backfilled += 1;
        }
        if contribution_count > 0 {
            continue;
        }

        let remaining = (budget - consumed).max(0);
        if let Some(revoked_at) = revoked_at {
            insert_share_key_contribution_tx(
                &tx,
                &key_id,
                &issuer,
                budget.max(1),
                0,
                revoked_at,
                Some(refunds_settled_at.unwrap_or(revoked_at)),
                Some("legacy_revoked"),
            )?;
        } else if expires_at <= now && refunds_settled_at.is_some() {
            insert_share_key_contribution_tx(
                &tx,
                &key_id,
                &issuer,
                budget.max(1),
                0,
                expires_at,
                refunds_settled_at,
                Some("legacy_expired_refunded"),
            )?;
        } else {
            insert_share_key_contribution_tx(
                &tx,
                &key_id,
                &issuer,
                budget.max(1),
                remaining,
                now,
                None,
                None,
            )?;
        }
        report.keys_backfilled += 1;
        report.contributions_backfilled += 1;
    }

    tx.commit()?;
    Ok(report)
}

pub fn transfer_to_share_key(
    pool: &DbPool,
    sender_device_id: &str,
    funding_id: &str,
    amount_credits: i64,
) -> Result<ShareKeyFundingReceipt, FundShareKeyError> {
    if amount_credits <= 0 {
        return Err(FundShareKeyError::InsufficientBalance {
            balance: 0,
            required: amount_credits.max(1),
        });
    }

    let mut conn = pool.lock();
    let now = unix_now();
    let tx = conn
        .transaction()
        .map_err(|_| FundShareKeyError::NotFound)?;

    let target: Option<ShareKeyFundingTarget> = tx
        .query_row(
            "SELECT key_id, issuer_device_id, budget_credits, consumed_credits, expires_at,
                    revoked_at, funded
             FROM share_keys WHERE funding_id = ?",
            [funding_id],
            |r| {
                Ok(ShareKeyFundingTarget {
                    key_id: r.get(0)?,
                    budget_credits: r.get(2)?,
                    consumed_credits: r.get(3)?,
                    expires_at: r.get(4)?,
                    revoked_at: r.get(5)?,
                    funded: r.get(6)?,
                })
            },
        )
        .ok();
    let target = target.ok_or(FundShareKeyError::NotFound)?;
    if target.revoked_at.is_some() {
        return Err(FundShareKeyError::Revoked);
    }
    if target.expires_at <= now {
        return Err(FundShareKeyError::Expired);
    }
    if target.funded != 1 {
        return Err(FundShareKeyError::NotMigrated);
    }

    tx.execute(
        "INSERT OR IGNORE INTO devices (device_id, first_seen, last_seen) VALUES (?, ?, ?)",
        params![sender_device_id, now, now],
    )
    .map_err(|_| FundShareKeyError::NotFound)?;
    tx.execute(
        "INSERT OR IGNORE INTO balances (device_id) VALUES (?)",
        [sender_device_id],
    )
    .map_err(|_| FundShareKeyError::NotFound)?;
    let sender_balance: i64 = tx
        .query_row(
            "SELECT balance FROM balances WHERE device_id = ?",
            [sender_device_id],
            |r| r.get(0),
        )
        .unwrap_or(0);
    if sender_balance < amount_credits {
        return Err(FundShareKeyError::InsufficientBalance {
            balance: sender_balance,
            required: amount_credits,
        });
    }

    tx.execute(
        "UPDATE balances SET balance = balance - ? WHERE device_id = ?",
        params![amount_credits, sender_device_id],
    )
    .map_err(|_| FundShareKeyError::NotFound)?;
    tx.execute(
        "UPDATE share_keys SET budget_credits = budget_credits + ? WHERE key_id = ?",
        params![amount_credits, &target.key_id],
    )
    .map_err(|_| FundShareKeyError::NotFound)?;
    insert_share_key_contribution_tx(
        &tx,
        &target.key_id,
        sender_device_id,
        amount_credits,
        amount_credits,
        now,
        None,
        None,
    )
    .map_err(|_| FundShareKeyError::NotFound)?;
    tx.execute(
        "INSERT INTO ledger (device_id, type, amount, timestamp, note)
         VALUES (?, ?, ?, ?, ?)",
        params![
            sender_device_id,
            LedgerType::ShareKeyFund.as_str(),
            -amount_credits,
            now,
            format!("share_key:{} funded", &target.key_id),
        ],
    )
    .map_err(|_| FundShareKeyError::NotFound)?;

    let new_sender_balance = sender_balance - amount_credits;
    let new_budget = target.budget_credits + amount_credits;
    let remaining = sum_share_key_contributions_tx(&tx, &target.key_id)
        .map_err(|_| FundShareKeyError::NotFound)?;
    tx.commit().map_err(|_| FundShareKeyError::NotFound)?;

    Ok(ShareKeyFundingReceipt {
        funding_id: funding_id.to_string(),
        key_id: target.key_id,
        funded_credits: amount_credits,
        budget_credits: new_budget,
        consumed_credits: target.consumed_credits,
        remaining_credits: remaining,
        sender_balance_credits: new_sender_balance,
        expires_at: target.expires_at,
    })
}

pub fn refund_expired_share_keys(pool: &DbPool) -> anyhow::Result<ExpiredShareKeyRefundReport> {
    let mut conn = pool.lock();
    let now = unix_now();
    let tx = conn.transaction()?;

    let keys: Vec<String> = {
        let mut stmt = tx.prepare(
            "SELECT key_id FROM share_keys
             WHERE funded = 1
               AND revoked_at IS NULL
               AND expires_at <= ?
               AND refunds_settled_at IS NULL",
        )?;
        let keys = stmt
            .query_map([now], |r| r.get::<_, String>(0))?
            .collect::<Result<Vec<_>, _>>()?;
        keys
    };

    let mut report = ExpiredShareKeyRefundReport::default();
    for key_id in keys {
        let (rows, credits) = refund_share_key_contributions_tx(&tx, &key_id, now, "expired")?;
        tx.execute(
            "UPDATE share_keys SET refunds_settled_at = ? WHERE key_id = ?",
            params![now, &key_id],
        )?;
        report.keys_closed += 1;
        report.contributions_refunded += rows;
        report.credits_refunded += credits;
    }

    tx.commit()?;
    Ok(report)
}

/// Admin-initiated mint: credit a device wallet with `amount` credits, debit
/// the mint pool (clamping at zero so we never go negative), and record an
/// ADMIN_MINT ledger entry. Used by the admin top-up endpoint.
///
/// Like `record_bonus`, counts toward the recipient's `total_earned` so the
/// wallet history shows the top-up as an earn (distinguishable by ledger type
/// from a welcome bonus).
pub fn admin_mint(pool: &DbPool, device_id: &str, amount: i64, note: &str) -> anyhow::Result<i64> {
    if amount <= 0 {
        anyhow::bail!("amount must be > 0");
    }
    let mut conn = pool.lock();
    let now = unix_now();
    let tx = conn.transaction()?;

    // Ensure device exists so the FK on any downstream ledger rows is valid.
    tx.execute(
        "INSERT OR IGNORE INTO devices (device_id, first_seen, last_seen) VALUES (?, ?, ?)",
        params![device_id, now, now],
    )?;
    tx.execute(
        "INSERT OR IGNORE INTO balances (device_id) VALUES (?)",
        [device_id],
    )?;

    tx.execute(
        "UPDATE mint_pool SET remaining = MAX(0, remaining - ?) WHERE id = 1",
        params![amount],
    )?;
    tx.execute(
        "INSERT INTO ledger (device_id, type, amount, timestamp, note)
         VALUES (?, ?, ?, ?, ?)",
        params![device_id, LedgerType::AdminMint.as_str(), amount, now, note,],
    )?;
    tx.execute(
        "UPDATE balances SET balance = balance + ?, total_earned = total_earned + ?
         WHERE device_id = ?",
        params![amount, amount, device_id],
    )?;
    let balance: i64 = tx.query_row(
        "SELECT balance FROM balances WHERE device_id = ?",
        [device_id],
        |r| r.get(0),
    )?;
    tx.commit()?;
    Ok(balance)
}

pub fn get_balance(pool: &DbPool, device_id: &str) -> BalanceSnapshot {
    let conn = pool.lock();
    let (balance, earned, spent): (i64, i64, i64) = conn
        .query_row(
            "SELECT balance, total_earned, total_spent FROM balances WHERE device_id = ?",
            [device_id],
            |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)),
        )
        .unwrap_or((0, 0, 0));
    BalanceSnapshot {
        device_id: device_id.to_string(),
        balance_credits: balance,
        total_earned_credits: earned,
        total_spent_credits: spent,
        usdc_cents: 0,
    }
}

pub fn list_transactions(pool: &DbPool, device_id: &str, limit: i64) -> Vec<LedgerEntry> {
    list_transactions_with_options(pool, device_id, limit, true)
}

pub fn list_transactions_without_availability(
    pool: &DbPool,
    device_id: &str,
    limit: i64,
) -> Vec<LedgerEntry> {
    list_transactions_with_options(pool, device_id, limit, false)
}

fn list_transactions_with_options(
    pool: &DbPool,
    device_id: &str,
    limit: i64,
    include_availability: bool,
) -> Vec<LedgerEntry> {
    let conn = pool.lock();
    let sql = if include_availability {
        "SELECT id, device_id, type, amount, timestamp, ref_request_id, note
         FROM ledger WHERE device_id = ? ORDER BY timestamp DESC LIMIT ?"
    } else {
        "SELECT id, device_id, type, amount, timestamp, ref_request_id, note
         FROM ledger WHERE device_id = ? AND type != 'AVAILABILITY_DRIP'
         ORDER BY timestamp DESC LIMIT ?"
    };
    let mut stmt = match conn.prepare(sql) {
        Ok(s) => s,
        Err(_) => return vec![],
    };
    stmt.query_map(params![device_id, limit], |r| {
        Ok(LedgerEntry {
            id: r.get(0)?,
            device_id: r.get(1)?,
            type_: r.get(2)?,
            amount: r.get(3)?,
            timestamp: r.get(4)?,
            ref_request_id: r.get(5)?,
            note: r.get(6)?,
        })
    })
    .ok()
    .map(|iter| iter.filter_map(|r| r.ok()).collect())
    .unwrap_or_default()
}

pub fn network_ledger_totals(pool: &DbPool) -> anyhow::Result<NetworkLedgerTotals> {
    let conn = pool.lock();
    let (total_credits_earned, total_credits_spent): (i64, i64) = conn.query_row(
        "SELECT COALESCE(SUM(total_earned), 0), COALESCE(SUM(total_spent), 0) FROM balances",
        [],
        |r| Ok((r.get(0)?, r.get(1)?)),
    )?;
    let total_usdc_distributed_cents: i64 = conn.query_row(
        "SELECT COALESCE(SUM(usdc_cents), 0) FROM account_wallets",
        [],
        |r| r.get(0),
    )?;

    Ok(NetworkLedgerTotals {
        total_credits_earned,
        total_credits_spent,
        total_usdc_distributed_cents,
    })
}

#[derive(Debug, Clone)]
enum ResolvedTransferTarget {
    Device {
        device_id: String,
    },
    Account {
        account_user_id: String,
        display_name: Option<String>,
        phone: Option<String>,
        email: Option<String>,
        github_username: Option<String>,
    },
}

impl ResolvedTransferTarget {
    fn summary(&self) -> TransferRecipientSummary {
        match self {
            Self::Device { device_id } => TransferRecipientSummary {
                kind: "device".to_string(),
                id: device_id.clone(),
                display_name: None,
                device_id: Some(device_id.clone()),
                account_user_id: None,
                phone: None,
                email: None,
                github_username: None,
            },
            Self::Account {
                account_user_id,
                display_name,
                phone,
                email,
                github_username,
            } => TransferRecipientSummary {
                kind: "account".to_string(),
                id: account_user_id.clone(),
                display_name: display_name.clone(),
                device_id: None,
                account_user_id: Some(account_user_id.clone()),
                phone: phone.clone(),
                email: email.clone(),
                github_username: github_username.clone(),
            },
        }
    }
}

#[derive(Debug, Clone)]
enum TransferLookup {
    Device(String),
    Account(String),
    Email(String),
    PhoneDigits(String),
    Github(String),
}

fn looks_like_device_id(value: &str) -> bool {
    value.len() == 64 && value.chars().all(|c| c.is_ascii_hexdigit())
}

fn normalize_email(value: &str) -> Option<String> {
    let trimmed = value.trim().to_lowercase();
    (!trimmed.is_empty()).then_some(trimmed)
}

fn normalize_github_username(value: &str) -> Option<String> {
    let trimmed = value.trim().trim_start_matches('@').to_lowercase();
    (!trimmed.is_empty()).then_some(trimmed)
}

fn normalize_phone_value(value: &str) -> Option<String> {
    let trimmed = value.trim();
    if trimmed.is_empty() {
        return None;
    }
    let digits: String = trimmed.chars().filter(|c| c.is_ascii_digit()).collect();
    if digits.is_empty() {
        return None;
    }
    if trimmed.starts_with('+') {
        Some(format!("+{digits}"))
    } else {
        Some(digits)
    }
}

fn normalize_phone_digits(value: &str) -> Option<String> {
    let digits: String = value.chars().filter(|c| c.is_ascii_digit()).collect();
    (!digits.is_empty()).then_some(digits)
}

fn parse_transfer_lookup(raw: &str) -> Result<TransferLookup, TransferError> {
    let trimmed = raw.trim();
    if trimmed.is_empty() {
        return Err(TransferError::MissingRecipient);
    }

    if let Some(rest) = trimmed.strip_prefix("device:") {
        return Ok(TransferLookup::Device(rest.trim().to_string()));
    }
    if let Some(rest) = trimmed.strip_prefix("account:") {
        return Ok(TransferLookup::Account(rest.trim().to_string()));
    }
    if let Some(rest) = trimmed.strip_prefix("email:") {
        let email = normalize_email(rest).ok_or(TransferError::MissingRecipient)?;
        return Ok(TransferLookup::Email(email));
    }
    if let Some(rest) = trimmed.strip_prefix("phone:") {
        let digits = normalize_phone_digits(rest).ok_or(TransferError::MissingRecipient)?;
        return Ok(TransferLookup::PhoneDigits(digits));
    }
    if let Some(rest) = trimmed.strip_prefix("github:") {
        let github = normalize_github_username(rest).ok_or(TransferError::MissingRecipient)?;
        return Ok(TransferLookup::Github(github));
    }

    if looks_like_device_id(trimmed) {
        return Ok(TransferLookup::Device(trimmed.to_string()));
    }
    if trimmed.contains('@') {
        let email = normalize_email(trimmed).ok_or(TransferError::MissingRecipient)?;
        return Ok(TransferLookup::Email(email));
    }
    if let Some(digits) = normalize_phone_digits(trimmed) {
        if trimmed.starts_with('+')
            || trimmed
                .chars()
                .any(|c| matches!(c, '(' | ')' | ' ' | '-' | '.'))
        {
            return Ok(TransferLookup::PhoneDigits(digits));
        }
    }

    let github = normalize_github_username(trimmed).ok_or(TransferError::MissingRecipient)?;
    Ok(TransferLookup::Github(github))
}

fn load_account_target_from_query<P: rusqlite::Params>(
    tx: &rusqlite::Transaction<'_>,
    sql: &str,
    params: P,
) -> Result<ResolvedTransferTarget, TransferError> {
    let mut stmt = tx.prepare(sql)?;
    let rows = stmt.query_map(params, |r| {
        Ok(ResolvedTransferTarget::Account {
            account_user_id: r.get(0)?,
            display_name: r.get(1)?,
            phone: r.get(2)?,
            email: r.get(3)?,
            github_username: r.get(4)?,
        })
    })?;
    let results: Vec<ResolvedTransferTarget> = rows.filter_map(|row| row.ok()).take(2).collect();
    match results.len() {
        0 => Err(TransferError::RecipientAccountNotFound),
        1 => Ok(results.into_iter().next().expect("one result")),
        _ => Err(TransferError::AmbiguousRecipient),
    }
}

fn resolve_transfer_target_tx(
    tx: &rusqlite::Transaction<'_>,
    raw_recipient: &str,
) -> Result<ResolvedTransferTarget, TransferError> {
    let trimmed = raw_recipient.trim();
    if !trimmed.is_empty()
        && !trimmed.contains('@')
        && !trimmed.starts_with('+')
        && !trimmed.contains(':')
    {
        if let Ok(device_id) = tx.query_row(
            "SELECT device_id FROM devices WHERE device_id = ?",
            [trimmed],
            |r| r.get::<_, String>(0),
        ) {
            return Ok(ResolvedTransferTarget::Device { device_id });
        }
        if let Ok(account_user_id) = tx.query_row(
            "SELECT account_user_id FROM account_wallets WHERE account_user_id = ?",
            [trimmed],
            |r| r.get::<_, String>(0),
        ) {
            return tx
                .query_row(
                    "SELECT account_user_id, display_name, phone, email, github_username
                     FROM account_wallets
                     WHERE account_user_id = ?",
                    [account_user_id],
                    |r| {
                        Ok(ResolvedTransferTarget::Account {
                            account_user_id: r.get(0)?,
                            display_name: r.get(1)?,
                            phone: r.get(2)?,
                            email: r.get(3)?,
                            github_username: r.get(4)?,
                        })
                    },
                )
                .map_err(|_| TransferError::RecipientAccountNotFound);
        }
    }

    match parse_transfer_lookup(raw_recipient)? {
        TransferLookup::Device(device_id) => tx
            .query_row(
                "SELECT device_id FROM devices WHERE device_id = ?",
                [device_id.clone()],
                |r| r.get::<_, String>(0),
            )
            .map(|device_id| ResolvedTransferTarget::Device { device_id })
            .map_err(|_| TransferError::RecipientDeviceNotFound),
        TransferLookup::Account(account_user_id) => tx
            .query_row(
                "SELECT account_user_id, display_name, phone, email, github_username
                 FROM account_wallets
                 WHERE account_user_id = ?",
                [account_user_id],
                |r| {
                    Ok(ResolvedTransferTarget::Account {
                        account_user_id: r.get(0)?,
                        display_name: r.get(1)?,
                        phone: r.get(2)?,
                        email: r.get(3)?,
                        github_username: r.get(4)?,
                    })
                },
            )
            .map_err(|_| TransferError::RecipientAccountNotFound),
        TransferLookup::Email(email) => load_account_target_from_query(
            tx,
            "SELECT account_user_id, display_name, phone, email, github_username
             FROM account_wallets
             WHERE LOWER(email) = ?",
            [email],
        ),
        TransferLookup::PhoneDigits(phone_digits) => load_account_target_from_query(
            tx,
            "SELECT account_user_id, display_name, phone, email, github_username
             FROM account_wallets
             WHERE REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(COALESCE(phone, ''), '+', ''), ' ', ''), '-', ''), '(', ''), ')', ''), '.', '') = ?",
            [phone_digits],
        ),
        TransferLookup::Github(username) => load_account_target_from_query(
            tx,
            "SELECT account_user_id, display_name, phone, email, github_username
             FROM account_wallets
             WHERE LOWER(github_username) = ?",
            [username],
        ),
    }
}

fn format_sender_note(recipient: &ResolvedTransferTarget, memo: Option<&str>) -> String {
    let target = match recipient {
        ResolvedTransferTarget::Device { device_id } => format!("device {device_id}"),
        ResolvedTransferTarget::Account {
            account_user_id,
            phone,
            email,
            github_username,
            ..
        } => phone
            .clone()
            .or_else(|| email.clone())
            .or_else(|| github_username.clone())
            .unwrap_or_else(|| format!("account {account_user_id}")),
    };
    match memo.and_then(|value| {
        let trimmed = value.trim();
        (!trimmed.is_empty()).then_some(trimmed)
    }) {
        Some(memo) => format!("transfer to {target}: {memo}"),
        None => format!("transfer to {target}"),
    }
}

fn format_recipient_note(sender_label: &str, memo: Option<&str>) -> String {
    match memo.and_then(|value| {
        let trimmed = value.trim();
        (!trimmed.is_empty()).then_some(trimmed)
    }) {
        Some(memo) => format!("transfer from {sender_label}: {memo}"),
        None => format!("transfer from {sender_label}"),
    }
}

pub fn link_device_to_account(
    pool: &DbPool,
    device_id: &str,
    account_user_id: &str,
    metadata: &AccountLinkMetadata,
) -> anyhow::Result<()> {
    let mut conn = pool.lock();
    let now = unix_now();
    let tx = conn.transaction()?;
    let normalized_phone = metadata.phone.as_deref().and_then(normalize_phone_value);
    let normalized_email = metadata.email.as_deref().and_then(normalize_email);
    let normalized_github = metadata
        .github_username
        .as_deref()
        .and_then(normalize_github_username);
    tx.execute(
        "INSERT OR IGNORE INTO devices (device_id, first_seen, last_seen) VALUES (?, ?, ?)",
        params![device_id, now, now],
    )?;
    tx.execute(
        "INSERT OR IGNORE INTO balances (device_id) VALUES (?)",
        [device_id],
    )?;
    tx.execute(
        "INSERT INTO account_wallets
            (account_user_id, display_name, phone, email, github_username,
             balance_credits, usdc_cents, created_at, updated_at)
         VALUES (?, ?, ?, ?, ?, 0, 0, ?, ?)
         ON CONFLICT(account_user_id) DO UPDATE SET
            display_name = COALESCE(excluded.display_name, account_wallets.display_name),
            phone = COALESCE(excluded.phone, account_wallets.phone),
            email = COALESCE(excluded.email, account_wallets.email),
            github_username = COALESCE(excluded.github_username, account_wallets.github_username),
            updated_at = excluded.updated_at",
        params![
            account_user_id,
            metadata.display_name.as_deref(),
            normalized_phone.as_deref(),
            normalized_email.as_deref(),
            normalized_github.as_deref(),
            now,
            now,
        ],
    )?;
    tx.execute(
        "UPDATE devices SET last_seen = ? WHERE device_id = ?",
        params![now, device_id],
    )?;
    tx.execute(
        "INSERT INTO account_devices
            (device_id, account_user_id, device_name, platform, linked_at, last_seen)
         VALUES (?, ?, ?, ?, ?, ?)
         ON CONFLICT(device_id) DO UPDATE SET
            account_user_id = excluded.account_user_id,
            device_name = COALESCE(excluded.device_name, account_devices.device_name),
            platform = COALESCE(excluded.platform, account_devices.platform),
            linked_at = excluded.linked_at,
            last_seen = excluded.last_seen",
        params![
            device_id,
            account_user_id,
            metadata.device_name.as_deref(),
            metadata.platform.as_deref(),
            now,
            now,
        ],
    )?;
    tx.commit()?;
    Ok(())
}

pub fn transfer_from_device_wallet(
    pool: &DbPool,
    sender_device_id: &str,
    raw_recipient: &str,
    amount_credits: i64,
    memo: Option<&str>,
) -> Result<TransferReceipt, TransferError> {
    if amount_credits <= 0 {
        return Err(TransferError::InvalidAmount);
    }

    let mut conn = pool.lock();
    let now = unix_now();
    let tx = conn.transaction()?;

    tx.execute(
        "INSERT OR IGNORE INTO balances (device_id) VALUES (?)",
        [sender_device_id],
    )?;
    let sender_balance: i64 = tx
        .query_row(
            "SELECT balance FROM balances WHERE device_id = ?",
            [sender_device_id],
            |r| r.get(0),
        )
        .unwrap_or(0);
    if sender_balance < amount_credits {
        return Err(TransferError::InsufficientBalance {
            balance: sender_balance,
            required: amount_credits,
        });
    }

    let recipient = resolve_transfer_target_tx(&tx, raw_recipient)?;
    if matches!(
        &recipient,
        ResolvedTransferTarget::Device { device_id } if device_id == sender_device_id
    ) {
        return Err(TransferError::SameWallet);
    }

    tx.execute(
        "UPDATE balances SET balance = balance - ? WHERE device_id = ?",
        params![amount_credits, sender_device_id],
    )?;
    tx.execute(
        "INSERT INTO ledger (device_id, type, amount, timestamp, note)
         VALUES (?, 'TRANSFER_OUT', ?, ?, ?)",
        params![
            sender_device_id,
            -amount_credits,
            now,
            format_sender_note(&recipient, memo),
        ],
    )?;

    match &recipient {
        ResolvedTransferTarget::Device { device_id } => {
            tx.execute(
                "INSERT OR IGNORE INTO balances (device_id) VALUES (?)",
                [device_id],
            )?;
            tx.execute(
                "UPDATE balances SET balance = balance + ? WHERE device_id = ?",
                params![amount_credits, device_id],
            )?;
            tx.execute(
                "INSERT INTO ledger (device_id, type, amount, timestamp, note)
                 VALUES (?, 'TRANSFER_IN', ?, ?, ?)",
                params![
                    device_id,
                    amount_credits,
                    now,
                    format_recipient_note(sender_device_id, memo),
                ],
            )?;
        }
        ResolvedTransferTarget::Account {
            account_user_id, ..
        } => {
            tx.execute(
                "UPDATE account_wallets
                 SET balance_credits = balance_credits + ?, updated_at = ?
                 WHERE account_user_id = ?",
                params![amount_credits, now, account_user_id],
            )?;
            tx.execute(
                "INSERT INTO account_ledger
                    (account_user_id, asset, amount, type, timestamp, device_id, note)
                 VALUES (?, 'credits', ?, 'TRANSFER_IN', ?, ?, ?)",
                params![
                    account_user_id,
                    amount_credits,
                    now,
                    sender_device_id,
                    format_recipient_note(sender_device_id, memo),
                ],
            )?;
        }
    }

    tx.commit()?;

    Ok(TransferReceipt {
        asset: "credits".to_string(),
        amount: amount_credits,
        memo: memo.and_then(|value| {
            let trimmed = value.trim();
            (!trimmed.is_empty()).then_some(trimmed.to_string())
        }),
        sender_kind: "device".to_string(),
        sender_id: sender_device_id.to_string(),
        sender_balance_credits: sender_balance - amount_credits,
        recipient: recipient.summary(),
    })
}

pub fn transfer_from_account_wallet(
    pool: &DbPool,
    requester_device_id: &str,
    raw_recipient: &str,
    amount_credits: i64,
    memo: Option<&str>,
) -> Result<TransferReceipt, TransferError> {
    let account_user_id = account_user_id_for_device(pool, requester_device_id)
        .ok_or(TransferError::AccountNotLinked)?;
    transfer_from_account_wallet_for_account(
        pool,
        &account_user_id,
        raw_recipient,
        amount_credits,
        memo,
        Some(requester_device_id),
    )
}

pub fn account_user_id_for_device(pool: &DbPool, device_id: &str) -> Option<String> {
    let conn = pool.lock();
    conn.query_row(
        "SELECT account_user_id FROM account_devices WHERE device_id = ?",
        [device_id],
        |r| r.get(0),
    )
    .ok()
}

pub fn account_balance_credits(pool: &DbPool, account_user_id: &str) -> i64 {
    let conn = pool.lock();
    conn.query_row(
        "SELECT balance_credits FROM account_wallets WHERE account_user_id = ?",
        [account_user_id],
        |r| r.get(0),
    )
    .unwrap_or(0)
}

pub fn transfer_from_account_wallet_for_account(
    pool: &DbPool,
    account_user_id: &str,
    raw_recipient: &str,
    amount_credits: i64,
    memo: Option<&str>,
    actor_device_id: Option<&str>,
) -> Result<TransferReceipt, TransferError> {
    if amount_credits <= 0 {
        return Err(TransferError::InvalidAmount);
    }

    let mut conn = pool.lock();
    let now = unix_now();
    let tx = conn.transaction()?;

    tx.query_row(
        "SELECT account_user_id FROM account_wallets WHERE account_user_id = ?",
        [account_user_id],
        |_r| Ok(()),
    )
    .map_err(|_| TransferError::AccountNotLinked)?;

    let sender_balance: i64 = tx
        .query_row(
            "SELECT balance_credits FROM account_wallets WHERE account_user_id = ?",
            [account_user_id],
            |r| r.get(0),
        )
        .unwrap_or(0);
    if sender_balance < amount_credits {
        return Err(TransferError::InsufficientBalance {
            balance: sender_balance,
            required: amount_credits,
        });
    }

    let recipient = resolve_transfer_target_tx(&tx, raw_recipient)?;
    if matches!(
        &recipient,
        ResolvedTransferTarget::Account {
            account_user_id: recipient_account_id,
            ..
        } if recipient_account_id == account_user_id
    ) {
        return Err(TransferError::SameWallet);
    }

    tx.execute(
        "UPDATE account_wallets
         SET balance_credits = balance_credits - ?, updated_at = ?
         WHERE account_user_id = ?",
        params![amount_credits, now, account_user_id],
    )?;
    tx.execute(
        "INSERT INTO account_ledger
            (account_user_id, asset, amount, type, timestamp, device_id, note)
         VALUES (?, 'credits', ?, 'TRANSFER_OUT', ?, ?, ?)",
        params![
            account_user_id,
            -amount_credits,
            now,
            actor_device_id,
            format_sender_note(&recipient, memo),
        ],
    )?;

    let sender_label = format!("account {account_user_id}");
    match &recipient {
        ResolvedTransferTarget::Device { device_id } => {
            tx.execute(
                "INSERT OR IGNORE INTO balances (device_id) VALUES (?)",
                [device_id],
            )?;
            tx.execute(
                "UPDATE balances SET balance = balance + ? WHERE device_id = ?",
                params![amount_credits, device_id],
            )?;
            tx.execute(
                "INSERT INTO ledger (device_id, type, amount, timestamp, note)
                 VALUES (?, 'TRANSFER_IN', ?, ?, ?)",
                params![
                    device_id,
                    amount_credits,
                    now,
                    format_recipient_note(&sender_label, memo),
                ],
            )?;
        }
        ResolvedTransferTarget::Account {
            account_user_id: recipient_account_id,
            ..
        } => {
            tx.execute(
                "UPDATE account_wallets
                 SET balance_credits = balance_credits + ?, updated_at = ?
                 WHERE account_user_id = ?",
                params![amount_credits, now, recipient_account_id],
            )?;
            tx.execute(
                "INSERT INTO account_ledger
                    (account_user_id, asset, amount, type, timestamp, device_id, note)
                 VALUES (?, 'credits', ?, 'TRANSFER_IN', ?, ?, ?)",
                params![
                    recipient_account_id,
                    amount_credits,
                    now,
                    actor_device_id,
                    format_recipient_note(&sender_label, memo),
                ],
            )?;
        }
    }

    tx.commit()?;

    Ok(TransferReceipt {
        asset: "credits".to_string(),
        amount: amount_credits,
        memo: memo.and_then(|value| {
            let trimmed = value.trim();
            (!trimmed.is_empty()).then_some(trimmed.to_string())
        }),
        sender_kind: "account".to_string(),
        sender_id: account_user_id.to_string(),
        sender_balance_credits: sender_balance - amount_credits,
        recipient: recipient.summary(),
    })
}

pub fn account_summary_for_device(
    pool: &DbPool,
    device_id: &str,
) -> anyhow::Result<AccountWalletSnapshot> {
    let Some(account_user_id) = account_user_id_for_device(pool, device_id) else {
        anyhow::bail!("device is not linked to an account");
    };
    account_summary(pool, &account_user_id)
}

pub fn account_device_ids(pool: &DbPool, account_user_id: &str) -> anyhow::Result<Vec<String>> {
    let conn = pool.lock();
    let mut stmt = conn.prepare(
        "SELECT device_id
         FROM account_devices
         WHERE account_user_id = ?
         ORDER BY last_seen DESC, device_id ASC",
    )?;
    let rows = stmt.query_map([account_user_id], |r| r.get::<_, String>(0))?;
    Ok(rows.filter_map(|row| row.ok()).collect())
}

pub fn account_summary(
    pool: &DbPool,
    account_user_id: &str,
) -> anyhow::Result<AccountWalletSnapshot> {
    let conn = pool.lock();
    let (display_name, phone, email, github_username, balance_credits, usdc_cents): (
        Option<String>,
        Option<String>,
        Option<String>,
        Option<String>,
        i64,
        i64,
    ) = conn.query_row(
        "SELECT display_name, phone, email, github_username, balance_credits, usdc_cents
         FROM account_wallets WHERE account_user_id = ?",
        [account_user_id],
        |r| {
            Ok((
                r.get(0)?,
                r.get(1)?,
                r.get(2)?,
                r.get(3)?,
                r.get(4)?,
                r.get(5)?,
            ))
        },
    )?;

    let devices = {
        let mut stmt = conn.prepare(
            "SELECT ad.device_id, ad.device_name, ad.platform, ad.linked_at, ad.last_seen,
                    COALESCE(b.balance, 0) AS wallet_balance_credits
             FROM account_devices ad
             LEFT JOIN balances b ON b.device_id = ad.device_id
             WHERE ad.account_user_id = ?
             ORDER BY ad.last_seen DESC, ad.device_id ASC",
        )?;
        let rows = stmt.query_map([account_user_id], |r| {
            Ok(AccountDeviceSnapshot {
                device_id: r.get(0)?,
                device_name: r.get(1)?,
                platform: r.get(2)?,
                linked_at: r.get(3)?,
                last_seen: r.get(4)?,
                wallet_balance_credits: r.get(5)?,
                wallet_usdc_cents: 0,
            })
        })?;
        rows.filter_map(|row| row.ok()).collect()
    };

    let transactions = list_account_transactions_locked(&conn, account_user_id, 100)?;

    Ok(AccountWalletSnapshot {
        account_user_id: account_user_id.to_string(),
        balance_credits,
        usdc_cents,
        display_name,
        phone,
        email,
        github_username,
        devices,
        transactions,
    })
}

pub fn sweep_device_to_account(
    pool: &DbPool,
    requester_device_id: &str,
    target_device_id: &str,
) -> anyhow::Result<AccountSweepResult> {
    let mut conn = pool.lock();
    let now = unix_now();
    let tx = conn.transaction()?;

    let requester_account: Option<String> = tx
        .query_row(
            "SELECT account_user_id FROM account_devices WHERE device_id = ?",
            [requester_device_id],
            |r| r.get(0),
        )
        .ok();
    let Some(account_user_id) = requester_account else {
        anyhow::bail!("requesting device is not linked to an account");
    };

    let target_account: Option<String> = tx
        .query_row(
            "SELECT account_user_id FROM account_devices WHERE device_id = ?",
            [target_device_id],
            |r| r.get(0),
        )
        .ok();
    if target_account.as_deref() != Some(account_user_id.as_str()) {
        anyhow::bail!("target device is not linked to this account");
    }

    tx.execute(
        "INSERT OR IGNORE INTO balances (device_id) VALUES (?)",
        [target_device_id],
    )?;
    let (balance_credits, usdc_cents): (i64, i64) = tx.query_row(
        "SELECT balance, 0 FROM balances WHERE device_id = ?",
        [target_device_id],
        |r| Ok((r.get(0)?, r.get(1)?)),
    )?;

    if balance_credits > 0 {
        tx.execute(
            "INSERT INTO ledger (device_id, type, amount, timestamp, note)
             VALUES (?, 'ACCOUNT_SWEEP_OUT', ?, ?, ?)",
            params![
                target_device_id,
                -balance_credits,
                now,
                format!("swept to account {account_user_id}")
            ],
        )?;
        tx.execute(
            "UPDATE balances SET balance = balance - ?, total_spent = total_spent + ?
             WHERE device_id = ?",
            params![balance_credits, balance_credits, target_device_id],
        )?;
        tx.execute(
            "UPDATE account_wallets
             SET balance_credits = balance_credits + ?, updated_at = ?
             WHERE account_user_id = ?",
            params![balance_credits, now, account_user_id],
        )?;
        tx.execute(
            "INSERT INTO account_ledger
                (account_user_id, asset, amount, type, timestamp, device_id, note)
             VALUES (?, 'credits', ?, 'SWEEP_IN', ?, ?, ?)",
            params![
                account_user_id,
                balance_credits,
                now,
                target_device_id,
                format!("swept from device {target_device_id}")
            ],
        )?;
    }

    if usdc_cents > 0 {
        tx.execute(
            "UPDATE account_wallets
             SET usdc_cents = usdc_cents + ?, updated_at = ?
             WHERE account_user_id = ?",
            params![usdc_cents, now, account_user_id],
        )?;
        tx.execute(
            "INSERT INTO account_ledger
                (account_user_id, asset, amount, type, timestamp, device_id, note)
             VALUES (?, 'usdc', ?, 'SWEEP_IN', ?, ?, ?)",
            params![
                account_user_id,
                usdc_cents,
                now,
                target_device_id,
                format!("swept from device {target_device_id}")
            ],
        )?;
    }

    tx.commit()?;
    drop(conn);

    Ok(AccountSweepResult {
        swept_credits: balance_credits,
        swept_usdc_cents: usdc_cents,
        account: account_summary(pool, &account_user_id)?,
    })
}

pub fn remove_device_from_account(
    pool: &DbPool,
    requester_device_id: &str,
    target_device_id: &str,
) -> anyhow::Result<AccountWalletSnapshot> {
    if requester_device_id == target_device_id {
        anyhow::bail!("current device cannot remove itself from this account");
    }

    let mut conn = pool.lock();
    let tx = conn.transaction()?;
    let requester_account: Option<String> = tx
        .query_row(
            "SELECT account_user_id FROM account_devices WHERE device_id = ?",
            [requester_device_id],
            |r| r.get(0),
        )
        .ok();
    let Some(account_user_id) = requester_account else {
        anyhow::bail!("requesting device is not linked to an account");
    };

    let target_account: Option<String> = tx
        .query_row(
            "SELECT account_user_id FROM account_devices WHERE device_id = ?",
            [target_device_id],
            |r| r.get(0),
        )
        .ok();
    if target_account.as_deref() != Some(account_user_id.as_str()) {
        anyhow::bail!("target device is not linked to this account");
    }

    tx.execute(
        "DELETE FROM account_devices WHERE device_id = ?",
        [target_device_id],
    )?;
    tx.commit()?;
    drop(conn);
    account_summary(pool, &account_user_id)
}

fn list_account_transactions_locked(
    conn: &rusqlite::Connection,
    account_user_id: &str,
    limit: i64,
) -> anyhow::Result<Vec<AccountLedgerEntry>> {
    let mut stmt = conn.prepare(
        "SELECT id, account_user_id, asset, amount, type, timestamp, device_id, note
         FROM account_ledger
         WHERE account_user_id = ?
         ORDER BY timestamp DESC, id DESC
         LIMIT ?",
    )?;
    let rows = stmt.query_map(params![account_user_id, limit], |r| {
        Ok(AccountLedgerEntry {
            id: r.get(0)?,
            account_user_id: r.get(1)?,
            asset: r.get(2)?,
            amount: r.get(3)?,
            type_: r.get(4)?,
            timestamp: r.get(5)?,
            device_id: r.get(6)?,
            note: r.get(7)?,
        })
    })?;
    Ok(rows.filter_map(|row| row.ok()).collect())
}

/// Called after a chat completion. Distributes:
///   - consumer SPENT (negative) — debited from the paying device, account
///     wallet, or share-key issuer/pool
///   - provider DIRECT_EARN (70% of effective cost)
///   - AVAILABILITY_EARN to all other eligible online devices (25%, pro-rata)
///   - OPS_FEE (5%) internal — plus any integer-division leftover and the
///     25% that rolls to ops when no eligible pool recipients exist
///
/// Non-negative balance invariant: if the consumer's balance at commit time
/// is below `cost`, the debit is capped at the available balance and every
/// earner's share is scaled proportionally (down to `effective_cost`). The
/// shortfall is recorded on the SPENT row's `note`. The primary defense is
/// the pre-flight balance check in the chat handler; this guard catches the
/// concurrent-request edge case.
///
/// When the consumer is a `Share` principal, the key's `consumed_credits` is
/// incremented inside the same transaction so budget enforcement stays
/// consistent with wallet accounting.
pub fn settle_request(
    pool: &DbPool,
    consumer: &ConsumerPrincipal,
    provider_device_id: Option<&str>,
    online_device_ids: &[String],
    cost: i64,
    request_id: &str,
    model: &str,
) -> anyhow::Result<()> {
    if cost <= 0 {
        return Ok(());
    }
    let paying_device_id = consumer.paying_device_id();

    let mut conn = pool.lock();
    let now = unix_now();
    let tx = conn.transaction()?;

    // Compute the effective (actually-payable) cost. For device principals
    // this is bounded by the wallet balance; for share-keys, by the key's
    // pre-funded pool remainder. In both cases the non-negative invariant
    // holds: we never debit more than the source can cover.
    if let Some(paying_device_id) = paying_device_id {
        tx.execute(
            "INSERT OR IGNORE INTO balances (device_id) VALUES (?)",
            [paying_device_id],
        )?;
    }
    // Share-key funded status (only relevant for Share principals). Keys
    // minted post-refactor (`funded=1`) have a pre-stocked pool; legacy keys
    // (`funded=0`) still debit the issuer's wallet at settle time until an
    // operator runs the retroactive-funding migration.
    let share_funded = match consumer {
        ConsumerPrincipal::Share { key_id, .. } => tx
            .query_row(
                "SELECT funded FROM share_keys WHERE key_id = ?",
                [key_id],
                |r| r.get::<_, i64>(0),
            )
            .ok(),
        _ => None,
    };
    let effective_cost = match consumer {
        ConsumerPrincipal::Device(_) => {
            let paying_device_id = paying_device_id.expect("device principal has device id");
            let bal: i64 = tx
                .query_row(
                    "SELECT balance FROM balances WHERE device_id = ?",
                    [paying_device_id],
                    |r| r.get(0),
                )
                .unwrap_or(0);
            cost.min(bal.max(0))
        }
        ConsumerPrincipal::Account { account_user_id } => {
            let bal: i64 = tx
                .query_row(
                    "SELECT balance_credits FROM account_wallets WHERE account_user_id = ?",
                    [account_user_id],
                    |r| r.get(0),
                )
                .unwrap_or(0);
            cost.min(bal.max(0))
        }
        ConsumerPrincipal::Share { key_id, .. } => {
            let paying_device_id = paying_device_id.expect("share principal has issuer device id");
            if share_funded == Some(1) {
                // New semantics: debit from the pre-funded pool.
                let remaining = sum_share_key_contributions_tx(&tx, key_id).unwrap_or(0);
                cost.min(remaining.max(0))
            } else {
                // Legacy pre-refactor key: debit directly from the issuer's
                // wallet, capped at wallet balance AND the key's remaining
                // budget (the original cap semantics).
                let bal: i64 = tx
                    .query_row(
                        "SELECT balance FROM balances WHERE device_id = ?",
                        [paying_device_id],
                        |r| r.get(0),
                    )
                    .unwrap_or(0);
                let key_remaining: i64 = tx
                    .query_row(
                        "SELECT budget_credits - consumed_credits FROM share_keys WHERE key_id = ?",
                        [key_id],
                        |r| r.get(0),
                    )
                    .unwrap_or(0);
                cost.min(bal.max(0)).min(key_remaining.max(0))
            }
        }
    };
    let shortfall = cost - effective_cost;

    // Split the effective (actually-payable) amount 70/25/5.
    let direct_earn = effective_cost * 70 / 100;
    let pool_share = effective_cost * 25 / 100;
    let ops_fee = effective_cost - direct_earn - pool_share;

    // Filter provider + paying device out of availability recipients.
    let recipients: Vec<&String> = online_device_ids
        .iter()
        .filter(|d| Some(d.as_str()) != provider_device_id && Some(d.as_str()) != paying_device_id)
        .collect();

    let per_peer = if recipients.is_empty() {
        0
    } else {
        pool_share / recipients.len() as i64
    };
    let availability_used = per_peer * recipients.len() as i64;
    // Whatever we couldn't split into whole credits folds back to ops; the
    // entire pool does so if there are no recipients.
    let pool_leftover = pool_share - availability_used;

    let note_base = match consumer {
        ConsumerPrincipal::Device(_) => format!("model={}", model),
        ConsumerPrincipal::Account { account_user_id } => {
            format!("account={} model={}", account_user_id, model)
        }
        ConsumerPrincipal::Share { key_id, .. } => {
            format!("share_key:{} model={}", key_id, model)
        }
    };
    let note = if shortfall > 0 {
        format!("{} shortfall={}", note_base, shortfall)
    } else {
        note_base
    };

    // Record the SPENT ledger entry against the paying device for audit
    // attribution regardless of source (device wallet OR share-key pool). We
    // always record it (even at effective_cost==0) so the request shows up
    // in wallet history.
    match consumer {
        ConsumerPrincipal::Device(_) | ConsumerPrincipal::Share { .. } => {
            let paying_device_id = paying_device_id.expect("device-backed principal has device id");
            tx.execute(
                "INSERT INTO ledger (device_id, type, amount, timestamp, ref_request_id, note)
                 VALUES (?, 'SPENT', ?, ?, ?, ?)",
                params![paying_device_id, -effective_cost, now, request_id, &note],
            )?;
        }
        ConsumerPrincipal::Account { account_user_id } => {
            tx.execute(
                "INSERT INTO account_ledger
                    (account_user_id, asset, amount, type, timestamp, device_id, note)
                 VALUES (?, 'credits', ?, 'INFERENCE_SPENT', ?, NULL, ?)",
                params![account_user_id, -effective_cost, now, &note],
            )?;
        }
    }
    if effective_cost > 0 {
        match consumer {
            ConsumerPrincipal::Device(_) => {
                let paying_device_id = paying_device_id.expect("device principal has device id");
                // Device path: debit the wallet and bump total_spent.
                tx.execute(
                    "UPDATE balances SET balance = balance - ?, total_spent = total_spent + ?
                     WHERE device_id = ?",
                    params![effective_cost, effective_cost, paying_device_id],
                )?;
            }
            ConsumerPrincipal::Account { account_user_id } => {
                tx.execute(
                    "UPDATE account_wallets
                     SET balance_credits = balance_credits - ?, updated_at = ?
                     WHERE account_user_id = ?",
                    params![effective_cost, now, account_user_id],
                )?;
            }
            ConsumerPrincipal::Share { key_id, .. } => {
                let paying_device_id =
                    paying_device_id.expect("share principal has issuer device id");
                // Always bump the key's consumed_credits ticker so budget
                // exhaustion tracks across both semantics.
                tx.execute(
                    "UPDATE share_keys SET consumed_credits = consumed_credits + ?
                     WHERE key_id = ?",
                    params![effective_cost, key_id],
                )?;
                if share_funded == Some(1) {
                    apply_pro_rata_share_key_spend_tx(&tx, key_id, effective_cost)?;
                    // New: pool already holds the funds; just bump
                    // total_spent on the issuer's wallet to keep cumulative
                    // accounting coherent (from the wallet-owner's
                    // perspective, a share-key spend IS their spend — they
                    // funded it at mint time).
                    tx.execute(
                        "UPDATE balances SET total_spent = total_spent + ?
                         WHERE device_id = ?",
                        params![effective_cost, paying_device_id],
                    )?;
                } else {
                    // Legacy: debit the issuer's wallet directly.
                    tx.execute(
                        "UPDATE balances SET balance = balance - ?, total_spent = total_spent + ?
                         WHERE device_id = ?",
                        params![effective_cost, effective_cost, paying_device_id],
                    )?;
                }
            }
        }
    }

    // Provider DIRECT_EARN
    if let Some(provider) = provider_device_id {
        if direct_earn > 0 {
            tx.execute(
                "INSERT OR IGNORE INTO balances (device_id) VALUES (?)",
                [provider],
            )?;
            tx.execute(
                "INSERT INTO ledger (device_id, type, amount, timestamp, ref_request_id, note)
                 VALUES (?, 'DIRECT_EARN', ?, ?, ?, ?)",
                params![provider, direct_earn, now, request_id, &note],
            )?;
            tx.execute(
                "UPDATE balances SET balance = balance + ?, total_earned = total_earned + ?
                 WHERE device_id = ?",
                params![direct_earn, direct_earn, provider],
            )?;
        }
    }

    // Availability earns
    if per_peer > 0 {
        for peer in &recipients {
            tx.execute(
                "INSERT OR IGNORE INTO balances (device_id) VALUES (?)",
                [peer.as_str()],
            )?;
            tx.execute(
                "INSERT INTO ledger (device_id, type, amount, timestamp, ref_request_id, note)
                 VALUES (?, 'AVAILABILITY_EARN', ?, ?, ?, ?)",
                params![peer.as_str(), per_peer, now, request_id, &note],
            )?;
            tx.execute(
                "UPDATE balances SET balance = balance + ?, total_earned = total_earned + ?
                 WHERE device_id = ?",
                params![per_peer, per_peer, peer.as_str()],
            )?;
        }
    }

    // Ops fee + pool leftover — recorded under the sentinel `__ops__` device.
    let ops_total = ops_fee + pool_leftover;
    if ops_total > 0 {
        tx.execute(
            "INSERT OR IGNORE INTO balances (device_id) VALUES ('__ops__')",
            [],
        )?;
        tx.execute(
            "INSERT INTO ledger (device_id, type, amount, timestamp, ref_request_id, note)
             VALUES ('__ops__', 'OPS_FEE', ?, ?, ?, ?)",
            params![ops_total, now, request_id, &note],
        )?;
        tx.execute(
            "UPDATE balances SET balance = balance + ?, total_earned = total_earned + ?
             WHERE device_id = '__ops__'",
            params![ops_total, ops_total],
        )?;
    }

    tx.commit()?;
    Ok(())
}

/// Settlement when a centralized 3rd-party provider served the request.
/// Pays 95% to the provider's wallet (`provider_wallets`) and 5% to the Teale
/// ops account (`__ops__` in the device ledger). No availability pool — the
/// 25% availability slice exists to reward the idle distributed fleet for
/// keeping models warm; that incentive doesn't apply to a centralized vendor.
///
/// The consumer-debit path is identical to `settle_request`: the same
/// `effective_cost` cap (consumer balance OR share-key remainder) holds the
/// non-negative invariant. If the consumer can't cover `cost`, both the
/// provider's earn and the ops fee scale down proportionally.
pub fn settle_provider_request(
    pool: &DbPool,
    consumer: &ConsumerPrincipal,
    provider_id: &str,
    cost: i64,
    request_id: &str,
    model: &str,
) -> anyhow::Result<()> {
    if cost <= 0 {
        return Ok(());
    }
    let paying_device_id = consumer.paying_device_id();

    let mut conn = pool.lock();
    let now = unix_now();
    let tx = conn.transaction()?;

    if let Some(paying_device_id) = paying_device_id {
        tx.execute(
            "INSERT OR IGNORE INTO balances (device_id) VALUES (?)",
            [paying_device_id],
        )?;
    }
    let share_funded = match consumer {
        ConsumerPrincipal::Share { key_id, .. } => tx
            .query_row(
                "SELECT funded FROM share_keys WHERE key_id = ?",
                [key_id],
                |r| r.get::<_, i64>(0),
            )
            .ok(),
        _ => None,
    };
    let effective_cost = match consumer {
        ConsumerPrincipal::Device(_) => {
            let paying_device_id = paying_device_id.expect("device principal has device id");
            let bal: i64 = tx
                .query_row(
                    "SELECT balance FROM balances WHERE device_id = ?",
                    [paying_device_id],
                    |r| r.get(0),
                )
                .unwrap_or(0);
            cost.min(bal.max(0))
        }
        ConsumerPrincipal::Account { account_user_id } => {
            let bal: i64 = tx
                .query_row(
                    "SELECT balance_credits FROM account_wallets WHERE account_user_id = ?",
                    [account_user_id],
                    |r| r.get(0),
                )
                .unwrap_or(0);
            cost.min(bal.max(0))
        }
        ConsumerPrincipal::Share { key_id, .. } => {
            let paying_device_id = paying_device_id.expect("share principal has issuer device id");
            if share_funded == Some(1) {
                let remaining = sum_share_key_contributions_tx(&tx, key_id).unwrap_or(0);
                cost.min(remaining.max(0))
            } else {
                let bal: i64 = tx
                    .query_row(
                        "SELECT balance FROM balances WHERE device_id = ?",
                        [paying_device_id],
                        |r| r.get(0),
                    )
                    .unwrap_or(0);
                let key_remaining: i64 = tx
                    .query_row(
                        "SELECT budget_credits - consumed_credits FROM share_keys WHERE key_id = ?",
                        [key_id],
                        |r| r.get(0),
                    )
                    .unwrap_or(0);
                cost.min(bal.max(0)).min(key_remaining.max(0))
            }
        }
    };
    let shortfall = cost - effective_cost;

    let provider_earn = effective_cost * 95 / 100;
    let ops_fee = effective_cost - provider_earn;

    let note_base = match consumer {
        ConsumerPrincipal::Device(_) => format!("provider={} model={}", provider_id, model),
        ConsumerPrincipal::Account { account_user_id } => format!(
            "account={} provider={} model={}",
            account_user_id, provider_id, model
        ),
        ConsumerPrincipal::Share { key_id, .. } => format!(
            "share_key:{} provider={} model={}",
            key_id, provider_id, model
        ),
    };
    let note = if shortfall > 0 {
        format!("{} shortfall={}", note_base, shortfall)
    } else {
        note_base
    };

    // Consumer debit — identical bookkeeping to settle_request, just routed
    // to whichever wallet table backs the principal.
    match consumer {
        ConsumerPrincipal::Device(_) | ConsumerPrincipal::Share { .. } => {
            let paying_device_id = paying_device_id.expect("device-backed principal has device id");
            tx.execute(
                "INSERT INTO ledger (device_id, type, amount, timestamp, ref_request_id, note)
                 VALUES (?, 'SPENT', ?, ?, ?, ?)",
                params![paying_device_id, -effective_cost, now, request_id, &note],
            )?;
        }
        ConsumerPrincipal::Account { account_user_id } => {
            tx.execute(
                "INSERT INTO account_ledger
                    (account_user_id, asset, amount, type, timestamp, device_id, note)
                 VALUES (?, 'credits', ?, 'INFERENCE_SPENT', ?, NULL, ?)",
                params![account_user_id, -effective_cost, now, &note],
            )?;
        }
    }
    if effective_cost > 0 {
        match consumer {
            ConsumerPrincipal::Device(_) => {
                let paying_device_id = paying_device_id.expect("device principal has device id");
                tx.execute(
                    "UPDATE balances SET balance = balance - ?, total_spent = total_spent + ?
                     WHERE device_id = ?",
                    params![effective_cost, effective_cost, paying_device_id],
                )?;
            }
            ConsumerPrincipal::Account { account_user_id } => {
                tx.execute(
                    "UPDATE account_wallets
                     SET balance_credits = balance_credits - ?, updated_at = ?
                     WHERE account_user_id = ?",
                    params![effective_cost, now, account_user_id],
                )?;
            }
            ConsumerPrincipal::Share { key_id, .. } => {
                let paying_device_id =
                    paying_device_id.expect("share principal has issuer device id");
                tx.execute(
                    "UPDATE share_keys SET consumed_credits = consumed_credits + ?
                     WHERE key_id = ?",
                    params![effective_cost, key_id],
                )?;
                if share_funded == Some(1) {
                    apply_pro_rata_share_key_spend_tx(&tx, key_id, effective_cost)?;
                    tx.execute(
                        "UPDATE balances SET total_spent = total_spent + ?
                         WHERE device_id = ?",
                        params![effective_cost, paying_device_id],
                    )?;
                } else {
                    tx.execute(
                        "UPDATE balances SET balance = balance - ?, total_spent = total_spent + ?
                         WHERE device_id = ?",
                        params![effective_cost, effective_cost, paying_device_id],
                    )?;
                }
            }
        }
    }

    // Provider earn — credited to provider_wallets + provider_ledger.
    if provider_earn > 0 {
        tx.execute(
            "INSERT OR IGNORE INTO provider_wallets (provider_id, updated_at) VALUES (?, ?)",
            params![provider_id, now],
        )?;
        tx.execute(
            "INSERT INTO provider_ledger
                (provider_id, type, amount, timestamp, ref_request_id, model_id, note)
             VALUES (?, 'PROVIDER_EARN', ?, ?, ?, ?, ?)",
            params![provider_id, provider_earn, now, request_id, model, &note],
        )?;
        tx.execute(
            "UPDATE provider_wallets
             SET balance_credits = balance_credits + ?,
                 total_earned = total_earned + ?,
                 updated_at = ?
             WHERE provider_id = ?",
            params![provider_earn, provider_earn, now, provider_id],
        )?;
    }

    // Ops fee — recorded under the sentinel `__ops__` device, same shape as
    // the distributed-path OPS_FEE so existing wallet tooling sees it.
    if ops_fee > 0 {
        tx.execute(
            "INSERT OR IGNORE INTO balances (device_id) VALUES ('__ops__')",
            [],
        )?;
        tx.execute(
            "INSERT INTO ledger (device_id, type, amount, timestamp, ref_request_id, note)
             VALUES ('__ops__', 'OPS_FEE', ?, ?, ?, ?)",
            params![ops_fee, now, request_id, &note],
        )?;
        tx.execute(
            "UPDATE balances SET balance = balance + ?, total_earned = total_earned + ?
             WHERE device_id = '__ops__'",
            params![ops_fee, ops_fee],
        )?;
    }

    tx.commit()?;
    Ok(())
}

/// Records a provider payout: debits `provider_wallets.balance_credits` and
/// writes a `PROVIDER_PAYOUT` row. v1 has no real off-ramp — this is the
/// audit marker an operator uses when they've manually settled the provider
/// out-of-band (USDC wire, invoice, etc.).
pub fn record_provider_payout(
    pool: &DbPool,
    provider_id: &str,
    amount: i64,
    destination: Option<&str>,
) -> anyhow::Result<()> {
    if amount <= 0 {
        anyhow::bail!("payout amount must be positive");
    }
    let mut conn = pool.lock();
    let now = unix_now();
    let tx = conn.transaction()?;

    let bal: i64 = tx
        .query_row(
            "SELECT balance_credits FROM provider_wallets WHERE provider_id = ?",
            [provider_id],
            |r| r.get(0),
        )
        .unwrap_or(0);
    if amount > bal {
        anyhow::bail!(
            "payout exceeds provider balance: requested={} available={}",
            amount,
            bal
        );
    }

    let note = destination.map(|d| format!("dest={}", d)).unwrap_or_default();
    tx.execute(
        "INSERT INTO provider_ledger (provider_id, type, amount, timestamp, note)
         VALUES (?, 'PROVIDER_PAYOUT', ?, ?, ?)",
        params![provider_id, -amount, now, &note],
    )?;
    tx.execute(
        "UPDATE provider_wallets
         SET balance_credits = balance_credits - ?,
             total_paid_out = total_paid_out + ?,
             updated_at = ?
         WHERE provider_id = ?",
        params![amount, amount, now, provider_id],
    )?;
    tx.commit()?;
    Ok(())
}

/// Snapshot of a provider's wallet for the admin & public surfaces.
#[derive(Debug, Clone, Serialize)]
pub struct ProviderWalletView {
    #[serde(rename = "providerID")]
    pub provider_id: String,
    #[serde(rename = "balanceCredits")]
    pub balance_credits: i64,
    #[serde(rename = "totalEarned")]
    pub total_earned: i64,
    #[serde(rename = "totalPaidOut")]
    pub total_paid_out: i64,
}

pub fn get_provider_wallet(
    pool: &DbPool,
    provider_id: &str,
) -> anyhow::Result<Option<ProviderWalletView>> {
    let conn = pool.lock();
    let row = conn
        .query_row(
            "SELECT balance_credits, total_earned, total_paid_out
             FROM provider_wallets WHERE provider_id = ?",
            [provider_id],
            |r| {
                Ok(ProviderWalletView {
                    provider_id: provider_id.to_string(),
                    balance_credits: r.get(0)?,
                    total_earned: r.get(1)?,
                    total_paid_out: r.get(2)?,
                })
            },
        )
        .ok();
    Ok(row)
}

fn load_active_availability_sessions(
    tx: &rusqlite::Transaction<'_>,
) -> anyhow::Result<Vec<ActiveAvailabilitySession>> {
    let mut stmt = tx.prepare(
        "SELECT device_id, model_id, started_at, last_accrued_at, accrued_credits
         FROM availability_sessions",
    )?;
    let rows = stmt.query_map([], |row| {
        Ok(ActiveAvailabilitySession {
            device_id: row.get(0)?,
            model_id: row.get(1)?,
            started_at: row.get(2)?,
            _last_accrued_at: row.get(3)?,
            accrued_credits: row.get(4)?,
        })
    })?;
    Ok(rows.filter_map(Result::ok).collect())
}

fn finalize_availability_session(
    tx: &rusqlite::Transaction<'_>,
    session: &ActiveAvailabilitySession,
    ended_at: i64,
) -> anyhow::Result<()> {
    if session.accrued_credits > 0 {
        let duration_secs = ended_at.saturating_sub(session.started_at).max(1);
        let note = match session.model_id.as_deref() {
            Some(model_id) => format!(
                "availability session ended // model={} // duration={}s",
                model_id, duration_secs
            ),
            None => format!("availability session ended // duration={}s", duration_secs),
        };
        tx.execute(
            "INSERT INTO ledger (device_id, type, amount, timestamp, note)
             VALUES (?, ?, ?, ?, ?)",
            params![
                session.device_id,
                LedgerType::AvailabilitySession.as_str(),
                session.accrued_credits,
                ended_at,
                note,
            ],
        )?;
    }

    tx.execute(
        "DELETE FROM availability_sessions WHERE device_id = ?",
        [session.device_id.as_str()],
    )?;
    Ok(())
}

/// Credit currently available devices immediately while keeping one active
/// availability session per device. A single ledger row is emitted only when a
/// session ends because the device disappears, becomes unavailable, or changes
/// models.
pub fn reconcile_availability_sessions(
    pool: &DbPool,
    recipients: &[DripRecipient],
) -> anyhow::Result<AvailabilityReconcileReport> {
    let mut conn = pool.lock();
    let tx = conn.transaction()?;
    let now = unix_now();
    let active_sessions = load_active_availability_sessions(&tx)?;
    let recipient_map: HashMap<&str, &DripRecipient> = recipients
        .iter()
        .map(|recipient| (recipient.device_id.as_str(), recipient))
        .collect();
    let mut report = AvailabilityReconcileReport::default();

    for session in &active_sessions {
        let still_matching = recipient_map
            .get(session.device_id.as_str())
            .is_some_and(|recipient| recipient.model_id == session.model_id);
        if !still_matching {
            finalize_availability_session(&tx, session, now)?;
            report.finalized_sessions += 1;
        }
    }

    let total_needed: i64 = recipients
        .iter()
        .map(|recipient| recipient.credits.max(0))
        .sum();
    if total_needed > 0 {
        let remaining: i64 =
            tx.query_row("SELECT remaining FROM mint_pool WHERE id = 1", [], |r| {
                r.get(0)
            })?;
        if remaining < total_needed {
            tracing::warn!(
                "mint_pool remaining ({}) < drip amount ({}), skipping",
                remaining,
                total_needed
            );
            tx.commit()?;
            return Ok(report);
        }

        tx.execute(
            "UPDATE mint_pool SET remaining = remaining - ? WHERE id = 1",
            params![total_needed],
        )?;
    }

    for recipient in recipients {
        tx.execute(
            "INSERT OR IGNORE INTO devices (device_id, first_seen, last_seen) VALUES (?, ?, ?)",
            params![recipient.device_id.as_str(), now, now],
        )?;
        tx.execute(
            "UPDATE devices SET last_seen = ? WHERE device_id = ?",
            params![now, recipient.device_id.as_str()],
        )?;
        tx.execute(
            "INSERT OR IGNORE INTO balances (device_id) VALUES (?)",
            [recipient.device_id.as_str()],
        )?;
        tx.execute(
            "UPDATE balances SET balance = balance + ?, total_earned = total_earned + ?
             WHERE device_id = ?",
            params![
                recipient.credits,
                recipient.credits,
                recipient.device_id.as_str()
            ],
        )?;
        tx.execute(
            "INSERT INTO availability_sessions
                 (device_id, model_id, started_at, last_accrued_at, accrued_credits)
             VALUES (?, ?, ?, ?, ?)
             ON CONFLICT(device_id) DO UPDATE SET
                 model_id = excluded.model_id,
                 last_accrued_at = excluded.last_accrued_at,
                 accrued_credits = availability_sessions.accrued_credits + excluded.accrued_credits",
            params![
                recipient.device_id.as_str(),
                recipient.model_id.as_deref(),
                now,
                now,
                recipient.credits,
            ],
        )?;
        report.credited_devices += 1;
    }

    tx.commit()?;
    Ok(report)
}

/// Spawn the drip loop.
pub fn spawn_drip_loop(pool: DbPool, snapshot: impl Fn() -> Vec<DripRecipient> + Send + 'static) {
    let pool = Arc::clone(&pool);
    tokio::spawn(async move {
        let mut ticker = tokio::time::interval(std::time::Duration::from_secs(DRIP_INTERVAL_SECS));
        ticker.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
        loop {
            ticker.tick().await;
            let recipients = snapshot();
            match reconcile_availability_sessions(&pool, &recipients) {
                Ok(report) => {
                    if report.credited_devices > 0 || report.finalized_sessions > 0 {
                        tracing::debug!(
                            "availability reconcile: credited {} devices, finalized {} sessions",
                            report.credited_devices,
                            report.finalized_sessions
                        );
                    }
                }
                Err(e) => tracing::warn!("drip error: {}", e),
            }
        }
    });
}

// ── Share keys ───────────────────────────────────────────────────────────────
//
// Temporary scoped bearer tokens minted by a device for community previews.
// The key is a **pre-funded pool**: at mint time we atomically debit the
// issuer's wallet by `budget_credits` and record that as the key's pool.
// Subsequent bearer spend debits the pool (not the issuer's wallet) in
// `settle_request`, and a revoke refunds the unspent remainder back to the
// issuer. This decouples share-key spending from the issuer's live wallet
// balance: once minted, the bearer has a committed allowance.

/// Mint a share key. Atomically debits the issuer's wallet by the key's
/// budget and records the key row with `funded=1`. Fails if the issuer can't
/// cover the budget (non-negative-wallet invariant).
pub fn mint_share_key(
    pool: &DbPool,
    issuer_device_id: &str,
    label: Option<&str>,
    expires_in_seconds: i64,
    budget_credits: i64,
) -> anyhow::Result<ShareKeyMinted> {
    if !(SHARE_KEY_MIN_EXPIRES_IN..=SHARE_KEY_MAX_EXPIRES_IN).contains(&expires_in_seconds) {
        anyhow::bail!(
            "expiresInSeconds must be between {} and {}",
            SHARE_KEY_MIN_EXPIRES_IN,
            SHARE_KEY_MAX_EXPIRES_IN
        );
    }
    if !(SHARE_KEY_MIN_BUDGET..=SHARE_KEY_MAX_BUDGET).contains(&budget_credits) {
        anyhow::bail!(
            "budgetCredits must be between {} and {}",
            SHARE_KEY_MIN_BUDGET,
            SHARE_KEY_MAX_BUDGET
        );
    }
    let normalized_label = label.map(|s| s.trim()).filter(|s| !s.is_empty());
    if let Some(l) = normalized_label {
        if l.chars().count() > SHARE_KEY_MAX_LABEL_LEN {
            anyhow::bail!("label must be ≤ {} chars", SHARE_KEY_MAX_LABEL_LEN);
        }
    }

    let mut conn = pool.lock();
    let now = unix_now();
    let tx = conn.transaction()?;

    let active: i64 = tx.query_row(
        "SELECT COUNT(*) FROM share_keys
         WHERE issuer_device_id = ? AND revoked_at IS NULL AND expires_at > ?",
        params![issuer_device_id, now],
        |r| r.get(0),
    )?;
    if active >= SHARE_KEY_MAX_ACTIVE_PER_ISSUER {
        anyhow::bail!(
            "too many active share keys ({} max)",
            SHARE_KEY_MAX_ACTIVE_PER_ISSUER
        );
    }

    // Ensure the issuer has a balance row before we read, then check it can
    // cover the budget. The invariant is hard: wallets must never go negative.
    tx.execute(
        "INSERT OR IGNORE INTO balances (device_id) VALUES (?)",
        [issuer_device_id],
    )?;
    let issuer_balance: i64 = tx.query_row(
        "SELECT balance FROM balances WHERE device_id = ?",
        [issuer_device_id],
        |r| r.get(0),
    )?;
    if issuer_balance < budget_credits {
        anyhow::bail!(
            "insufficient wallet balance: have {}, need {}",
            issuer_balance,
            budget_credits
        );
    }

    let key_id = uuid::Uuid::new_v4().simple().to_string();
    let funding_id = new_share_key_funding_id();
    let token = format!("tok_share_{}", uuid::Uuid::new_v4().simple());
    let expires_at = now + expires_in_seconds;

    tx.execute(
        "INSERT INTO share_keys
         (key_id, token, issuer_device_id, label, expires_at, budget_credits,
          consumed_credits, created_at, revoked_at, funded, funding_id, refunds_settled_at)
         VALUES (?, ?, ?, ?, ?, ?, 0, ?, NULL, 1, ?, NULL)",
        params![
            &key_id,
            &token,
            issuer_device_id,
            normalized_label,
            expires_at,
            budget_credits,
            now,
            &funding_id,
        ],
    )?;
    // Debit issuer: balance drops but total_spent does NOT — the funds are
    // transferred to the share-key pool, not spent. They come back on revoke.
    tx.execute(
        "UPDATE balances SET balance = balance - ? WHERE device_id = ?",
        params![budget_credits, issuer_device_id],
    )?;
    tx.execute(
        "INSERT INTO ledger (device_id, type, amount, timestamp, note)
         VALUES (?, ?, ?, ?, ?)",
        params![
            issuer_device_id,
            LedgerType::ShareKeyFund.as_str(),
            -budget_credits,
            now,
            format!("share_key:{} funded", key_id),
        ],
    )?;
    insert_share_key_contribution_tx(
        &tx,
        &key_id,
        issuer_device_id,
        budget_credits,
        budget_credits,
        now,
        None,
        None,
    )?;
    tx.commit()?;

    Ok(ShareKeyMinted {
        key_id,
        funding_id,
        token,
        label: normalized_label.map(|s| s.to_string()),
        budget_credits,
        expires_at,
        created_at: now,
    })
}

/// Resolve a bearer against the share-keys table. Returns:
/// - `Ok(Some(resolved))` for a valid, live, un-exhausted key
/// - `Ok(None)` if the token isn't a share key (caller should fall through)
/// - `Err(rejection)` if the token IS a share key but should be rejected
pub fn resolve_share_key(
    pool: &DbPool,
    token: &str,
) -> Result<Option<ResolvedShareKey>, ShareKeyRejection> {
    let conn = pool.lock();
    let row: Option<(String, String, i64, i64, i64, Option<i64>)> = conn
        .query_row(
            "SELECT key_id, issuer_device_id, expires_at, budget_credits,
                    consumed_credits, revoked_at
             FROM share_keys WHERE token = ?",
            [token],
            |r| {
                Ok((
                    r.get(0)?,
                    r.get(1)?,
                    r.get(2)?,
                    r.get(3)?,
                    r.get(4)?,
                    r.get(5)?,
                ))
            },
        )
        .ok();
    drop(conn);

    let (key_id, issuer_device_id, expires_at, budget_credits, consumed_credits, revoked_at) =
        match row {
            Some(r) => r,
            None => return Ok(None),
        };

    if revoked_at.is_some() {
        return Err(ShareKeyRejection::Revoked);
    }
    if expires_at <= unix_now() {
        return Err(ShareKeyRejection::Expired);
    }
    if consumed_credits >= budget_credits {
        return Err(ShareKeyRejection::Exhausted);
    }
    Ok(Some(ResolvedShareKey {
        key_id,
        issuer_device_id,
        budget_credits,
        consumed_credits,
        expires_at,
    }))
}

/// List keys owned by `issuer_device_id`, newest first. Excludes the raw token.
pub fn list_share_keys(pool: &DbPool, issuer_device_id: &str) -> Vec<ShareKeyPublic> {
    let conn = pool.lock();
    let mut stmt = match conn.prepare(
        "SELECT sk.key_id, sk.funding_id, sk.label, sk.budget_credits, sk.consumed_credits,
                COALESCE(
                    CASE
                        WHEN sk.funded = 1 THEN (
                            SELECT SUM(skc.remaining_credits)
                            FROM share_key_contributions skc
                            WHERE skc.key_id = sk.key_id
                        )
                        ELSE sk.budget_credits - sk.consumed_credits
                    END,
                    0
                ) AS remaining_credits,
                sk.expires_at, sk.created_at, sk.revoked_at
         FROM share_keys sk WHERE sk.issuer_device_id = ?
         ORDER BY created_at DESC",
    ) {
        Ok(s) => s,
        Err(_) => return vec![],
    };
    stmt.query_map([issuer_device_id], |r| {
        Ok(ShareKeyPublic {
            key_id: r.get(0)?,
            funding_id: r.get(1)?,
            label: r.get(2)?,
            budget_credits: r.get(3)?,
            consumed_credits: r.get(4)?,
            remaining_credits: r.get(5)?,
            expires_at: r.get(6)?,
            created_at: r.get(7)?,
            revoked_at: r.get(8)?,
        })
    })
    .ok()
    .map(|iter| iter.filter_map(|r| r.ok()).collect())
    .unwrap_or_default()
}

/// Soft-revoke a key and refund each funder's unspent contribution back to
/// that funder atomically. Returns `true` if a row was updated (key belongs to
/// issuer, not already revoked), `false` if no matching row was found.
pub fn revoke_share_key(
    pool: &DbPool,
    issuer_device_id: &str,
    key_id: &str,
) -> anyhow::Result<bool> {
    let mut conn = pool.lock();
    let now = unix_now();
    let tx = conn.transaction()?;

    // Look up the key's state under the transaction lock so the refund
    // amount doesn't race with concurrent settlements. Only revoke-and-refund
    // if the key is still live, owned by this issuer, and funded (old
    // un-funded keys were not paid for so have nothing to refund).
    let row: Option<(i64, i64, i64, Option<i64>)> = tx
        .query_row(
            "SELECT budget_credits, consumed_credits, funded, refunds_settled_at
             FROM share_keys
             WHERE key_id = ? AND issuer_device_id = ? AND revoked_at IS NULL",
            params![key_id, issuer_device_id],
            |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?)),
        )
        .ok();
    let (budget, consumed, funded, refunds_settled_at) = match row {
        Some(v) => v,
        None => {
            tx.rollback()?;
            return Ok(false);
        }
    };

    tx.execute(
        "UPDATE share_keys SET revoked_at = ? WHERE key_id = ?",
        params![now, key_id],
    )?;

    let refund = (budget - consumed).max(0);
    if funded == 1 && refunds_settled_at.is_none() {
        let _ = refund;
        let _ = refund_share_key_contributions_tx(&tx, key_id, now, "revoked")?;
        tx.execute(
            "UPDATE share_keys SET refunds_settled_at = ? WHERE key_id = ?",
            params![now, key_id],
        )?;
    }
    tx.commit()?;
    Ok(true)
}

/// Outcome of the startup retroactive-funding pass for pre-refactor share
/// keys. Surfaced to the caller mainly for logging.
#[derive(Debug, Default, Clone, Copy, PartialEq, Eq)]
pub struct ShareKeyMigrationReport {
    pub funded_fully: usize,
    pub funded_partially: usize,
    pub skipped_revoked: usize,
    pub total_debited_credits: i64,
    pub total_shrunk_credits: i64,
}

/// One-shot migration: retroactively pre-fund share-key pools that existed
/// before the pre-funded-pool refactor. For each row with `funded=0`:
///
/// - **Revoked/expired keys** are marked funded without debiting (their
///   budget is moot; they can no longer be spent).
/// - **Live keys** get `(budget - consumed)` debited from the issuer. If the
///   issuer's wallet can't cover the full remainder, the key's budget is
///   shrunk to `consumed + issuer_balance` and only the affordable portion
///   is debited — preserving the non-negative-wallet invariant.
///
/// Idempotent: rows are marked `funded=1` after processing, so re-runs are
/// cheap no-ops.
pub fn migrate_unfunded_share_keys(pool: &DbPool) -> anyhow::Result<ShareKeyMigrationReport> {
    let mut conn = pool.lock();
    let now = unix_now();
    let tx = conn.transaction()?;

    let rows: Vec<ShareKeyMigrationRow> = {
        let mut stmt = tx.prepare(
            "SELECT key_id, issuer_device_id, budget_credits, consumed_credits,
                    expires_at, revoked_at, funding_id
             FROM share_keys WHERE funded = 0",
        )?;
        let collected: Vec<_> = stmt
            .query_map([], |r| {
                Ok((
                    r.get::<_, String>(0)?,
                    r.get::<_, String>(1)?,
                    r.get::<_, i64>(2)?,
                    r.get::<_, i64>(3)?,
                    r.get::<_, i64>(4)?,
                    r.get::<_, Option<i64>>(5)?,
                    r.get::<_, Option<String>>(6)?,
                ))
            })?
            .collect::<Result<Vec<_>, _>>()?;
        collected
    };

    let mut report = ShareKeyMigrationReport::default();
    for (key_id, issuer, budget, consumed, expires_at, revoked_at, funding_id) in rows {
        ensure_share_key_funding_id_tx(&tx, &key_id, funding_id)?;
        let is_dead = revoked_at.is_some() || expires_at <= now;
        if is_dead {
            tx.execute(
                "UPDATE share_keys SET funded = 1, refunds_settled_at = ? WHERE key_id = ?",
                params![revoked_at.unwrap_or(now), &key_id],
            )?;
            insert_share_key_contribution_tx(
                &tx,
                &key_id,
                &issuer,
                budget.max(1),
                0,
                revoked_at.unwrap_or(expires_at),
                Some(revoked_at.unwrap_or(now)),
                Some(if revoked_at.is_some() {
                    "legacy_revoked"
                } else {
                    "legacy_expired"
                }),
            )?;
            report.skipped_revoked += 1;
            continue;
        }

        let owed = (budget - consumed).max(0);
        if owed == 0 {
            tx.execute(
                "UPDATE share_keys SET funded = 1 WHERE key_id = ?",
                [&key_id],
            )?;
            insert_share_key_contribution_tx(
                &tx,
                &key_id,
                &issuer,
                budget.max(1),
                0,
                now,
                None,
                None,
            )?;
            report.funded_fully += 1;
            continue;
        }

        tx.execute(
            "INSERT OR IGNORE INTO balances (device_id) VALUES (?)",
            [&issuer],
        )?;
        let issuer_balance: i64 = tx.query_row(
            "SELECT balance FROM balances WHERE device_id = ?",
            [&issuer],
            |r| r.get(0),
        )?;

        let debit = owed.min(issuer_balance.max(0));
        let new_budget = consumed + debit;

        if debit > 0 {
            tx.execute(
                "UPDATE balances SET balance = balance - ? WHERE device_id = ?",
                params![debit, issuer],
            )?;
            tx.execute(
                "INSERT INTO ledger (device_id, type, amount, timestamp, note)
                 VALUES (?, ?, ?, ?, ?)",
                params![
                    issuer,
                    LedgerType::ShareKeyFund.as_str(),
                    -debit,
                    now,
                    format!("share_key:{} retroactive funding", key_id),
                ],
            )?;
        }
        // If we couldn't cover the full owed amount, shrink the key's budget
        // so that `budget - consumed == debit`. This keeps the pool balance
        // exactly equal to what we successfully pre-funded.
        if new_budget < budget {
            tx.execute(
                "UPDATE share_keys SET budget_credits = ?, funded = 1 WHERE key_id = ?",
                params![new_budget, key_id],
            )?;
            report.funded_partially += 1;
            report.total_shrunk_credits += budget - new_budget;
            insert_share_key_contribution_tx(
                &tx,
                &key_id,
                &issuer,
                debit.max(1),
                debit,
                now,
                None,
                None,
            )?;
        } else {
            tx.execute(
                "UPDATE share_keys SET funded = 1 WHERE key_id = ?",
                [&key_id],
            )?;
            report.funded_fully += 1;
            insert_share_key_contribution_tx(
                &tx,
                &key_id,
                &issuer,
                debit.max(1),
                debit,
                now,
                None,
                None,
            )?;
        }
        report.total_debited_credits += debit;
    }

    tx.commit()?;
    Ok(report)
}

/// Columns pulled from the `share_keys` row during a public preview:
/// `(label, budget_credits, consumed_credits, expires_at, issuer_device_id, revoked_at)`.
type PreviewRow = (Option<String>, i64, i64, i64, String, Option<i64>);

/// Public preview — no auth required. Looks up a key by token and exposes
/// only the fields needed to render the `/try/:token` landing page.
pub fn preview_share_key(pool: &DbPool, token: &str) -> Option<ShareKeyPreview> {
    let conn = pool.lock();
    let row: Option<PreviewRow> = conn
        .query_row(
            "SELECT sk.label, sk.budget_credits, sk.consumed_credits, sk.expires_at,
                    sk.issuer_device_id, sk.revoked_at
             FROM share_keys sk WHERE sk.token = ?",
            [token],
            |r| {
                Ok((
                    r.get(0)?,
                    r.get(1)?,
                    r.get(2)?,
                    r.get(3)?,
                    r.get(4)?,
                    r.get(5)?,
                ))
            },
        )
        .ok();
    let (label, budget_credits, consumed_credits, expires_at, issuer_device_id, revoked_at) = row?;
    // Hide revoked keys from the public preview — they look like 404s.
    if revoked_at.is_some() {
        return None;
    }
    let issuer_display_name: Option<String> = conn
        .query_row(
            "SELECT username FROM devices WHERE device_id = ?",
            [&issuer_device_id],
            |r| r.get::<_, Option<String>>(0),
        )
        .ok()
        .flatten();
    Some(ShareKeyPreview {
        label,
        budget_credits,
        consumed_credits,
        expires_at,
        issuer_display_name,
    })
}

pub fn preview_share_key_funding(
    pool: &DbPool,
    funding_id: &str,
) -> Option<ShareKeyFundingPreview> {
    let conn = pool.lock();
    let now = unix_now();
    let row: Option<ShareKeyFundingPreviewRow> = conn
        .query_row(
            "SELECT sk.label, sk.budget_credits, sk.consumed_credits, sk.expires_at,
                    sk.issuer_device_id, sk.revoked_at, sk.funded
             FROM share_keys sk
             WHERE sk.funding_id = ?",
            [funding_id],
            |r| {
                Ok((
                    r.get(0)?,
                    r.get(1)?,
                    r.get(2)?,
                    r.get(3)?,
                    r.get(4)?,
                    r.get(5)?,
                    r.get(6)?,
                ))
            },
        )
        .ok();
    let (label, budget_credits, consumed_credits, expires_at, issuer_device_id, revoked_at, funded) =
        row?;
    if revoked_at.is_some() || expires_at <= now || funded != 1 {
        return None;
    }
    let issuer_display_name: Option<String> = conn
        .query_row(
            "SELECT username FROM devices WHERE device_id = ?",
            [&issuer_device_id],
            |r| r.get::<_, Option<String>>(0),
        )
        .ok()
        .flatten();
    let remaining_credits: i64 = conn
        .query_row(
            "SELECT COALESCE(SUM(remaining_credits), 0)
             FROM share_key_contributions WHERE key_id = (
                 SELECT key_id FROM share_keys WHERE funding_id = ?
             )",
            [funding_id],
            |r| r.get(0),
        )
        .unwrap_or((budget_credits - consumed_credits).max(0));
    Some(ShareKeyFundingPreview {
        funding_id: funding_id.to_string(),
        label,
        issuer_display_name,
        budget_credits,
        consumed_credits,
        remaining_credits,
        expires_at,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::db::open_in_memory;

    #[test]
    fn welcome_bonus_and_balance() {
        let pool = open_in_memory().unwrap();
        let dev = "abc123";
        assert!(upsert_device(&pool, dev).unwrap());
        let bal = record_bonus(&pool, dev, WELCOME_BONUS_CREDITS).unwrap();
        assert_eq!(bal, WELCOME_BONUS_CREDITS);
        let snap = get_balance(&pool, dev);
        assert_eq!(snap.balance_credits, WELCOME_BONUS_CREDITS);
        assert_eq!(snap.total_earned_credits, WELCOME_BONUS_CREDITS);
    }

    #[test]
    fn settlement_splits_correctly() {
        let pool = open_in_memory().unwrap();
        let consumer = "consumer";
        let provider = "provider";
        let peer1 = "peer1";
        let peer2 = "peer2";
        for d in &[consumer, provider, peer1, peer2] {
            upsert_device(&pool, d).unwrap();
        }
        record_bonus(&pool, consumer, 10_000).unwrap();

        let online = vec![provider.to_string(), peer1.to_string(), peer2.to_string()];
        settle_request(
            &pool,
            &ConsumerPrincipal::Device(consumer.to_string()),
            Some(provider),
            &online,
            100,
            "req1",
            "gemma",
        )
        .unwrap();

        // cost=100: direct=70, pool=25, ops=5. Pool 25 split 2 ways = 12 each,
        // leftover=1 folds back to ops → ops=5+1=6.
        assert_eq!(get_balance(&pool, consumer).balance_credits, 10_000 - 100);
        assert_eq!(get_balance(&pool, provider).balance_credits, 70);
        assert_eq!(get_balance(&pool, peer1).balance_credits, 12);
        assert_eq!(get_balance(&pool, peer2).balance_credits, 12);
        assert_eq!(get_balance(&pool, "__ops__").balance_credits, 6);
    }

    #[test]
    fn settlement_rolls_pool_to_ops_when_no_peers() {
        // Only consumer + provider online → pool has no recipients; the
        // 25% rolls into ops along with the 5% fee.
        let pool = open_in_memory().unwrap();
        let consumer = "c";
        let provider = "p";
        for d in &[consumer, provider] {
            upsert_device(&pool, d).unwrap();
        }
        record_bonus(&pool, consumer, 10_000).unwrap();

        settle_request(
            &pool,
            &ConsumerPrincipal::Device(consumer.to_string()),
            Some(provider),
            &[provider.to_string()],
            100,
            "req-empty",
            "gemma",
        )
        .unwrap();

        assert_eq!(get_balance(&pool, consumer).balance_credits, 10_000 - 100);
        assert_eq!(get_balance(&pool, provider).balance_credits, 70);
        // ops = 5% fee + 25% unclaimed pool = 30
        assert_eq!(get_balance(&pool, "__ops__").balance_credits, 30);
    }

    #[test]
    fn settlement_matches_catalog_for_kimi() {
        // Regression tying cost_credits to the models.yaml pricing: 1M
        // completion tokens at $1/M = 1,000,000 credits; with a 70/25/5
        // split and 2 peers, provider earns 700,000 and each peer 125,000.
        let pool = open_in_memory().unwrap();
        for d in &["consumer", "provider", "peer1", "peer2"] {
            upsert_device(&pool, d).unwrap();
        }
        // Seed the consumer so they can actually afford the spend.
        record_bonus(&pool, "consumer", 2_000_000).unwrap();

        // $0.50/M prompt, $1.00/M completion — Kimi K2.6 rates.
        let kimi_prompt = 0.00000050_f64;
        let kimi_completion = 0.00000100_f64;
        let cost = cost_credits(0, 1_000_000, kimi_prompt, kimi_completion);
        assert_eq!(cost, 1_000_000);

        settle_request(
            &pool,
            &ConsumerPrincipal::Device("consumer".into()),
            Some("provider"),
            &["provider".into(), "peer1".into(), "peer2".into()],
            cost,
            "kimi-req",
            "kimi-k2.6",
        )
        .unwrap();

        assert_eq!(get_balance(&pool, "provider").balance_credits, 700_000);
        assert_eq!(get_balance(&pool, "peer1").balance_credits, 125_000);
        assert_eq!(get_balance(&pool, "peer2").balance_credits, 125_000);
        assert_eq!(get_balance(&pool, "__ops__").balance_credits, 50_000);
    }

    #[test]
    fn settlement_caps_at_consumer_balance_on_shortfall() {
        // Concurrent-request edge case: consumer has 40 credits but cost is
        // 100. Non-negative rule forces effective_cost = 40. All earners
        // scale down to the 70/25/5 split of 40 (= 28/10/2), keeping the
        // ledger balanced; the 60-credit shortfall is noted on the SPENT
        // row for audit.
        let pool = open_in_memory().unwrap();
        for d in &["consumer", "provider", "peer"] {
            upsert_device(&pool, d).unwrap();
        }
        record_bonus(&pool, "consumer", 40).unwrap();

        settle_request(
            &pool,
            &ConsumerPrincipal::Device("consumer".into()),
            Some("provider"),
            &["provider".into(), "peer".into()],
            100,
            "short-req",
            "gemma",
        )
        .unwrap();

        assert_eq!(get_balance(&pool, "consumer").balance_credits, 0);
        // 70% of 40 = 28
        assert_eq!(get_balance(&pool, "provider").balance_credits, 28);
        // 25% of 40 = 10, one peer → 10
        assert_eq!(get_balance(&pool, "peer").balance_credits, 10);
        // 40 - 28 - 10 = 2 to ops
        assert_eq!(get_balance(&pool, "__ops__").balance_credits, 2);

        let entries = list_transactions(&pool, "consumer", 10);
        assert!(
            entries.iter().any(|e| e
                .note
                .as_deref()
                .is_some_and(|n| n.contains("shortfall=60"))),
            "shortfall should be noted on the SPENT row"
        );
    }

    /// Helper that mirrors the admin-endpoint upsert path so the centralized
    /// settlement tests don't have to depend on the registry refresh.
    fn seed_provider_for_test(pool: &DbPool, provider_id: &str) {
        let conn = pool.lock();
        conn.execute(
            "INSERT INTO providers
                (provider_id, slug, display_name, base_url, wire_format,
                 auth_header_name, auth_secret_ref, status, data_collection,
                 zdr, quantization, created_at, updated_at)
             VALUES (?, 'acme', 'ACME', 'https://api.acme.example/v1',
                     'openai', 'Authorization', 'ACME_KEY', 'active', 'allow',
                     0, NULL, 0, 0)",
            [provider_id],
        )
        .unwrap();
    }

    #[test]
    fn provider_settlement_pays_95_5() {
        // 100-credit cost served by a centralized provider: 95 credits go
        // to the provider's wallet, 5 to ops, no availability pool.
        let pool = open_in_memory().unwrap();
        upsert_device(&pool, "consumer").unwrap();
        record_bonus(&pool, "consumer", 10_000).unwrap();
        seed_provider_for_test(&pool, "prov_acme");

        settle_provider_request(
            &pool,
            &ConsumerPrincipal::Device("consumer".into()),
            "prov_acme",
            100,
            "req-c1",
            "openai/gpt-oss-120b",
        )
        .unwrap();

        assert_eq!(get_balance(&pool, "consumer").balance_credits, 9_900);
        let wallet = get_provider_wallet(&pool, "prov_acme").unwrap().unwrap();
        assert_eq!(wallet.balance_credits, 95);
        assert_eq!(wallet.total_earned, 95);
        // Ops gets exactly 5 — no availability pool drift.
        assert_eq!(get_balance(&pool, "__ops__").balance_credits, 5);
    }

    #[test]
    fn provider_settlement_caps_at_consumer_balance() {
        // Consumer has only 40 credits but the upstream usage report would
        // imply a 100-credit cost. Effective cost clamps to 40, scaled
        // 95/5 → 38 to provider, 2 to ops.
        let pool = open_in_memory().unwrap();
        upsert_device(&pool, "consumer").unwrap();
        record_bonus(&pool, "consumer", 40).unwrap();
        seed_provider_for_test(&pool, "prov_acme");

        settle_provider_request(
            &pool,
            &ConsumerPrincipal::Device("consumer".into()),
            "prov_acme",
            100,
            "short-c1",
            "openai/gpt-oss-120b",
        )
        .unwrap();

        assert_eq!(get_balance(&pool, "consumer").balance_credits, 0);
        let wallet = get_provider_wallet(&pool, "prov_acme").unwrap().unwrap();
        assert_eq!(wallet.balance_credits, 38);
        assert_eq!(get_balance(&pool, "__ops__").balance_credits, 2);
    }

    #[test]
    fn provider_settlement_does_not_credit_availability_pool() {
        // Even if other devices are "online", the centralized path must NOT
        // pay an availability share. (The pool exists to reward idle fleet
        // for keeping models warm; a remote vendor doesn't share that
        // incentive.)
        let pool = open_in_memory().unwrap();
        for d in &["consumer", "peer1", "peer2"] {
            upsert_device(&pool, d).unwrap();
        }
        record_bonus(&pool, "consumer", 10_000).unwrap();
        seed_provider_for_test(&pool, "prov_acme");

        settle_provider_request(
            &pool,
            &ConsumerPrincipal::Device("consumer".into()),
            "prov_acme",
            100,
            "req-c2",
            "openai/gpt-oss-120b",
        )
        .unwrap();

        assert_eq!(get_balance(&pool, "peer1").balance_credits, 0);
        assert_eq!(get_balance(&pool, "peer2").balance_credits, 0);
    }

    #[test]
    fn provider_payout_debits_wallet_and_writes_audit_row() {
        let pool = open_in_memory().unwrap();
        upsert_device(&pool, "consumer").unwrap();
        record_bonus(&pool, "consumer", 10_000).unwrap();
        seed_provider_for_test(&pool, "prov_acme");

        settle_provider_request(
            &pool,
            &ConsumerPrincipal::Device("consumer".into()),
            "prov_acme",
            1_000,
            "req-payout",
            "openai/gpt-oss-120b",
        )
        .unwrap();
        let pre = get_provider_wallet(&pool, "prov_acme").unwrap().unwrap();
        assert_eq!(pre.balance_credits, 950);

        record_provider_payout(&pool, "prov_acme", 500, Some("usdc:0xabc")).unwrap();
        let post = get_provider_wallet(&pool, "prov_acme").unwrap().unwrap();
        assert_eq!(post.balance_credits, 450);
        assert_eq!(post.total_paid_out, 500);

        // Payouts above the wallet balance are rejected without mutation.
        let res = record_provider_payout(&pool, "prov_acme", 9_999, None);
        assert!(res.is_err(), "over-payout should error");
        let still = get_provider_wallet(&pool, "prov_acme").unwrap().unwrap();
        assert_eq!(still.balance_credits, 450);
    }

    #[test]
    fn drip_credits_online_devices() {
        let pool = open_in_memory().unwrap();
        upsert_device(&pool, "a").unwrap();
        upsert_device(&pool, "b").unwrap();
        reconcile_availability_sessions(
            &pool,
            &[
                DripRecipient {
                    device_id: "a".into(),
                    credits: 1,
                    model_id: Some("nousresearch/hermes-3-llama-3.1-8b".into()),
                },
                DripRecipient {
                    device_id: "b".into(),
                    credits: 4,
                    model_id: Some("mistralai/mistral-small-3.2-24b-instruct".into()),
                },
            ],
        )
        .unwrap();
        assert_eq!(get_balance(&pool, "a").balance_credits, 1);
        assert_eq!(get_balance(&pool, "b").balance_credits, 4);

        assert!(list_transactions(&pool, "b", 1).is_empty());

        reconcile_availability_sessions(&pool, &[]).unwrap();
        let entries = list_transactions(&pool, "b", 1);
        assert_eq!(entries.len(), 1);
        assert_eq!(entries[0].type_, "AVAILABILITY_SESSION");
        assert_eq!(entries[0].amount, 4);
        assert!(entries[0]
            .note
            .as_deref()
            .is_some_and(|note| note.contains("mistralai/mistral-small-3.2-24b-instruct")));
    }

    #[test]
    fn drip_credits_creates_missing_device_rows() {
        let pool = open_in_memory().unwrap();

        reconcile_availability_sessions(
            &pool,
            &[DripRecipient {
                device_id: "fresh-device".into(),
                credits: 1,
                model_id: Some("nousresearch/hermes-3-llama-3.1-8b".into()),
            }],
        )
        .unwrap();

        assert_eq!(get_balance(&pool, "fresh-device").balance_credits, 1);

        reconcile_availability_sessions(&pool, &[]).unwrap();
        let entries = list_transactions(&pool, "fresh-device", 1);
        assert_eq!(entries.len(), 1);
        assert_eq!(entries[0].type_, "AVAILABILITY_SESSION");
        assert_eq!(entries[0].amount, 1);
    }

    #[test]
    fn model_change_finalizes_previous_availability_session() {
        let pool = open_in_memory().unwrap();
        upsert_device(&pool, "a").unwrap();

        reconcile_availability_sessions(
            &pool,
            &[DripRecipient {
                device_id: "a".into(),
                credits: 1,
                model_id: Some("nousresearch/hermes-3-llama-3.1-8b".into()),
            }],
        )
        .unwrap();

        reconcile_availability_sessions(
            &pool,
            &[DripRecipient {
                device_id: "a".into(),
                credits: 4,
                model_id: Some("mistralai/mistral-small-3.2-24b-instruct".into()),
            }],
        )
        .unwrap();

        let entries = list_transactions(&pool, "a", 10);
        assert_eq!(entries.len(), 1);
        assert_eq!(entries[0].type_, "AVAILABILITY_SESSION");
        assert_eq!(entries[0].amount, 1);
        assert!(entries[0]
            .note
            .as_deref()
            .is_some_and(|note| note.contains("nousresearch/hermes-3-llama-3.1-8b")));
        assert_eq!(get_balance(&pool, "a").balance_credits, 5);
    }

    #[test]
    fn availability_tick_scales_from_hermes_pricing() {
        assert_eq!(availability_credits_per_tick(0.00000010, 0.00000020), 1);
        assert_eq!(availability_credits_per_tick(0.00000040, 0.00000080), 4);
        assert_eq!(availability_credits_per_tick(0.00000080, 0.00000160), 8);
    }

    #[test]
    fn cost_for_typical_turn() {
        // Llama 3.1 8B: $0.10/M prompt, $0.20/M completion.
        let p8b = 0.00000010_f64;
        let c8b = 0.00000020_f64;
        // 1000 prompt + 500 completion = 1000*0.1 + 500*0.2 = 200 credits.
        assert_eq!(cost_credits(1000, 500, p8b, c8b), 200);
        // Zero tokens still returns the 1-credit floor.
        assert_eq!(cost_credits(0, 0, p8b, c8b), 1);
        // 1M completion tokens of an $0.20/M model = 200,000 credits.
        assert_eq!(cost_credits(0, 1_000_000, p8b, c8b), 200_000);
    }

    #[test]
    fn challenge_consume_once() {
        let pool = open_in_memory().unwrap();
        upsert_device(&pool, "d1").unwrap();
        create_challenge(&pool, "d1", "nonce1").unwrap();
        assert!(consume_challenge(&pool, "d1", "nonce1").unwrap());
        // Second consume should fail
        assert!(!consume_challenge(&pool, "d1", "nonce1").unwrap());
    }

    // ── Share keys ──────────────────────────────────────────────────────

    #[test]
    fn mint_share_key_persists_and_is_resolvable() {
        let pool = open_in_memory().unwrap();
        let issuer = "issuer1";
        upsert_device(&pool, issuer).unwrap();
        // New semantics: mint pre-funds the pool from the issuer's wallet.
        record_bonus(&pool, issuer, 500).unwrap();

        let minted = mint_share_key(&pool, issuer, Some("demo"), 3600, 500).unwrap();
        assert!(minted.token.starts_with("tok_share_"));
        assert_eq!(minted.budget_credits, 500);
        assert_eq!(minted.label.as_deref(), Some("demo"));
        // Issuer's wallet was debited by the full budget at mint time.
        assert_eq!(get_balance(&pool, issuer).balance_credits, 0);

        let resolved = resolve_share_key(&pool, &minted.token).unwrap().unwrap();
        assert_eq!(resolved.key_id, minted.key_id);
        assert_eq!(resolved.issuer_device_id, issuer);
        assert_eq!(resolved.budget_credits, 500);
        assert_eq!(resolved.consumed_credits, 0);
        assert_eq!(resolved.remaining(), 500);
    }

    #[test]
    fn mint_share_key_rejects_when_issuer_cant_cover_budget() {
        let pool = open_in_memory().unwrap();
        let issuer = "broke";
        upsert_device(&pool, issuer).unwrap();
        // No bonus — issuer wallet is empty. Mint must refuse rather than
        // driving the wallet negative.
        let err = mint_share_key(&pool, issuer, None, 3600, 100).unwrap_err();
        assert!(
            err.to_string().contains("insufficient wallet balance"),
            "unexpected error: {}",
            err
        );
    }

    #[test]
    fn settle_share_key_debits_pool_and_bumps_consumed() {
        // Post-refactor: the share-key pool (not the issuer's wallet) is the
        // source of funds at settle time. The wallet was already debited at
        // mint. Earners still get paid out of the pool in the 70/25/5 split.
        let pool = open_in_memory().unwrap();
        let issuer = "alice";
        let provider = "provider";
        let peer = "peer1";
        for d in &[issuer, provider, peer] {
            upsert_device(&pool, d).unwrap();
        }
        record_bonus(&pool, issuer, 10_000).unwrap();

        let minted = mint_share_key(&pool, issuer, None, 3600, 1_000).unwrap();
        // After mint: issuer had 10_000 credits, 1_000 transferred into pool.
        assert_eq!(get_balance(&pool, issuer).balance_credits, 9_000);

        let online = vec![provider.to_string(), peer.to_string()];
        settle_request(
            &pool,
            &ConsumerPrincipal::Share {
                issuer_device_id: issuer.to_string(),
                key_id: minted.key_id.clone(),
            },
            Some(provider),
            &online,
            100,
            "reqX",
            "gemma",
        )
        .unwrap();

        // Settle doesn't re-debit the issuer — wallet stays at 9_000.
        assert_eq!(get_balance(&pool, issuer).balance_credits, 9_000);
        // Provider earned 70% of 100 = 70.
        assert_eq!(get_balance(&pool, provider).balance_credits, 70);
        // Peer earned the availability cut (≥1).
        assert!(get_balance(&pool, peer).balance_credits > 0);

        let resolved = resolve_share_key(&pool, &minted.token).unwrap().unwrap();
        assert_eq!(resolved.consumed_credits, 100);
        assert_eq!(resolved.remaining(), 900);

        // Ledger entry notes the key_id so wallet history is attributable.
        let entries = list_transactions(&pool, issuer, 10);
        assert!(entries
            .iter()
            .any(|e| e.note.as_deref().is_some_and(|n| n.contains("share_key:"))));
    }

    #[test]
    fn legacy_unfunded_share_key_still_debits_issuer_on_settle() {
        // Pre-refactor key with funded=0: settle must fall back to debiting
        // the issuer's wallet (old semantics) until an operator runs the
        // migration. This keeps existing tokens working between deploy and
        // admin-migrate without silently creating credits from thin air.
        let pool = open_in_memory().unwrap();
        let issuer = "alice";
        let provider = "provider";
        for d in &[issuer, provider] {
            upsert_device(&pool, d).unwrap();
        }
        record_bonus(&pool, issuer, 1_000).unwrap();

        // Insert a legacy row (funded=0, no mint-time debit).
        let now = unix_now();
        let key_id = "ki_legacy";
        let token = "tok_share_legacy";
        {
            let conn = pool.lock();
            conn.execute(
                "INSERT INTO share_keys
                 (key_id, token, issuer_device_id, label, expires_at,
                  budget_credits, consumed_credits, created_at, revoked_at, funded)
                 VALUES (?, ?, ?, NULL, ?, ?, 0, ?, NULL, 0)",
                params![key_id, token, issuer, now + 3600, 10_000i64, now],
            )
            .unwrap();
        }
        // Issuer wallet should still be 1000 (no mint-time debit under legacy).
        assert_eq!(get_balance(&pool, issuer).balance_credits, 1_000);

        settle_request(
            &pool,
            &ConsumerPrincipal::Share {
                issuer_device_id: issuer.to_string(),
                key_id: key_id.to_string(),
            },
            Some(provider),
            &[provider.to_string()],
            200,
            "reqL",
            "gemma",
        )
        .unwrap();

        // Legacy: issuer wallet dropped by 200 at settle (not at mint).
        assert_eq!(get_balance(&pool, issuer).balance_credits, 800);
        // Provider earned 70% of 200 = 140.
        assert_eq!(get_balance(&pool, provider).balance_credits, 140);
        // Consumed ticker advanced.
        let resolved = resolve_share_key(&pool, token).unwrap().unwrap();
        assert_eq!(resolved.consumed_credits, 200);
    }

    #[test]
    fn settle_share_key_caps_at_pool_remaining() {
        // Non-negative policy on the pool: if the settlement cost exceeds
        // what remains in the share-key pool, the debit caps at the pool's
        // remainder (earners paid proportionally, shortfall recorded).
        let pool = open_in_memory().unwrap();
        let issuer = "alice";
        let provider = "provider";
        for d in &[issuer, provider] {
            upsert_device(&pool, d).unwrap();
        }
        record_bonus(&pool, issuer, 1_000).unwrap();

        let minted = mint_share_key(&pool, issuer, None, 3600, 100).unwrap();
        // Pool = 100; cost = 500 — settle must cap at 100.
        settle_request(
            &pool,
            &ConsumerPrincipal::Share {
                issuer_device_id: issuer.to_string(),
                key_id: minted.key_id.clone(),
            },
            Some(provider),
            &[provider.to_string()],
            500,
            "reqY",
            "gemma",
        )
        .unwrap();

        // Issuer wallet untouched by settle (already debited at mint).
        assert_eq!(get_balance(&pool, issuer).balance_credits, 900);
        // Provider earned 70% of 100 (the capped amount).
        assert_eq!(get_balance(&pool, provider).balance_credits, 70);
        // Pool drained.
        let resolved = resolve_share_key(&pool, &minted.token).unwrap_err();
        assert_eq!(resolved, ShareKeyRejection::Exhausted);
    }

    #[test]
    fn revoke_share_key_blocks_resolve_and_refunds_unspent() {
        let pool = open_in_memory().unwrap();
        let issuer = "alice";
        upsert_device(&pool, issuer).unwrap();
        record_bonus(&pool, issuer, 100).unwrap();
        let minted = mint_share_key(&pool, issuer, None, 3600, 100).unwrap();
        // Mint transferred 100 into the pool.
        assert_eq!(get_balance(&pool, issuer).balance_credits, 0);

        assert!(resolve_share_key(&pool, &minted.token).unwrap().is_some());
        assert!(preview_share_key(&pool, &minted.token).is_some());

        assert!(revoke_share_key(&pool, issuer, &minted.key_id).unwrap());
        // Revoke refunded the full 100 back to the wallet (no spend occurred).
        assert_eq!(get_balance(&pool, issuer).balance_credits, 100);

        assert_eq!(
            resolve_share_key(&pool, &minted.token).unwrap_err(),
            ShareKeyRejection::Revoked,
        );
        assert!(preview_share_key(&pool, &minted.token).is_none());
        // Second revoke is a no-op.
        assert!(!revoke_share_key(&pool, issuer, &minted.key_id).unwrap());
        // Refund didn't duplicate.
        assert_eq!(get_balance(&pool, issuer).balance_credits, 100);
    }

    #[test]
    fn revoke_refund_after_partial_spend() {
        // After some spending, revoke refunds only the remainder.
        let pool = open_in_memory().unwrap();
        let issuer = "alice";
        let provider = "provider";
        upsert_device(&pool, issuer).unwrap();
        upsert_device(&pool, provider).unwrap();
        record_bonus(&pool, issuer, 1_000).unwrap();
        let minted = mint_share_key(&pool, issuer, None, 3600, 1_000).unwrap();
        assert_eq!(get_balance(&pool, issuer).balance_credits, 0);

        settle_request(
            &pool,
            &ConsumerPrincipal::Share {
                issuer_device_id: issuer.to_string(),
                key_id: minted.key_id.clone(),
            },
            Some(provider),
            &[provider.to_string()],
            300,
            "reqR",
            "gemma",
        )
        .unwrap();

        // Pool remainder = 700; revoke returns that much to the issuer.
        assert!(revoke_share_key(&pool, issuer, &minted.key_id).unwrap());
        assert_eq!(get_balance(&pool, issuer).balance_credits, 700);
    }

    #[test]
    fn revoke_share_key_scoped_to_issuer() {
        let pool = open_in_memory().unwrap();
        upsert_device(&pool, "alice").unwrap();
        upsert_device(&pool, "mallory").unwrap();
        record_bonus(&pool, "alice", 10).unwrap();
        let minted = mint_share_key(&pool, "alice", None, 3600, 10).unwrap();
        // Mallory can't revoke Alice's key.
        assert!(!revoke_share_key(&pool, "mallory", &minted.key_id).unwrap());
        assert!(resolve_share_key(&pool, &minted.token).unwrap().is_some());
    }

    #[test]
    fn expired_share_key_rejected() {
        let pool = open_in_memory().unwrap();
        let issuer = "alice";
        upsert_device(&pool, issuer).unwrap();

        // Insert an already-expired row directly (mint validates expires_in ≥ 60s).
        let now = unix_now();
        let key_id = "ki_expired";
        let token = "tok_share_expired";
        {
            let conn = pool.lock();
            conn.execute(
                "INSERT INTO share_keys
                 (key_id, token, issuer_device_id, label, expires_at,
                  budget_credits, consumed_credits, created_at, revoked_at)
                 VALUES (?, ?, ?, NULL, ?, ?, 0, ?, NULL)",
                params![key_id, token, issuer, now - 1, 100i64, now - 10],
            )
            .unwrap();
        }
        assert_eq!(
            resolve_share_key(&pool, token).unwrap_err(),
            ShareKeyRejection::Expired,
        );
    }

    #[test]
    fn exhausted_share_key_rejected() {
        let pool = open_in_memory().unwrap();
        upsert_device(&pool, "alice").unwrap();
        record_bonus(&pool, "alice", 50).unwrap();
        let minted = mint_share_key(&pool, "alice", None, 3600, 50).unwrap();
        {
            let conn = pool.lock();
            conn.execute(
                "UPDATE share_keys SET consumed_credits = budget_credits WHERE key_id = ?",
                [&minted.key_id],
            )
            .unwrap();
        }
        assert_eq!(
            resolve_share_key(&pool, &minted.token).unwrap_err(),
            ShareKeyRejection::Exhausted,
        );
    }

    #[test]
    fn list_share_keys_scopes_to_issuer() {
        let pool = open_in_memory().unwrap();
        upsert_device(&pool, "a").unwrap();
        upsert_device(&pool, "b").unwrap();
        record_bonus(&pool, "a", 30).unwrap();
        record_bonus(&pool, "b", 30).unwrap();
        mint_share_key(&pool, "a", Some("a-1"), 3600, 10).unwrap();
        mint_share_key(&pool, "a", Some("a-2"), 3600, 20).unwrap();
        mint_share_key(&pool, "b", Some("b-1"), 3600, 30).unwrap();

        let a_keys = list_share_keys(&pool, "a");
        assert_eq!(a_keys.len(), 2);
        assert!(a_keys.iter().all(|k| k.label.as_deref() != Some("b-1")));

        let b_keys = list_share_keys(&pool, "b");
        assert_eq!(b_keys.len(), 1);
        assert_eq!(b_keys[0].label.as_deref(), Some("b-1"));
    }

    #[test]
    fn mint_share_key_rejects_bad_bounds() {
        let pool = open_in_memory().unwrap();
        upsert_device(&pool, "a").unwrap();
        // Fund the issuer generously so the wallet-balance check doesn't
        // mask bound-validation errors we're actually testing.
        record_bonus(&pool, "a", 10_000).unwrap();
        assert!(
            mint_share_key(&pool, "a", None, 10, 100).is_err(),
            "too short TTL"
        );
        assert!(
            mint_share_key(&pool, "a", None, SHARE_KEY_MAX_EXPIRES_IN + 1, 100).is_err(),
            "too long TTL"
        );
        assert!(
            mint_share_key(&pool, "a", None, 3600, 0).is_err(),
            "zero budget"
        );
        assert!(
            mint_share_key(&pool, "a", None, 3600, SHARE_KEY_MAX_BUDGET + 1).is_err(),
            "over cap"
        );
        let over = "x".repeat(SHARE_KEY_MAX_LABEL_LEN + 1);
        assert!(
            mint_share_key(&pool, "a", Some(&over), 3600, 10).is_err(),
            "long label"
        );
    }

    #[test]
    fn preview_returns_issuer_display_name_when_set() {
        let pool = open_in_memory().unwrap();
        upsert_device(&pool, "a").unwrap();
        set_username(&pool, "a", "alice").unwrap();
        record_bonus(&pool, "a", 100).unwrap();
        let minted = mint_share_key(&pool, "a", Some("demo"), 3600, 100).unwrap();
        let preview = preview_share_key(&pool, &minted.token).unwrap();
        assert_eq!(preview.issuer_display_name.as_deref(), Some("alice"));
        assert_eq!(preview.label.as_deref(), Some("demo"));
        assert_eq!(preview.budget_credits, 100);
        assert_eq!(preview.consumed_credits, 0);
    }

    #[test]
    fn link_device_to_account_persists_summary() {
        let pool = open_in_memory().unwrap();
        upsert_device(&pool, "device-a").unwrap();

        link_device_to_account(
            &pool,
            "device-a",
            "user-123",
            &AccountLinkMetadata {
                device_name: Some("X1 Carbon".into()),
                platform: Some("windows".into()),
                display_name: Some("Taylor".into()),
                phone: Some("+15551234567".into()),
                email: None,
                github_username: Some("thou48".into()),
            },
        )
        .unwrap();

        let summary = account_summary_for_device(&pool, "device-a").unwrap();
        assert_eq!(summary.account_user_id, "user-123");
        assert_eq!(summary.display_name.as_deref(), Some("Taylor"));
        assert_eq!(summary.devices.len(), 1);
        assert_eq!(summary.devices[0].device_id, "device-a");
        assert_eq!(summary.devices[0].device_name.as_deref(), Some("X1 Carbon"));
    }

    #[test]
    fn sweep_moves_device_balance_into_account_wallet() {
        let pool = open_in_memory().unwrap();
        upsert_device(&pool, "device-a").unwrap();
        record_bonus(&pool, "device-a", 1_250).unwrap();
        link_device_to_account(
            &pool,
            "device-a",
            "user-123",
            &AccountLinkMetadata {
                device_name: Some("X1 Carbon".into()),
                platform: Some("windows".into()),
                ..Default::default()
            },
        )
        .unwrap();

        let swept = sweep_device_to_account(&pool, "device-a", "device-a").unwrap();
        assert_eq!(swept.swept_credits, 1_250);
        assert_eq!(get_balance(&pool, "device-a").balance_credits, 0);
        assert_eq!(swept.account.balance_credits, 1_250);
        assert_eq!(swept.account.transactions.len(), 1);
        assert_eq!(swept.account.transactions[0].type_, "SWEEP_IN");

        let device_entries = list_transactions(&pool, "device-a", 10);
        assert!(device_entries
            .iter()
            .any(|entry| entry.type_ == "ACCOUNT_SWEEP_OUT" && entry.amount == -1_250));
    }

    #[test]
    fn transfer_from_device_wallet_to_device_updates_only_balances() {
        let pool = open_in_memory().unwrap();
        upsert_device(&pool, "device-a").unwrap();
        upsert_device(&pool, "device-b").unwrap();
        record_bonus(&pool, "device-a", 500).unwrap();

        let receipt =
            transfer_from_device_wallet(&pool, "device-a", "device-b", 125, Some("team lunch"))
                .unwrap();
        assert_eq!(receipt.sender_kind, "device");
        assert_eq!(receipt.sender_balance_credits, 375);
        assert_eq!(receipt.recipient.kind, "device");
        assert_eq!(get_balance(&pool, "device-a").balance_credits, 375);
        assert_eq!(get_balance(&pool, "device-b").balance_credits, 125);
        assert_eq!(get_balance(&pool, "device-a").total_spent_credits, 0);
        assert_eq!(get_balance(&pool, "device-b").total_earned_credits, 0);

        let sender_entries = list_transactions(&pool, "device-a", 10);
        assert!(sender_entries
            .iter()
            .any(|entry| entry.type_ == "TRANSFER_OUT" && entry.amount == -125));
        let recipient_entries = list_transactions(&pool, "device-b", 10);
        assert!(recipient_entries
            .iter()
            .any(|entry| entry.type_ == "TRANSFER_IN" && entry.amount == 125));
    }

    #[test]
    fn transfer_from_device_wallet_to_account_identifier_credits_account_wallet() {
        let pool = open_in_memory().unwrap();
        upsert_device(&pool, "sender").unwrap();
        upsert_device(&pool, "recipient-device").unwrap();
        record_bonus(&pool, "sender", 400).unwrap();
        link_device_to_account(
            &pool,
            "recipient-device",
            "user-123",
            &AccountLinkMetadata {
                phone: Some("+1 (555) 123-4567".into()),
                email: Some("Taylor@example.com".into()),
                github_username: Some("@TaylorHou".into()),
                ..Default::default()
            },
        )
        .unwrap();

        let receipt =
            transfer_from_device_wallet(&pool, "sender", "taylor@example.com", 90, None).unwrap();
        assert_eq!(receipt.recipient.kind, "account");
        assert_eq!(
            receipt.recipient.account_user_id.as_deref(),
            Some("user-123")
        );
        assert_eq!(get_balance(&pool, "sender").balance_credits, 310);

        let summary = account_summary(&pool, "user-123").unwrap();
        assert_eq!(summary.balance_credits, 90);
        assert!(summary
            .transactions
            .iter()
            .any(|entry| entry.type_ == "TRANSFER_IN" && entry.amount == 90));
    }

    #[test]
    fn transfer_from_device_wallet_to_bare_account_wallet_id_credits_account_wallet() {
        let pool = open_in_memory().unwrap();
        upsert_device(&pool, "sender").unwrap();
        upsert_device(&pool, "recipient-device").unwrap();
        record_bonus(&pool, "sender", 400).unwrap();
        link_device_to_account(
            &pool,
            "recipient-device",
            "270E90AF-4661-4DF1-949B-1A0BA1F705EE",
            &AccountLinkMetadata {
                email: Some("account@example.com".into()),
                ..Default::default()
            },
        )
        .unwrap();

        let receipt = transfer_from_device_wallet(
            &pool,
            "sender",
            "270E90AF-4661-4DF1-949B-1A0BA1F705EE",
            90,
            Some("alms from thou32"),
        )
        .unwrap();
        assert_eq!(receipt.recipient.kind, "account");
        assert_eq!(
            receipt.recipient.account_user_id.as_deref(),
            Some("270E90AF-4661-4DF1-949B-1A0BA1F705EE")
        );
        assert_eq!(get_balance(&pool, "sender").balance_credits, 310);

        let summary = account_summary(&pool, "270E90AF-4661-4DF1-949B-1A0BA1F705EE").unwrap();
        assert_eq!(summary.balance_credits, 90);
        assert!(summary
            .transactions
            .iter()
            .any(|entry| entry.type_ == "TRANSFER_IN" && entry.amount == 90));
    }

    #[test]
    fn transfer_from_account_wallet_to_device_debits_account_balance() {
        let pool = open_in_memory().unwrap();
        upsert_device(&pool, "sender-device").unwrap();
        upsert_device(&pool, "recipient-device").unwrap();
        record_bonus(&pool, "sender-device", 300).unwrap();
        link_device_to_account(
            &pool,
            "sender-device",
            "sender-account",
            &AccountLinkMetadata {
                email: Some("sender@example.com".into()),
                ..Default::default()
            },
        )
        .unwrap();
        sweep_device_to_account(&pool, "sender-device", "sender-device").unwrap();

        let receipt = transfer_from_account_wallet(
            &pool,
            "sender-device",
            "recipient-device",
            120,
            Some("bonus"),
        )
        .unwrap();
        assert_eq!(receipt.sender_kind, "account");
        assert_eq!(receipt.sender_id, "sender-account");
        assert_eq!(receipt.sender_balance_credits, 180);
        assert_eq!(get_balance(&pool, "recipient-device").balance_credits, 120);

        let account = account_summary(&pool, "sender-account").unwrap();
        assert_eq!(account.balance_credits, 180);
        assert!(account
            .transactions
            .iter()
            .any(|entry| entry.type_ == "TRANSFER_OUT" && entry.amount == -120));
    }

    #[test]
    fn account_api_keys_are_revocable_and_track_last_use() {
        let pool = open_in_memory().unwrap();
        upsert_device(&pool, "device-a").unwrap();
        link_device_to_account(
            &pool,
            "device-a",
            "user-123",
            &AccountLinkMetadata {
                display_name: Some("Taylor".into()),
                ..Default::default()
            },
        )
        .unwrap();

        let minted = mint_account_api_key(&pool, "user-123", Some("CLI")).unwrap();
        assert!(minted.key_id.starts_with("ak_"));
        assert!(minted.token.starts_with("tok_acct_"));
        assert_eq!(minted.label.as_deref(), Some("CLI"));

        let keys = list_account_api_keys(&pool, "user-123").unwrap();
        assert_eq!(keys.len(), 1);
        assert_eq!(keys[0].key_id, minted.key_id);
        assert_eq!(keys[0].label.as_deref(), Some("CLI"));
        assert!(keys[0].token_preview.starts_with("tok_acct_"));
        assert!(keys[0].last_used_at.is_none());
        assert!(keys[0].revoked_at.is_none());

        let resolved = resolve_account_api_key(&pool, &minted.token)
            .unwrap()
            .expect("account API key resolves");
        assert_eq!(resolved.key_id, minted.key_id);
        assert_eq!(resolved.account_user_id, "user-123");

        let keys = list_account_api_keys(&pool, "user-123").unwrap();
        assert!(keys[0].last_used_at.is_some());

        assert!(revoke_account_api_key(&pool, "user-123", &minted.key_id).unwrap());
        assert!(resolve_account_api_key(&pool, &minted.token)
            .unwrap()
            .is_none());
        assert!(!revoke_account_api_key(&pool, "user-123", &minted.key_id).unwrap());
    }

    #[test]
    fn account_principal_settlement_debits_account_wallet() {
        let pool = open_in_memory().unwrap();
        let owner_device = "owner-device";
        let provider = "provider";
        let peer = "peer";
        for device_id in &[owner_device, provider, peer] {
            upsert_device(&pool, device_id).unwrap();
        }
        record_bonus(&pool, owner_device, 300).unwrap();
        link_device_to_account(
            &pool,
            owner_device,
            "user-123",
            &AccountLinkMetadata {
                email: Some("taylor@example.com".into()),
                ..Default::default()
            },
        )
        .unwrap();
        sweep_device_to_account(&pool, owner_device, owner_device).unwrap();

        settle_request(
            &pool,
            &ConsumerPrincipal::Account {
                account_user_id: "user-123".into(),
            },
            Some(provider),
            &[provider.to_string(), peer.to_string()],
            200,
            "req-account",
            "qwen/qwen3.6-27b",
        )
        .unwrap();

        assert_eq!(account_balance_credits(&pool, "user-123"), 100);
        assert_eq!(get_balance(&pool, owner_device).balance_credits, 0);
        assert_eq!(get_balance(&pool, provider).balance_credits, 140);
        assert!(get_balance(&pool, peer).balance_credits > 0);

        let account = account_summary(&pool, "user-123").unwrap();
        assert!(account
            .transactions
            .iter()
            .any(|entry| entry.type_ == "INFERENCE_SPENT" && entry.amount == -200));
    }

    #[test]
    fn remove_device_detaches_only_target_row() {
        let pool = open_in_memory().unwrap();
        for device_id in &["device-a", "device-b"] {
            upsert_device(&pool, device_id).unwrap();
            link_device_to_account(
                &pool,
                device_id,
                "user-123",
                &AccountLinkMetadata {
                    device_name: Some(device_id.to_string()),
                    platform: Some("windows".into()),
                    ..Default::default()
                },
            )
            .unwrap();
        }

        let summary = remove_device_from_account(&pool, "device-a", "device-b").unwrap();
        assert_eq!(summary.devices.len(), 1);
        assert_eq!(summary.devices[0].device_id, "device-a");
        assert!(account_summary_for_device(&pool, "device-b").is_err());
    }

    // ── admin_mint ────────────────────────────────────────────────────────

    #[test]
    fn admin_mint_credits_wallet_and_debits_mint_pool() {
        let pool = open_in_memory().unwrap();
        let dev = "dev1";
        let bal = admin_mint(&pool, dev, 50_000_000, "manual top-up").unwrap();
        assert_eq!(bal, 50_000_000);
        let snap = get_balance(&pool, dev);
        assert_eq!(snap.balance_credits, 50_000_000);
        assert_eq!(snap.total_earned_credits, 50_000_000);
        // Ledger entry is of type ADMIN_MINT.
        let entries = list_transactions(&pool, dev, 5);
        assert!(entries.iter().any(|e| e.type_ == "ADMIN_MINT"));
    }

    #[test]
    fn admin_mint_rejects_non_positive() {
        let pool = open_in_memory().unwrap();
        assert!(admin_mint(&pool, "d", 0, "").is_err());
        assert!(admin_mint(&pool, "d", -1, "").is_err());
    }

    // ── Retroactive share-key funding migration ───────────────────────────

    #[test]
    fn migrate_unfunded_share_keys_retroactively_debits_issuer() {
        let pool = open_in_memory().unwrap();
        let issuer = "alice";
        upsert_device(&pool, issuer).unwrap();
        record_bonus(&pool, issuer, 1_000).unwrap();

        // Simulate an OLD (pre-refactor) share key: funded=0, issuer wallet
        // never debited at mint.
        let now = unix_now();
        {
            let conn = pool.lock();
            conn.execute(
                "INSERT INTO share_keys
                 (key_id, token, issuer_device_id, label, expires_at,
                  budget_credits, consumed_credits, created_at, revoked_at, funded)
                 VALUES (?, ?, ?, NULL, ?, ?, ?, ?, NULL, 0)",
                params![
                    "ki1",
                    "tok_share_old1",
                    issuer,
                    now + 3600,
                    400i64,
                    100i64,
                    now
                ],
            )
            .unwrap();
        }

        let report = migrate_unfunded_share_keys(&pool).unwrap();
        assert_eq!(report.funded_fully, 1);
        assert_eq!(report.funded_partially, 0);
        assert_eq!(report.total_debited_credits, 300); // budget 400 - consumed 100
                                                       // Issuer debited by owed amount.
        assert_eq!(get_balance(&pool, issuer).balance_credits, 700);

        // Idempotent: running again is a no-op.
        let again = migrate_unfunded_share_keys(&pool).unwrap();
        assert_eq!(
            again.funded_fully + again.funded_partially + again.skipped_revoked,
            0
        );
        assert_eq!(get_balance(&pool, issuer).balance_credits, 700);
    }

    #[test]
    fn migrate_shrinks_budget_when_issuer_cant_cover() {
        let pool = open_in_memory().unwrap();
        let issuer = "alice";
        upsert_device(&pool, issuer).unwrap();
        record_bonus(&pool, issuer, 50).unwrap();

        let now = unix_now();
        {
            let conn = pool.lock();
            conn.execute(
                "INSERT INTO share_keys
                 (key_id, token, issuer_device_id, label, expires_at,
                  budget_credits, consumed_credits, created_at, revoked_at, funded)
                 VALUES (?, ?, ?, NULL, ?, ?, ?, ?, NULL, 0)",
                params![
                    "ki2",
                    "tok_share_old2",
                    issuer,
                    now + 3600,
                    1_000i64,
                    10i64,
                    now
                ],
            )
            .unwrap();
        }

        let report = migrate_unfunded_share_keys(&pool).unwrap();
        assert_eq!(report.funded_partially, 1);
        assert_eq!(report.total_debited_credits, 50);
        // Shrunk by (owed 990) - (debit 50) = 940.
        assert_eq!(report.total_shrunk_credits, 940);
        // Issuer drained to 0; pool budget reduced to consumed+50 = 60.
        assert_eq!(get_balance(&pool, issuer).balance_credits, 0);
        let resolved = resolve_share_key(&pool, "tok_share_old2").unwrap().unwrap();
        assert_eq!(resolved.budget_credits, 60);
        assert_eq!(resolved.remaining(), 50);
    }

    #[test]
    fn migrate_skips_revoked_and_expired_keys() {
        let pool = open_in_memory().unwrap();
        let issuer = "alice";
        upsert_device(&pool, issuer).unwrap();
        record_bonus(&pool, issuer, 1_000).unwrap();
        let before = get_balance(&pool, issuer).balance_credits;

        let now = unix_now();
        {
            let conn = pool.lock();
            // Revoked — funded=0 but should be skipped (no debit).
            conn.execute(
                "INSERT INTO share_keys
                 (key_id, token, issuer_device_id, label, expires_at,
                  budget_credits, consumed_credits, created_at, revoked_at, funded)
                 VALUES (?, ?, ?, NULL, ?, ?, 0, ?, ?, 0)",
                params![
                    "kr",
                    "tok_share_rev",
                    issuer,
                    now + 3600,
                    500i64,
                    now,
                    now - 1
                ],
            )
            .unwrap();
            // Already-expired.
            conn.execute(
                "INSERT INTO share_keys
                 (key_id, token, issuer_device_id, label, expires_at,
                  budget_credits, consumed_credits, created_at, revoked_at, funded)
                 VALUES (?, ?, ?, NULL, ?, ?, 0, ?, NULL, 0)",
                params!["ke", "tok_share_exp", issuer, now - 1, 500i64, now - 10],
            )
            .unwrap();
        }

        let report = migrate_unfunded_share_keys(&pool).unwrap();
        assert_eq!(report.skipped_revoked, 2);
        assert_eq!(report.total_debited_credits, 0);
        // Issuer balance unchanged.
        assert_eq!(get_balance(&pool, issuer).balance_credits, before);
    }

    type ContributionRow = (String, i64, i64, Option<i64>, Option<String>);

    fn contribution_rows(pool: &DbPool, key_id: &str) -> Vec<ContributionRow> {
        let conn = pool.lock();
        let mut stmt = conn
            .prepare(
                "SELECT funder_device_id, funded_credits, remaining_credits, refunded_at, refund_reason
                 FROM share_key_contributions
                 WHERE key_id = ?
                 ORDER BY created_at ASC, contribution_id ASC",
            )
            .unwrap();
        stmt.query_map([key_id], |r| {
            Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?, r.get(4)?))
        })
        .unwrap()
        .collect::<Result<Vec<_>, _>>()
        .unwrap()
    }

    #[test]
    fn mint_share_key_creates_funding_id_and_initial_contribution() {
        let pool = open_in_memory().unwrap();
        upsert_device(&pool, "issuer").unwrap();
        record_bonus(&pool, "issuer", 250).unwrap();

        let minted = mint_share_key(&pool, "issuer", Some("demo"), 3600, 250).unwrap();
        assert!(minted.funding_id.starts_with("skf_"));

        let rows = contribution_rows(&pool, &minted.key_id);
        assert_eq!(rows.len(), 1);
        assert_eq!(rows[0].0, "issuer");
        assert_eq!(rows[0].1, 250);
        assert_eq!(rows[0].2, 250);

        let listed = list_share_keys(&pool, "issuer");
        assert_eq!(listed[0].funding_id, minted.funding_id);
        assert_eq!(listed[0].remaining_credits, 250);
    }

    #[test]
    fn transfer_to_share_key_adds_a_new_contribution() {
        let pool = open_in_memory().unwrap();
        for device in &["issuer", "donor"] {
            upsert_device(&pool, device).unwrap();
        }
        record_bonus(&pool, "issuer", 100).unwrap();
        record_bonus(&pool, "donor", 75).unwrap();

        let minted = mint_share_key(&pool, "issuer", None, 3600, 100).unwrap();
        let receipt = transfer_to_share_key(&pool, "donor", &minted.funding_id, 75).unwrap();

        assert_eq!(receipt.budget_credits, 175);
        assert_eq!(receipt.remaining_credits, 175);
        assert_eq!(receipt.sender_balance_credits, 0);

        let rows = contribution_rows(&pool, &minted.key_id);
        assert_eq!(rows.len(), 2);
        assert!(rows
            .iter()
            .any(|row| row.0 == "issuer" && row.1 == 100 && row.2 == 100));
        assert!(rows
            .iter()
            .any(|row| row.0 == "donor" && row.1 == 75 && row.2 == 75));
    }

    #[test]
    fn transfer_to_share_key_rejects_insufficient_balance_without_mutation() {
        let pool = open_in_memory().unwrap();
        for device in &["issuer", "donor"] {
            upsert_device(&pool, device).unwrap();
        }
        record_bonus(&pool, "issuer", 100).unwrap();
        record_bonus(&pool, "donor", 10).unwrap();

        let minted = mint_share_key(&pool, "issuer", None, 3600, 100).unwrap();
        let err = transfer_to_share_key(&pool, "donor", &minted.funding_id, 50).unwrap_err();
        assert_eq!(
            err,
            FundShareKeyError::InsufficientBalance {
                balance: 10,
                required: 50,
            }
        );

        assert_eq!(get_balance(&pool, "donor").balance_credits, 10);
        let rows = contribution_rows(&pool, &minted.key_id);
        assert_eq!(rows.len(), 1);
        assert_eq!(rows[0].2, 100);
    }

    #[test]
    fn pro_rata_spend_uses_largest_remainder_with_oldest_tiebreak() {
        let pool = open_in_memory().unwrap();
        for device in &["issuer", "donor"] {
            upsert_device(&pool, device).unwrap();
        }
        record_bonus(&pool, "issuer", 100).unwrap();
        record_bonus(&pool, "donor", 100).unwrap();

        let minted = mint_share_key(&pool, "issuer", None, 3600, 100).unwrap();
        transfer_to_share_key(&pool, "donor", &minted.funding_id, 100).unwrap();
        {
            let conn = pool.lock();
            conn.execute(
                "UPDATE share_key_contributions
                 SET created_at = created_at + 1
                 WHERE key_id = ? AND funder_device_id = 'donor'",
                params![&minted.key_id],
            )
            .unwrap();
        }

        let mut conn = pool.lock();
        let tx = conn.transaction().unwrap();
        apply_pro_rata_share_key_spend_tx(&tx, &minted.key_id, 1).unwrap();
        tx.commit().unwrap();
        drop(conn);

        let rows = contribution_rows(&pool, &minted.key_id);
        assert_eq!(rows[0].0, "issuer");
        assert_eq!(rows[0].2, 99);
        assert_eq!(rows[1].0, "donor");
        assert_eq!(rows[1].2, 100);
    }

    #[test]
    fn revoke_refunds_each_funder_not_just_the_issuer() {
        let pool = open_in_memory().unwrap();
        for device in &["issuer", "donor", "provider"] {
            upsert_device(&pool, device).unwrap();
        }
        record_bonus(&pool, "issuer", 100).unwrap();
        record_bonus(&pool, "donor", 100).unwrap();

        let minted = mint_share_key(&pool, "issuer", None, 3600, 100).unwrap();
        transfer_to_share_key(&pool, "donor", &minted.funding_id, 100).unwrap();
        settle_request(
            &pool,
            &ConsumerPrincipal::Share {
                issuer_device_id: "issuer".into(),
                key_id: minted.key_id.clone(),
            },
            Some("provider"),
            &["provider".into()],
            60,
            "req-refund",
            "gemma",
        )
        .unwrap();

        assert!(revoke_share_key(&pool, "issuer", &minted.key_id).unwrap());
        assert_eq!(get_balance(&pool, "issuer").balance_credits, 70);
        assert_eq!(get_balance(&pool, "donor").balance_credits, 70);

        let rows = contribution_rows(&pool, &minted.key_id);
        assert_eq!(rows[0].2, 0);
        assert_eq!(rows[1].2, 0);
        assert_eq!(rows[0].4.as_deref(), Some("revoked"));
        assert_eq!(rows[1].4.as_deref(), Some("revoked"));
    }

    #[test]
    fn refund_expired_share_keys_is_idempotent() {
        let pool = open_in_memory().unwrap();
        for device in &["issuer", "donor"] {
            upsert_device(&pool, device).unwrap();
        }
        record_bonus(&pool, "issuer", 100).unwrap();
        record_bonus(&pool, "donor", 40).unwrap();

        let minted = mint_share_key(&pool, "issuer", None, 3600, 100).unwrap();
        transfer_to_share_key(&pool, "donor", &minted.funding_id, 40).unwrap();
        {
            let conn = pool.lock();
            conn.execute(
                "UPDATE share_keys SET expires_at = ? WHERE key_id = ?",
                params![unix_now() - 1, &minted.key_id],
            )
            .unwrap();
        }

        let report = refund_expired_share_keys(&pool).unwrap();
        assert_eq!(report.keys_closed, 1);
        assert_eq!(report.contributions_refunded, 2);
        assert_eq!(report.credits_refunded, 140);
        assert_eq!(get_balance(&pool, "issuer").balance_credits, 100);
        assert_eq!(get_balance(&pool, "donor").balance_credits, 40);

        let again = refund_expired_share_keys(&pool).unwrap();
        assert_eq!(again, ExpiredShareKeyRefundReport::default());
    }

    #[test]
    fn backfill_funded_share_keys_adds_funding_id_and_contribution() {
        let pool = open_in_memory().unwrap();
        let issuer = "issuer";
        upsert_device(&pool, issuer).unwrap();
        let now = unix_now();
        {
            let conn = pool.lock();
            conn.execute(
                "INSERT INTO share_keys
                 (key_id, token, issuer_device_id, label, expires_at, budget_credits,
                  consumed_credits, created_at, revoked_at, funded, funding_id, refunds_settled_at)
                 VALUES (?, ?, ?, NULL, ?, ?, ?, ?, NULL, 1, NULL, NULL)",
                params![
                    "kb1",
                    "tok_share_backfill",
                    issuer,
                    now + 3600,
                    100i64,
                    30i64,
                    now
                ],
            )
            .unwrap();
        }

        let report = backfill_funded_share_key_contributions(&pool).unwrap();
        assert_eq!(report.keys_backfilled, 1);
        assert_eq!(report.funding_ids_backfilled, 1);
        let listed = list_share_keys(&pool, issuer);
        assert_eq!(listed[0].remaining_credits, 70);
        assert!(listed[0].funding_id.starts_with("skf_"));
        let rows = contribution_rows(&pool, "kb1");
        assert_eq!(rows.len(), 1);
        assert_eq!(rows[0].2, 70);
    }

    #[test]
    fn migrate_unfunded_share_keys_creates_contribution_rows() {
        let pool = open_in_memory().unwrap();
        let issuer = "issuer";
        upsert_device(&pool, issuer).unwrap();
        record_bonus(&pool, issuer, 500).unwrap();
        let now = unix_now();
        {
            let conn = pool.lock();
            conn.execute(
                "INSERT INTO share_keys
                 (key_id, token, issuer_device_id, label, expires_at, budget_credits,
                  consumed_credits, created_at, revoked_at, funded, funding_id, refunds_settled_at)
                 VALUES (?, ?, ?, NULL, ?, ?, ?, ?, NULL, 0, NULL, NULL)",
                params![
                    "km1",
                    "tok_share_migrate",
                    issuer,
                    now + 3600,
                    400i64,
                    100i64,
                    now
                ],
            )
            .unwrap();
        }

        let report = migrate_unfunded_share_keys(&pool).unwrap();
        assert_eq!(report.funded_fully, 1);
        let listed = list_share_keys(&pool, issuer);
        assert_eq!(listed[0].remaining_credits, 300);
        assert!(listed[0].funding_id.starts_with("skf_"));
        let rows = contribution_rows(&pool, "km1");
        assert_eq!(rows.len(), 1);
        assert_eq!(rows[0].1, 300);
        assert_eq!(rows[0].2, 300);
    }
}
