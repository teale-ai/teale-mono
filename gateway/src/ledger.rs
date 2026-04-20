//! Teale Credit ledger operations.
//!
//! The gateway is the source of truth for balances. All credit flows
//! (bonus, direct earn, availability earn, availability drip, spent, ops fee)
//! are recorded as append-only rows in the `ledger` table, with a denormalized
//! `balances` table kept in sync for fast reads.
//!
//! Pricing peg: 1 Teale Credit = $0.000001 USD.
//! Consumer charge formula: cost_usd = (tokens/1000) * complexity * quant / 10_000.
//! Split: 5% ops / 50% direct provider / 45% availability pool (pro-rata to
//! all other online devices).

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

// Drip: 0.003 cr/sec ⇒ with a 60s loop each online device gets 0.18 cr/tick.
// We credit integer credits only, so accumulate per-tick; realistic number is
// 1 credit/tick for devices online at that moment, which works out to
// 60 cr/hr — generous enough to make the wallet feel alive during a demo.
pub const DRIP_CREDITS_PER_TICK: i64 = 1;
pub const DRIP_INTERVAL_SECS: u64 = 60;

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

/// Credit cost in Teale credits for a completed chat turn.
/// Matches mac-app/CreditKit pricing; returned as an integer >=1.
pub fn cost_credits(tokens_out: u64, params_b: f64, quantization: Option<&str>) -> i64 {
    let tokens = tokens_out.max(1) as f64;
    let complexity = params_b.max(0.1) * 0.1;
    let quant_mult = match quantization {
        Some(q) if q.eq_ignore_ascii_case("FP16") => 2.0,
        Some(q) if q.eq_ignore_ascii_case("Q8_0") => 1.5,
        Some(q) if q.to_uppercase().contains("Q8") => 1.5,
        _ => 1.0,
    };
    // cost_usd = (tokens/1000) * complexity * quant / 10_000
    let usd = (tokens / 1000.0) * complexity * quant_mult / 10_000.0;
    // credits = usd / 0.000001 = usd * 1_000_000
    let credits = (usd * 1_000_000.0).ceil() as i64;
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

/// Called after a chat completion. Distributes:
///   - consumer SPENT (negative) — debited from the paying device (issuer for share-key spends)
///   - provider DIRECT_EARN (50% of cost)
///   - AVAILABILITY_EARN to all other online devices (45%, pro-rata)
///   - OPS_FEE (5%) internal
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
    let ops_fee = (cost * 5 + 99) / 100;
    let direct_earn = cost / 2;
    let availability_pool = cost - ops_fee - direct_earn;

    let paying_device_id = consumer.paying_device_id();

    // Filter provider + paying device out of availability recipients
    let recipients: Vec<&String> = online_device_ids
        .iter()
        .filter(|d| Some(d.as_str()) != provider_device_id && *d != paying_device_id)
        .collect();

    let per_peer = if recipients.is_empty() {
        0
    } else {
        availability_pool / recipients.len() as i64
    };
    let availability_used = per_peer * recipients.len() as i64;
    let leftover = availability_pool - availability_used; // folds back to ops

    let mut conn = pool.lock();
    let now = unix_now();
    let tx = conn.transaction()?;
    let note = match consumer {
        ConsumerPrincipal::Device(_) => format!("model={}", model),
        ConsumerPrincipal::Share { key_id, .. } => {
            format!("share_key:{} model={}", key_id, model)
        }
    };

    // Consumer SPENT (debited from the paying device — issuer for share spends)
    tx.execute(
        "INSERT OR IGNORE INTO balances (device_id) VALUES (?)",
        [paying_device_id],
    )?;
    tx.execute(
        "INSERT INTO ledger (device_id, type, amount, timestamp, ref_request_id, note)
         VALUES (?, 'SPENT', ?, ?, ?, ?)",
        params![paying_device_id, -cost, now, request_id, &note],
    )?;
    tx.execute(
        "UPDATE balances SET balance = balance - ?, total_spent = total_spent + ?
         WHERE device_id = ?",
        params![cost, cost, paying_device_id],
    )?;

    // Share-key: atomically bump consumed_credits so budget checks see spend.
    if let ConsumerPrincipal::Share { key_id, .. } = consumer {
        tx.execute(
            "UPDATE share_keys SET consumed_credits = consumed_credits + ?
             WHERE key_id = ?",
            params![cost, key_id],
        )?;
    }

    // Provider DIRECT_EARN
    if let Some(provider) = provider_device_id {
        // Ensure provider has a balances row
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

    // Ops fee (+ leftover) — recorded as an internal entry under a sentinel device id
    let ops_total = ops_fee + leftover;
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
pub fn run_drip(pool: &DbPool, online_device_ids: &[String]) -> anyhow::Result<usize> {
    if online_device_ids.is_empty() {
        return Ok(0);
    }
    let mut conn = pool.lock();
    let now = unix_now();
    let tx = conn.transaction()?;

    let remaining: i64 = tx.query_row("SELECT remaining FROM mint_pool WHERE id = 1", [], |r| {
        r.get(0)
    })?;
    let total_needed = DRIP_CREDITS_PER_TICK * online_device_ids.len() as i64;
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

    for d in online_device_ids {
        tx.execute(
            "INSERT OR IGNORE INTO balances (device_id) VALUES (?)",
            [d.as_str()],
        )?;
        tx.execute(
            "INSERT INTO ledger (device_id, type, amount, timestamp, note)
             VALUES (?, 'AVAILABILITY_DRIP', ?, ?, 'drip tick')",
            params![d.as_str(), DRIP_CREDITS_PER_TICK, now],
        )?;
        tx.execute(
            "UPDATE balances SET balance = balance + ?, total_earned = total_earned + ?
             WHERE device_id = ?",
            params![DRIP_CREDITS_PER_TICK, DRIP_CREDITS_PER_TICK, d.as_str()],
        )?;
    }
    tx.commit()?;
    Ok(online_device_ids.len())
}

/// Spawn the drip loop.
pub fn spawn_drip_loop(pool: DbPool, snapshot: impl Fn() -> Vec<String> + Send + 'static) {
    let pool = Arc::clone(&pool);
    tokio::spawn(async move {
        let mut ticker = tokio::time::interval(std::time::Duration::from_secs(DRIP_INTERVAL_SECS));
        ticker.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
        loop {
            ticker.tick().await;
            let online = snapshot();
            if online.is_empty() {
                continue;
            }
            match run_drip(&pool, &online) {
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

        // cost=100: ops=5, direct=50, pool=45 → 2 peers get 22 each, leftover=1 to ops
        assert_eq!(get_balance(&pool, consumer).balance_credits, 10_000 - 100);
        assert_eq!(get_balance(&pool, provider).balance_credits, 50);
        assert_eq!(get_balance(&pool, peer1).balance_credits, 22);
        assert_eq!(get_balance(&pool, peer2).balance_credits, 22);
    }

    #[test]
    fn drip_credits_online_devices() {
        let pool = open_in_memory().unwrap();
        upsert_device(&pool, "a").unwrap();
        upsert_device(&pool, "b").unwrap();
        run_drip(&pool, &["a".into(), "b".into()]).unwrap();
        assert_eq!(
            get_balance(&pool, "a").balance_credits,
            DRIP_CREDITS_PER_TICK
        );
        assert_eq!(
            get_balance(&pool, "b").balance_credits,
            DRIP_CREDITS_PER_TICK
        );
    }

    #[test]
    fn cost_for_typical_turn() {
        // 1000 tokens on 1B q4 = 1000/1000 * 0.1 * 1.0 / 10_000 = 0.00001 usd
        // = 10 credits
        assert_eq!(cost_credits(1000, 1.0, Some("Q4_K_M")), 10);
        // 500 tokens on 8B q4: 500/1000 * 0.8 * 1.0 / 10_000 = 0.00004 = 40 cr
        assert_eq!(cost_credits(500, 8.0, Some("Q4_K_M")), 40);
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
        // Provider earned 50% = 50.
        assert_eq!(get_balance(&pool, provider).balance_credits, 50);
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
    fn settle_share_key_allows_issuer_negative() {
        let pool = open_in_memory().unwrap();
        let issuer = "alice_poor";
        let provider = "provider";
        upsert_device(&pool, issuer).unwrap();
        upsert_device(&pool, provider).unwrap();

        let minted = mint_share_key(&pool, issuer, None, 3600, 1_000).unwrap();
        // No bonus — issuer balance starts at 0. Burn a big cost.
        settle_request(
            &pool,
            &ConsumerPrincipal::Share {
                issuer_device_id: issuer.to_string(),
                key_id: minted.key_id,
            },
            Some(provider),
            &[provider.to_string()],
            500,
            "reqY",
            "gemma",
        )
        .unwrap();
        assert!(get_balance(&pool, issuer).balance_credits < 0);
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
}
