//! Teale Credit ledger operations.
//!
//! The gateway is the source of truth for balances. All credit flows
//! (bonus, direct earn, availability earn, availability drip, spent, ops fee)
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
pub const DRIP_INTERVAL_SECS: u64 = 10;
pub const HERMES_REFERENCE_PROMPT_PRICE_USD: f64 = 0.00000010;
pub const HERMES_REFERENCE_COMPLETION_PRICE_USD: f64 = 0.00000020;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DripRecipient {
    pub device_id: String,
    pub credits: i64,
    pub note: Option<String>,
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "SCREAMING_SNAKE_CASE")]
pub enum LedgerType {
    Bonus,
    DirectEarn,
    AvailabilityEarn,
    AvailabilityDrip,
    Spent,
    OpsFee,
}

impl LedgerType {
    pub fn as_str(&self) -> &'static str {
        match self {
            LedgerType::Bonus => "BONUS",
            LedgerType::DirectEarn => "DIRECT_EARN",
            LedgerType::AvailabilityEarn => "AVAILABILITY_EARN",
            LedgerType::AvailabilityDrip => "AVAILABILITY_DRIP",
            LedgerType::Spent => "SPENT",
            LedgerType::OpsFee => "OPS_FEE",
        }
    }
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
/// share key minted by a device — in that case the ledger debits the
/// **issuer** and the key's `consumed_credits` is incremented.
#[derive(Debug, Clone)]
pub enum ConsumerPrincipal {
    Device(String),
    Share {
        issuer_device_id: String,
        key_id: String,
    },
}

