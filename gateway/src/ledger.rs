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
///   - consumer SPENT (negative)
///   - provider DIRECT_EARN (50% of cost)
///   - AVAILABILITY_EARN to all other online devices (45%, pro-rata)
///   - OPS_FEE (5%) internal
pub fn settle_request(
    pool: &DbPool,
    consumer_device_id: &str,
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

    // Filter provider out of availability recipients
    let recipients: Vec<&String> = online_device_ids
        .iter()
        .filter(|d| Some(d.as_str()) != provider_device_id && *d != consumer_device_id)
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
    let note = format!("model={}", model);

    // Consumer SPENT
    tx.execute(
        "INSERT INTO ledger (device_id, type, amount, timestamp, ref_request_id, note)
         VALUES (?, 'SPENT', ?, ?, ?, ?)",
        params![consumer_device_id, -cost, now, request_id, &note],
    )?;
    tx.execute(
        "UPDATE balances SET balance = balance - ?, total_spent = total_spent + ?
         WHERE device_id = ?",
        params![cost, cost, consumer_device_id],
    )?;

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

        let online = vec![
            provider.to_string(),
            peer1.to_string(),
            peer2.to_string(),
        ];
        settle_request(&pool, consumer, Some(provider), &online, 100, "req1", "gemma").unwrap();

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
}
