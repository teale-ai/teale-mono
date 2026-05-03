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
    // 006_account_wallets.sql — account-level balances backed by linked devices.
    r#"
    CREATE TABLE IF NOT EXISTS account_wallets (
        account_user_id TEXT PRIMARY KEY,
        display_name TEXT,
        phone TEXT,
        email TEXT,
        github_username TEXT,
        balance_credits INTEGER NOT NULL DEFAULT 0,
        usdc_cents INTEGER NOT NULL DEFAULT 0,
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL
    );

    CREATE TABLE IF NOT EXISTS account_devices (
        device_id TEXT PRIMARY KEY,
        account_user_id TEXT NOT NULL,
        device_name TEXT,
        platform TEXT,
        linked_at INTEGER NOT NULL,
        last_seen INTEGER NOT NULL,
        FOREIGN KEY (device_id) REFERENCES devices(device_id) ON DELETE CASCADE,
        FOREIGN KEY (account_user_id) REFERENCES account_wallets(account_user_id) ON DELETE CASCADE
    );

    CREATE INDEX IF NOT EXISTS idx_account_devices_account
        ON account_devices(account_user_id, last_seen DESC);

    CREATE TABLE IF NOT EXISTS account_ledger (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        account_user_id TEXT NOT NULL,
        asset TEXT NOT NULL,
        amount INTEGER NOT NULL,
        type TEXT NOT NULL,
        timestamp INTEGER NOT NULL,
        device_id TEXT,
        note TEXT,
        FOREIGN KEY (account_user_id) REFERENCES account_wallets(account_user_id) ON DELETE CASCADE
    );

    CREATE INDEX IF NOT EXISTS idx_account_ledger_account_ts
        ON account_ledger(account_user_id, timestamp DESC);
    "#,
    // 007_availability_sessions.sql - active per-device availability accrual
    // that is flushed into a single ledger row when the session ends.
    r#"
    CREATE TABLE IF NOT EXISTS availability_sessions (
        device_id TEXT PRIMARY KEY,
        model_id TEXT,
        started_at INTEGER NOT NULL,
        last_accrued_at INTEGER NOT NULL,
        accrued_credits INTEGER NOT NULL DEFAULT 0,
        FOREIGN KEY (device_id) REFERENCES devices(device_id) ON DELETE CASCADE
    );
    "#,
    // 008_account_api_keys.sql — historical: was main's first cut at API keys
    // before the OpenRouter-parity rewrite. Kept as a no-op so user_version=8
    // is preserved for already-deployed DBs; the table itself is dropped in
    // migration 012 below in favour of the richer `api_keys` schema (hashed
    // tokens, roles, credit limits).
    r#"
    CREATE TABLE IF NOT EXISTS account_api_keys (
        key_id TEXT PRIMARY KEY,
        token TEXT NOT NULL UNIQUE,
        account_user_id TEXT NOT NULL,
        label TEXT,
        created_at INTEGER NOT NULL,
        last_used_at INTEGER,
        revoked_at INTEGER,
        FOREIGN KEY (account_user_id) REFERENCES account_wallets(account_user_id) ON DELETE CASCADE
    );

    CREATE INDEX IF NOT EXISTS idx_account_api_keys_account_created
        ON account_api_keys(account_user_id, created_at DESC);
    "#,
    // 009_providers.sql — centralized 3rd-party inference vendors that join
    // the Teale marketplace. Mirrors OpenRouter's onboarding shape: each
    // provider declares a model menu with USD-string pricing and exposes an
    // OpenAI-compatible (or Anthropic-compatible) inference endpoint. Earnings
    // accrue to provider_wallets via the 95/5 settlement path.
    r#"
    CREATE TABLE IF NOT EXISTS providers (
        provider_id TEXT PRIMARY KEY,
        slug TEXT NOT NULL UNIQUE,
        display_name TEXT NOT NULL,
        base_url TEXT NOT NULL,
        wire_format TEXT NOT NULL DEFAULT 'openai',
        auth_header_name TEXT NOT NULL DEFAULT 'Authorization',
        auth_secret_ref TEXT NOT NULL,
        status TEXT NOT NULL DEFAULT 'active' CHECK(status IN ('active','disabled','probation')),
        data_collection TEXT NOT NULL DEFAULT 'allow' CHECK(data_collection IN ('allow','deny')),
        zdr INTEGER NOT NULL DEFAULT 0,
        quantization TEXT,
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL
    );

    CREATE TABLE IF NOT EXISTS provider_models (
        provider_id TEXT NOT NULL,
        model_id TEXT NOT NULL,
        pricing_prompt_usd TEXT NOT NULL,
        pricing_completion_usd TEXT NOT NULL,
        pricing_request_usd TEXT,
        min_context INTEGER,
        context_length INTEGER NOT NULL,
        max_output_tokens INTEGER,
        supported_features TEXT,
        input_modalities TEXT,
        deprecation_date TEXT,
        PRIMARY KEY (provider_id, model_id),
        FOREIGN KEY (provider_id) REFERENCES providers(provider_id) ON DELETE CASCADE
    );

    CREATE INDEX IF NOT EXISTS idx_provider_models_model
        ON provider_models(model_id);

    CREATE TABLE IF NOT EXISTS provider_health (
        provider_id TEXT NOT NULL,
        model_id TEXT NOT NULL,
        window_started_at INTEGER NOT NULL,
        success_count INTEGER NOT NULL DEFAULT 0,
        failure_count INTEGER NOT NULL DEFAULT 0,
        ttft_p50_ms INTEGER,
        ttft_p90_ms INTEGER,
        ttft_p99_ms INTEGER,
        tps_p50 INTEGER,
        tps_p90 INTEGER,
        tps_p99 INTEGER,
        last_outage_at INTEGER,
        PRIMARY KEY (provider_id, model_id),
        FOREIGN KEY (provider_id) REFERENCES providers(provider_id) ON DELETE CASCADE
    );

    CREATE TABLE IF NOT EXISTS provider_wallets (
        provider_id TEXT PRIMARY KEY,
        balance_credits INTEGER NOT NULL DEFAULT 0,
        total_earned INTEGER NOT NULL DEFAULT 0,
        total_paid_out INTEGER NOT NULL DEFAULT 0,
        usdc_cents INTEGER NOT NULL DEFAULT 0,
        payout_threshold INTEGER NOT NULL DEFAULT 0,
        payout_destination TEXT,
        updated_at INTEGER NOT NULL,
        FOREIGN KEY (provider_id) REFERENCES providers(provider_id) ON DELETE CASCADE
    );

    CREATE TABLE IF NOT EXISTS provider_ledger (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        provider_id TEXT NOT NULL,
        type TEXT NOT NULL,
        amount INTEGER NOT NULL,
        timestamp INTEGER NOT NULL,
        ref_request_id TEXT,
        model_id TEXT,
        note TEXT,
        FOREIGN KEY (provider_id) REFERENCES providers(provider_id) ON DELETE CASCADE
    );

    CREATE INDEX IF NOT EXISTS idx_provider_ledger_provider_ts
        ON provider_ledger(provider_id, timestamp DESC);
    "#,
    // 010_account_onchain_wallets.sql - account-level deposit-backed Solana
    // redemption state. Credits remain the fast internal rail; only explicitly
    // deposited principal is redeemable as on-chain USDC.
    r#"
    ALTER TABLE account_wallets ADD COLUMN solana_address TEXT;
    ALTER TABLE account_wallets ADD COLUMN solana_enabled INTEGER NOT NULL DEFAULT 0;
    ALTER TABLE account_wallets ADD COLUMN deposited_usdc_cents_total INTEGER NOT NULL DEFAULT 0;
    ALTER TABLE account_wallets ADD COLUMN withdrawn_usdc_cents_total INTEGER NOT NULL DEFAULT 0;

    UPDATE account_wallets
    SET deposited_usdc_cents_total = usdc_cents
    WHERE deposited_usdc_cents_total = 0
      AND withdrawn_usdc_cents_total = 0
      AND usdc_cents > 0;

    CREATE TABLE IF NOT EXISTS account_onchain_deposits (
        deposit_id TEXT PRIMARY KEY,
        account_user_id TEXT NOT NULL,
        tx_signature TEXT NOT NULL UNIQUE,
        solana_address TEXT NOT NULL,
        source_address TEXT,
        amount_usdc_cents INTEGER NOT NULL CHECK(amount_usdc_cents > 0),
        amount_credits INTEGER NOT NULL CHECK(amount_credits > 0),
        created_at INTEGER NOT NULL,
        FOREIGN KEY (account_user_id) REFERENCES account_wallets(account_user_id) ON DELETE CASCADE
    );

    CREATE INDEX IF NOT EXISTS idx_account_onchain_deposits_account_created
        ON account_onchain_deposits(account_user_id, created_at DESC);

    CREATE TABLE IF NOT EXISTS account_withdrawals (
        withdrawal_id TEXT PRIMARY KEY,
        request_id TEXT NOT NULL UNIQUE,
        account_user_id TEXT NOT NULL,
        destination_address TEXT NOT NULL,
        amount_usdc_cents INTEGER NOT NULL CHECK(amount_usdc_cents > 0),
        amount_credits INTEGER NOT NULL CHECK(amount_credits > 0),
        status TEXT NOT NULL,
        tx_signature TEXT UNIQUE,
        created_at INTEGER NOT NULL,
        completed_at INTEGER,
        FOREIGN KEY (account_user_id) REFERENCES account_wallets(account_user_id) ON DELETE CASCADE
    );

    CREATE INDEX IF NOT EXISTS idx_account_withdrawals_account_created
        ON account_withdrawals(account_user_id, created_at DESC);
    "#,
    // 011_referrals.sql - invite codes and one-time join claims for device or
    // account onboarding bonuses.
    r#"
    CREATE TABLE IF NOT EXISTS referral_codes (
        code TEXT PRIMARY KEY,
        owner_kind TEXT NOT NULL,
        owner_device_id TEXT UNIQUE,
        owner_account_user_id TEXT UNIQUE,
        created_at INTEGER NOT NULL,
        FOREIGN KEY (owner_device_id) REFERENCES devices(device_id) ON DELETE CASCADE,
        FOREIGN KEY (owner_account_user_id) REFERENCES account_wallets(account_user_id) ON DELETE CASCADE
    );

    CREATE TABLE IF NOT EXISTS referral_claims (
        claim_id TEXT PRIMARY KEY,
        code TEXT NOT NULL,
        referrer_kind TEXT NOT NULL,
        referrer_id TEXT NOT NULL,
        referred_kind TEXT NOT NULL,
        referred_device_id TEXT UNIQUE,
        referred_account_user_id TEXT UNIQUE,
        referrer_bonus_credits INTEGER NOT NULL,
        referred_bonus_credits INTEGER NOT NULL,
        created_at INTEGER NOT NULL,
        FOREIGN KEY (code) REFERENCES referral_codes(code) ON DELETE CASCADE,
        FOREIGN KEY (referred_device_id) REFERENCES devices(device_id) ON DELETE CASCADE,
        FOREIGN KEY (referred_account_user_id) REFERENCES account_wallets(account_user_id) ON DELETE CASCADE
    );

    CREATE INDEX IF NOT EXISTS idx_referral_claims_code_created
        ON referral_claims(code, created_at DESC);
    "#,
    // 012_api_keys.sql - programmatic API keys scoped to an account. Live keys
    // can call inference; provisioning keys can additionally manage other keys.
    // Spend is debited from the owning account_wallet's credit balance and
    // attributed back to the key via api_keys.usage_credits + api_key_id on
    // account_ledger rows. Hashed at rest; the plaintext token is returned to
    // the user only at creation time.
    //
    // Drops the legacy `account_api_keys` table from migration 008 — that
    // earlier model used plaintext tokens and no spend limits; this richer
    // schema replaces it.
    r#"
    DROP TABLE IF EXISTS account_api_keys;

    CREATE TABLE IF NOT EXISTS api_keys (
        key_id TEXT PRIMARY KEY,
        account_user_id TEXT NOT NULL,
        key_hash TEXT NOT NULL UNIQUE,
        prefix TEXT NOT NULL,
        name TEXT,
        role TEXT NOT NULL CHECK(role IN ('live', 'provisioning')),
        credit_limit INTEGER,
        usage_credits INTEGER NOT NULL DEFAULT 0,
        disabled INTEGER NOT NULL DEFAULT 0,
        created_at INTEGER NOT NULL,
        last_used_at INTEGER,
        FOREIGN KEY (account_user_id) REFERENCES account_wallets(account_user_id) ON DELETE CASCADE
    );

    CREATE INDEX IF NOT EXISTS idx_api_keys_account_created
        ON api_keys(account_user_id, created_at DESC);

    ALTER TABLE account_ledger ADD COLUMN api_key_id TEXT REFERENCES api_keys(key_id);

    CREATE INDEX IF NOT EXISTS idx_account_ledger_api_key
        ON account_ledger(api_key_id, timestamp DESC);
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