impl ConsumerPrincipal {
    /// Device ID whose balance is debited for this spend.
    pub fn paying_device_id(&self) -> &str {
        match self {
            Self::Device(d) => d,
            Self::Share {
                issuer_device_id, ..
            } => issuer_device_id,
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
    pub label: Option<String>,
    #[serde(rename = "budgetCredits")]
    pub budget_credits: i64,
    #[serde(rename = "consumedCredits")]
    pub consumed_credits: i64,
    #[serde(rename = "expiresAt")]
    pub expires_at: i64,
    #[serde(rename = "createdAt")]
    pub created_at: i64,
    #[serde(rename = "revokedAt", skip_serializing_if = "Option::is_none")]
    pub revoked_at: Option<i64>,
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
    let conn = pool.lock();
    let mut stmt = match conn.prepare(
        "SELECT id, device_id, type, amount, timestamp, ref_request_id, note
         FROM ledger WHERE device_id = ? ORDER BY timestamp DESC LIMIT ?",
    ) {
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

pub fn link_device_to_account(
    pool: &DbPool,
    device_id: &str,
    account_user_id: &str,
    metadata: &AccountLinkMetadata,
) -> anyhow::Result<()> {
    let mut conn = pool.lock();
    let now = unix_now();
    let tx = conn.transaction()?;
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
            metadata.phone.as_deref(),
            metadata.email.as_deref(),
            metadata.github_username.as_deref(),
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

pub fn account_user_id_for_device(pool: &DbPool, device_id: &str) -> Option<String> {
    let conn = pool.lock();
    conn.query_row(
        "SELECT account_user_id FROM account_devices WHERE device_id = ?",
        [device_id],
        |r| r.get(0),
    )
    .ok()
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
///   - consumer SPENT (negative) — debited from the paying device (issuer for share-key spends)
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

    // Probe consumer balance under the transaction lock so we see a consistent
    // view and can bound the payout to what's actually paid.
    tx.execute(
        "INSERT OR IGNORE INTO balances (device_id) VALUES (?)",
        [paying_device_id],
    )?;
    let consumer_balance: i64 = tx
        .query_row(
            "SELECT balance FROM balances WHERE device_id = ?",
            [paying_device_id],
            |r| r.get(0),
        )
        .unwrap_or(0);
    let effective_cost = cost.min(consumer_balance.max(0));
    let shortfall = cost - effective_cost;

    // Split the effective (actually-payable) amount 70/25/5.
    let direct_earn = effective_cost * 70 / 100;
    let pool_share = effective_cost * 25 / 100;
    let ops_fee = effective_cost - direct_earn - pool_share;

    // Filter provider + paying device out of availability recipients.
    let recipients: Vec<&String> = online_device_ids
        .iter()
        .filter(|d| Some(d.as_str()) != provider_device_id && *d != paying_device_id)
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
        ConsumerPrincipal::Share { key_id, .. } => {
            format!("share_key:{} model={}", key_id, model)
        }
    };
    let note = if shortfall > 0 {
        format!("{} shortfall={}", note_base, shortfall)
    } else {
        note_base
    };

    // Consumer SPENT — capped at available balance so the debit never drives
    // the balance negative. We always record the row (even if effective_cost
    // is 0) so the request is attributable in wallet history.
    tx.execute(
        "INSERT INTO ledger (device_id, type, amount, timestamp, ref_request_id, note)
         VALUES (?, 'SPENT', ?, ?, ?, ?)",
        params![paying_device_id, -effective_cost, now, request_id, &note],
    )?;
    if effective_cost > 0 {
        tx.execute(
            "UPDATE balances SET balance = balance - ?, total_spent = total_spent + ?
             WHERE device_id = ?",
            params![effective_cost, effective_cost, paying_device_id],
        )?;
    }

    // Share-key: atomically bump consumed_credits so budget checks see spend.
    // We bump by effective_cost (what was actually paid) to stay consistent
    // with the SPENT amount and keep the budget from being "consumed" for
    // credits that never moved.
    if let ConsumerPrincipal::Share { key_id, .. } = consumer {
        if effective_cost > 0 {
            tx.execute(
                "UPDATE share_keys SET consumed_credits = consumed_credits + ?
                 WHERE key_id = ?",
                params![effective_cost, key_id],
            )?;
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

/// Mint a drip payout to every online device. Debits the mint_pool and records
/// AVAILABILITY_DRIP entries.
pub fn run_drip(pool: &DbPool, recipients: &[DripRecipient]) -> anyhow::Result<usize> {
    if recipients.is_empty() {
        return Ok(0);
    }
    let mut conn = pool.lock();
    let now = unix_now();
    let tx = conn.transaction()?;

    let remaining: i64 = tx.query_row("SELECT remaining FROM mint_pool WHERE id = 1", [], |r| {
        r.get(0)
    })?;
    let total_needed: i64 = recipients
        .iter()
        .map(|recipient| recipient.credits.max(0))
        .sum();
    if remaining < total_needed {
        tracing::warn!(
            "mint_pool remaining ({}) < drip amount ({}), skipping",
            remaining,
            total_needed
        );
        tx.rollback()?;
        return Ok(0);
    }
    tx.execute(
        "UPDATE mint_pool SET remaining = remaining - ? WHERE id = 1",
        params![total_needed],
    )?;

    for recipient in recipients {
        let note = recipient.note.as_deref().unwrap_or("drip tick");
        tx.execute(
            "INSERT OR IGNORE INTO balances (device_id) VALUES (?)",
            [recipient.device_id.as_str()],
        )?;
        tx.execute(
            "INSERT INTO ledger (device_id, type, amount, timestamp, note)
             VALUES (?, 'AVAILABILITY_DRIP', ?, ?, ?)",
            params![recipient.device_id.as_str(), recipient.credits, now, note],
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
    }
    tx.commit()?;
    Ok(recipients.len())
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
            if recipients.is_empty() {
                continue;
            }
            match run_drip(&pool, &recipients) {
                Ok(n) => {
                    if n > 0 {
                        tracing::debug!("drip tick: credited {} online devices", n);
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
// The key's budget caps inference spend; usage is debited from the issuer's
// wallet while `share_keys.consumed_credits` ticks up in the same transaction
// as the ledger SPENT entry (see `settle_request`).

/// Mint a share key. Validates bounds and enforces the per-issuer active cap.
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

    let key_id = uuid::Uuid::new_v4().simple().to_string();
    let token = format!("tok_share_{}", uuid::Uuid::new_v4().simple());
    let expires_at = now + expires_in_seconds;

    tx.execute(
        "INSERT INTO share_keys
         (key_id, token, issuer_device_id, label, expires_at, budget_credits,
          consumed_credits, created_at, revoked_at)
         VALUES (?, ?, ?, ?, ?, ?, 0, ?, NULL)",
        params![
            &key_id,
            &token,
            issuer_device_id,
            normalized_label,
            expires_at,
            budget_credits,
            now,
        ],
    )?;
    tx.commit()?;

    Ok(ShareKeyMinted {
        key_id,
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
        "SELECT key_id, label, budget_credits, consumed_credits, expires_at,
                created_at, revoked_at
         FROM share_keys WHERE issuer_device_id = ?
         ORDER BY created_at DESC",
    ) {
        Ok(s) => s,
        Err(_) => return vec![],
    };
    stmt.query_map([issuer_device_id], |r| {
        Ok(ShareKeyPublic {
            key_id: r.get(0)?,
            label: r.get(1)?,
            budget_credits: r.get(2)?,
            consumed_credits: r.get(3)?,
            expires_at: r.get(4)?,
            created_at: r.get(5)?,
            revoked_at: r.get(6)?,
        })
    })
    .ok()
    .map(|iter| iter.filter_map(|r| r.ok()).collect())
    .unwrap_or_default()
}

/// Soft-revoke a key. Returns `true` if a row was updated (key belongs to issuer,
/// not already revoked), `false` if no matching row was found.
pub fn revoke_share_key(
    pool: &DbPool,
    issuer_device_id: &str,
    key_id: &str,
) -> anyhow::Result<bool> {
    let conn = pool.lock();
    let now = unix_now();
    let n = conn.execute(
        "UPDATE share_keys
            SET revoked_at = ?
          WHERE key_id = ? AND issuer_device_id = ? AND revoked_at IS NULL",
        params![now, key_id, issuer_device_id],
    )?;
    Ok(n > 0)
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

    #[test]
    fn drip_credits_online_devices() {
        let pool = open_in_memory().unwrap();
        upsert_device(&pool, "a").unwrap();
        upsert_device(&pool, "b").unwrap();
        run_drip(
            &pool,
            &[
                DripRecipient {
                    device_id: "a".into(),
                    credits: 1,
                    note: Some("drip tick // model=nousresearch/hermes-3-llama-3.1-8b".into()),
                },
                DripRecipient {
                    device_id: "b".into(),
                    credits: 4,
                    note: Some(
                        "drip tick // model=mistralai/mistral-small-3.2-24b-instruct".into(),
                    ),
                },
            ],
        )
        .unwrap();
        assert_eq!(get_balance(&pool, "a").balance_credits, 1);
        assert_eq!(get_balance(&pool, "b").balance_credits, 4);

        let entries = list_transactions(&pool, "b", 1);
        assert!(entries[0]
            .note
            .as_deref()
            .is_some_and(|note| note.contains("mistralai/mistral-small-3.2-24b-instruct")));
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

        let minted = mint_share_key(&pool, issuer, Some("demo"), 3600, 500).unwrap();
        assert!(minted.token.starts_with("tok_share_"));
        assert_eq!(minted.budget_credits, 500);
        assert_eq!(minted.label.as_deref(), Some("demo"));

        let resolved = resolve_share_key(&pool, &minted.token).unwrap().unwrap();
        assert_eq!(resolved.key_id, minted.key_id);
        assert_eq!(resolved.issuer_device_id, issuer);
        assert_eq!(resolved.budget_credits, 500);
        assert_eq!(resolved.consumed_credits, 0);
        assert_eq!(resolved.remaining(), 500);
    }

    #[test]
    fn settle_share_key_debits_issuer_and_bumps_consumed() {
        let pool = open_in_memory().unwrap();
        let issuer = "alice";
        let provider = "provider";
        let peer = "peer1";
        for d in &[issuer, provider, peer] {
            upsert_device(&pool, d).unwrap();
        }
        record_bonus(&pool, issuer, 10_000).unwrap();

        let minted = mint_share_key(&pool, issuer, None, 3600, 1_000).unwrap();
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

        // Issuer dropped by 100.
        assert_eq!(get_balance(&pool, issuer).balance_credits, 10_000 - 100);
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
    fn settle_share_key_rejects_when_issuer_insufficient() {
        // Non-negative policy: if the share-key issuer can't cover the
        // spend, the settlement caps the debit at the issuer's balance
        // (zero, here) and earners get nothing beyond what the issuer paid.
        // The consumed_credits ticker only advances by what was actually
        // debited so the share-key isn't "used up" by phantom spend.
        let pool = open_in_memory().unwrap();
        let issuer = "alice_poor";
        let provider = "provider";
        upsert_device(&pool, issuer).unwrap();
        upsert_device(&pool, provider).unwrap();

        let minted = mint_share_key(&pool, issuer, None, 3600, 1_000).unwrap();
        // No bonus — issuer balance starts at 0. If settlement ran, the
        // shortfall guard should pin everything to zero.
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

        // Non-negative invariant: issuer never goes below zero.
        assert_eq!(get_balance(&pool, issuer).balance_credits, 0);
        // Provider earns nothing since nothing was paid.
        assert_eq!(get_balance(&pool, provider).balance_credits, 0);
        // consumed_credits didn't advance — key still has its full budget.
        let resolved = resolve_share_key(&pool, &minted.token).unwrap().unwrap();
        assert_eq!(resolved.consumed_credits, 0);
        assert_eq!(resolved.remaining(), 1_000);
    }

    #[test]
    fn revoke_share_key_blocks_resolve_and_preview() {
        let pool = open_in_memory().unwrap();
        let issuer = "alice";
        upsert_device(&pool, issuer).unwrap();
        let minted = mint_share_key(&pool, issuer, None, 3600, 100).unwrap();

        assert!(resolve_share_key(&pool, &minted.token).unwrap().is_some());
        assert!(preview_share_key(&pool, &minted.token).is_some());

        assert!(revoke_share_key(&pool, issuer, &minted.key_id).unwrap());

        assert_eq!(
            resolve_share_key(&pool, &minted.token).unwrap_err(),
            ShareKeyRejection::Revoked,
        );
        assert!(preview_share_key(&pool, &minted.token).is_none());
        // Second revoke is a no-op.
        assert!(!revoke_share_key(&pool, issuer, &minted.key_id).unwrap());
    }

    #[test]
    fn revoke_share_key_scoped_to_issuer() {
        let pool = open_in_memory().unwrap();
        upsert_device(&pool, "alice").unwrap();
        upsert_device(&pool, "mallory").unwrap();
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
}
