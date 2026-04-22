//! SQLite persistence for the gateway ledger.
//!
//! Single connection (WAL mode) guarded by a parking_lot::Mutex — fine for
//! our single-machine write volume. Migrations run at startup.

use std::path::Path;
use std::sync::Arc;

use parking_lot::Mutex;
use rusqlite::Connection;

use crate::ledger;

pub type DbPool = Arc<Mutex<Connection>>;

pub const INITIAL_MINT_POOL: i64 = 1_000_000_000;

const MIGRATIONS: &[&str] = &[
    // 001_init.sql inlined
    r#"
    CREATE TABLE IF NOT EXISTS schema_version (version INTEGER PRIMARY KEY);

    CREATE TABLE IF NOT EXISTS mint_pool (
        id INTEGER PRIMARY KEY CHECK(id = 1),
        total_minted INTEGER NOT NULL,
        remaining INTEGER NOT NULL
    );

    CREATE TABLE IF NOT EXISTS devices (
        device_id TEXT PRIMARY KEY,
        username TEXT,
        first_seen INTEGER NOT NULL,
        last_seen INTEGER NOT NULL
    );

    CREATE TABLE IF NOT EXISTS tokens (
        token TEXT PRIMARY KEY,
        device_id TEXT NOT NULL,
        expires_at INTEGER NOT NULL,
        FOREIGN KEY (device_id) REFERENCES devices(device_id)
    );

    CREATE INDEX IF NOT EXISTS idx_tokens_device ON tokens(device_id);

    CREATE TABLE IF NOT EXISTS challenges (
        device_id TEXT NOT NULL,
        nonce TEXT NOT NULL,
        expires_at INTEGER NOT NULL,
        PRIMARY KEY (device_id, nonce)
    );

    CREATE TABLE IF NOT EXISTS ledger (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        device_id TEXT NOT NULL,
        type TEXT NOT NULL,
        amount INTEGER NOT NULL,
        timestamp INTEGER NOT NULL,
        ref_request_id TEXT,
        note TEXT
    );

    CREATE INDEX IF NOT EXISTS idx_ledger_device_ts ON ledger(device_id, timestamp DESC);

    CREATE TABLE IF NOT EXISTS balances (
        device_id TEXT PRIMARY KEY,
        balance INTEGER NOT NULL DEFAULT 0,
        total_earned INTEGER NOT NULL DEFAULT 0,
        total_spent INTEGER NOT NULL DEFAULT 0
    );

    CREATE TABLE IF NOT EXISTS groups (
        id TEXT PRIMARY KEY,
        title TEXT NOT NULL,
        created_by TEXT NOT NULL,
        created_at INTEGER NOT NULL
    );

    CREATE TABLE IF NOT EXISTS group_members (
        group_id TEXT NOT NULL,
        device_id TEXT NOT NULL,
        joined_at INTEGER NOT NULL,
        PRIMARY KEY (group_id, device_id)
    );

    CREATE INDEX IF NOT EXISTS idx_group_members_device ON group_members(device_id);

    CREATE TABLE IF NOT EXISTS group_messages (
        id TEXT PRIMARY KEY,
        group_id TEXT NOT NULL,
        sender_device_id TEXT NOT NULL,
        type TEXT NOT NULL,
        content TEXT NOT NULL,
        ref_message_id TEXT,
        timestamp INTEGER NOT NULL
    );

    CREATE INDEX IF NOT EXISTS idx_group_messages_ts ON group_messages(group_id, timestamp);

    CREATE TABLE IF NOT EXISTS group_memory (
        id TEXT PRIMARY KEY,
        group_id TEXT NOT NULL,
        category TEXT,
        text TEXT NOT NULL,
        source_message_id TEXT,
        created_at INTEGER NOT NULL
    );

    CREATE INDEX IF NOT EXISTS idx_group_memory_group ON group_memory(group_id);
    "#,
    // 002_share_keys.sql — temporary scoped bearer tokens for community previews.
    r#"
    CREATE TABLE IF NOT EXISTS share_keys (
        key_id TEXT PRIMARY KEY,
        token TEXT NOT NULL UNIQUE,
        issuer_device_id TEXT NOT NULL,
        label TEXT,
        expires_at INTEGER NOT NULL,
        budget_credits INTEGER NOT NULL CHECK(budget_credits > 0),
        consumed_credits INTEGER NOT NULL DEFAULT 0,
        created_at INTEGER NOT NULL,
        revoked_at INTEGER,
        FOREIGN KEY (issuer_device_id) REFERENCES devices(device_id)
    );

    CREATE INDEX IF NOT EXISTS idx_share_keys_issuer
        ON share_keys(issuer_device_id, created_at DESC);
    "#,
    // 003_share_keys_funded.sql — track whether a share key has been
    // pre-funded from the issuer's wallet. Existing rows default to 0 and are
    // brought forward by the startup `migrate_unfunded_share_keys` pass in
    // the ledger module.
    r#"
    ALTER TABLE share_keys ADD COLUMN funded INTEGER NOT NULL DEFAULT 0;
    "#,
    // 004_share_key_funding_ids.sql — add public funding ids and refund-settled
    // marker so share keys can receive third-party contributions safely.
    r#"
    ALTER TABLE share_keys ADD COLUMN funding_id TEXT;
    ALTER TABLE share_keys ADD COLUMN refunds_settled_at INTEGER;

    CREATE UNIQUE INDEX IF NOT EXISTS idx_share_keys_funding_id
        ON share_keys(funding_id)
        WHERE funding_id IS NOT NULL;
    "#,
    // 005_share_key_contributions.sql — per-funder contribution ledger for
    // share-key pools so refunds return to original funders.
    r#"
    CREATE TABLE IF NOT EXISTS share_key_contributions (
        contribution_id TEXT PRIMARY KEY,
        key_id TEXT NOT NULL,
        funder_device_id TEXT NOT NULL,
        funded_credits INTEGER NOT NULL CHECK(funded_credits > 0),
        remaining_credits INTEGER NOT NULL CHECK(remaining_credits >= 0),
        created_at INTEGER NOT NULL,
        refunded_at INTEGER,
        refund_reason TEXT,
        FOREIGN KEY (key_id) REFERENCES share_keys(key_id),
        FOREIGN KEY (funder_device_id) REFERENCES devices(device_id)
    );

    CREATE INDEX IF NOT EXISTS idx_share_key_contributions_key_created
        ON share_key_contributions(key_id, created_at, contribution_id);
    CREATE INDEX IF NOT EXISTS idx_share_key_contributions_funder_created
        ON share_key_contributions(funder_device_id, created_at, contribution_id);
    "#,
];

pub fn open<P: AsRef<Path>>(path: P) -> anyhow::Result<DbPool> {
    let conn = Connection::open(path)?;
    conn.pragma_update(None, "journal_mode", "WAL")?;
    conn.pragma_update(None, "synchronous", "NORMAL")?;
    conn.pragma_update(None, "foreign_keys", "ON")?;

    migrate(&conn)?;
    seed_mint_pool(&conn)?;

    let pool = Arc::new(Mutex::new(conn));
    ledger::backfill_funded_share_key_contributions(&pool)?;
    Ok(pool)
}

/// Open an in-memory DB — used only by tests.
pub fn open_in_memory() -> anyhow::Result<DbPool> {
    let conn = Connection::open_in_memory()?;
    migrate(&conn)?;
    seed_mint_pool(&conn)?;
    let pool = Arc::new(Mutex::new(conn));
    ledger::backfill_funded_share_key_contributions(&pool)?;
    Ok(pool)
}

fn migrate(conn: &Connection) -> anyhow::Result<()> {
    // SQLite's built-in `user_version` pragma tracks which migrations have
    // already applied. Existing DBs from before versioning was added start at
    // 0; migrations 1 and 2 are idempotent (CREATE … IF NOT EXISTS) so they
    // re-run harmlessly, and we only advance the version after each batch.
    let current: i64 = conn.query_row("PRAGMA user_version", [], |r| r.get(0))?;
    for (i, sql) in MIGRATIONS.iter().enumerate() {
        let target = (i + 1) as i64;
        if target > current {
            conn.execute_batch(sql)?;
            // PRAGMA user_version doesn't accept a bound parameter; the value
            // is a controlled integer so string interpolation is safe here.
            conn.execute_batch(&format!("PRAGMA user_version = {}", target))?;
        }
    }
    Ok(())
}

fn seed_mint_pool(conn: &Connection) -> anyhow::Result<()> {
    let row: Option<i64> = conn
        .query_row("SELECT remaining FROM mint_pool WHERE id = 1", [], |r| {
            r.get(0)
        })
        .ok();
    if row.is_none() {
        conn.execute(
            "INSERT INTO mint_pool (id, total_minted, remaining) VALUES (1, ?, ?)",
            rusqlite::params![INITIAL_MINT_POOL, INITIAL_MINT_POOL],
        )?;
        tracing::info!(
            "seeded mint_pool with {} credits (=${})",
            INITIAL_MINT_POOL,
            INITIAL_MINT_POOL as f64 / 1_000_000.0
        );
    }
    Ok(())
}

pub fn unix_now() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0)
}
