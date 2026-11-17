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
    // 013_pins.sql — Private Inference Networks control plane. The gateway is
    // coordination-only: membership, netmaps, scheduling metadata, usage COUNTS.
    // PIN paths never touch ledger/balances (see spec §8).
    r#"
    CREATE TABLE IF NOT EXISTS pins (
        pin_id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        join_code TEXT NOT NULL,
        join_code_generation INTEGER NOT NULL DEFAULT 1,
        owner_account_user_id TEXT NOT NULL,
        netmap_generation INTEGER NOT NULL DEFAULT 1,
        settings TEXT NOT NULL DEFAULT '{}',
        created_at INTEGER NOT NULL,
        deleted_at INTEGER,
        FOREIGN KEY (owner_account_user_id) REFERENCES account_wallets(account_user_id)
    );
    CREATE INDEX IF NOT EXISTS idx_pins_join_code ON pins(join_code) WHERE deleted_at IS NULL;

    CREATE TABLE IF NOT EXISTS pin_roles (
        pin_id TEXT NOT NULL,
        account_user_id TEXT NOT NULL,
        role TEXT NOT NULL CHECK(role IN ('admin','modelrator')),
        granted_by TEXT,
        granted_at INTEGER NOT NULL,
        PRIMARY KEY (pin_id, account_user_id),
        FOREIGN KEY (pin_id) REFERENCES pins(pin_id) ON DELETE CASCADE
    );

    CREATE TABLE IF NOT EXISTS pin_members (
        pin_id TEXT NOT NULL,
        device_id TEXT NOT NULL,
        node_pubkey TEXT NOT NULL,
        display_name TEXT,
        status TEXT NOT NULL CHECK(status IN ('pending','active','disabled','removed')),
        serves_models INTEGER NOT NULL DEFAULT 1,
        allow_remote_models INTEGER NOT NULL DEFAULT 1,
        endpoints TEXT NOT NULL DEFAULT '[]',
        requested_at INTEGER NOT NULL,
        approved_by TEXT,
        joined_at INTEGER,
        last_seen INTEGER,
        removed_at INTEGER,
        removed_by TEXT,
        PRIMARY KEY (pin_id, device_id),
        FOREIGN KEY (pin_id) REFERENCES pins(pin_id) ON DELETE CASCADE
    );
    CREATE INDEX IF NOT EXISTS idx_pin_members_device ON pin_members(device_id);

    CREATE TABLE IF NOT EXISTS pin_usage (
        pin_id TEXT NOT NULL,
        day TEXT NOT NULL,
        provider_device_id TEXT NOT NULL,
        consumer_device_id TEXT NOT NULL,
        model_id TEXT NOT NULL,
        requests INTEGER NOT NULL DEFAULT 0,
        tokens_in INTEGER NOT NULL DEFAULT 0,
        tokens_out INTEGER NOT NULL DEFAULT 0,
        PRIMARY KEY (pin_id, day, provider_device_id, consumer_device_id, model_id),
        FOREIGN KEY (pin_id) REFERENCES pins(pin_id) ON DELETE CASCADE
    );

    CREATE TABLE IF NOT EXISTS pin_model_policy (
        pin_id TEXT NOT NULL,
        device_id TEXT NOT NULL,
        model_id TEXT NOT NULL,
        desired_state TEXT NOT NULL CHECK(desired_state IN ('loaded','downloaded','none')),
        set_by TEXT NOT NULL,
        set_at INTEGER NOT NULL,
        applied_state TEXT,
        applied_at INTEGER,
        last_error TEXT,
        PRIMARY KEY (pin_id, device_id, model_id),
        FOREIGN KEY (pin_id) REFERENCES pins(pin_id) ON DELETE CASCADE
    );
    "#,
    // 014_pin_usage_batches.sql — idempotency ledger for provider usage
    // reports. A device retrying a batch whose ack was lost must not double
    // count tokens; batch ids are remembered and replays dropped.
    r#"
    CREATE TABLE IF NOT EXISTS pin_usage_batches (
        pin_id TEXT NOT NULL,
        provider_device_id TEXT NOT NULL,
        batch_id TEXT NOT NULL,
        received_at INTEGER NOT NULL,
        PRIMARY KEY (pin_id, provider_device_id, batch_id),
        FOREIGN KEY (pin_id) REFERENCES pins(pin_id) ON DELETE CASCADE
    );
    "#,
    // 015_pin_member_loaded_models.sql — devices advertise their loaded
    // models on /sync; persisted so netmaps (and offline-LAN scheduling on
    // peers) reflect devices the live registry hasn't heard from.
    r#"
    ALTER TABLE pin_members ADD COLUMN loaded_models TEXT NOT NULL DEFAULT '[]';
    "#,
    // 016_pin_member_wg_pubkey.sql — X25519 static key for data-plane Noise
    // peer authentication. Distinct from node_pubkey (Ed25519): CryptoKit
    // reuses the Ed25519 seed as the X25519 scalar, so the public keys are
    // unrelated and must be advertised separately.
    r#"
    ALTER TABLE pin_members ADD COLUMN wg_pubkey TEXT NOT NULL DEFAULT '';
    "#,
    // 017_account_email_codes.sql — short-lived verified email login codes
    // for human accounts. This avoids depending on Supabase Auth email
    // delivery for the gateway account-wallet identity.
    r#"
    CREATE TABLE IF NOT EXISTS account_email_codes (
        id TEXT PRIMARY KEY,
        email TEXT NOT NULL,
        code_hash TEXT NOT NULL,
        created_at INTEGER NOT NULL,
        expires_at INTEGER NOT NULL,
        attempts INTEGER NOT NULL DEFAULT 0,
        consumed_at INTEGER
    );

    CREATE INDEX IF NOT EXISTS idx_account_email_codes_email_created
        ON account_email_codes(email, created_at DESC);
    "#,
    // user_version 18 — ledger_anchoring (historically labelled
    // "014_ledger_anchoring.sql"; it landed after 017, so it is applied as the
    // 18th migration). External verifiability for the credit ledger.
    // Hashes live in a side table so the money path (INSERT INTO ledger) stays
    // untouched; anchors are Merkle roots published to Solana by an
    // operator-signed memo transaction. See docs/ledger-verifiability.md.
    r#"
    CREATE TABLE IF NOT EXISTS ledger_entry_hashes (
        entry_id INTEGER PRIMARY KEY,
        entry_hash TEXT NOT NULL,
        chain_hash TEXT NOT NULL
    );

    CREATE TABLE IF NOT EXISTS ledger_anchors (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        created_at INTEGER NOT NULL,
        first_entry_id INTEGER NOT NULL,
        last_entry_id INTEGER NOT NULL,
        entry_count INTEGER NOT NULL,
        merkle_root TEXT NOT NULL,
        chain_tip TEXT NOT NULL,
        memo TEXT NOT NULL,
        status TEXT NOT NULL DEFAULT 'pending',
        tx_signature TEXT,
        confirmed_at INTEGER
    );

    CREATE INDEX IF NOT EXISTS idx_ledger_anchors_status ON ledger_anchors(status);
    "#,
    // user_version 19 — account_sessions (historically labelled
    // "018_account_sessions.sql"). Passwordless gateway-native auth. Opaque
    // session tokens (SHA-256 hashed at rest) for human accounts, plus a
    // single-use magic-link token on email code rows. See
    // docs/passwordless-auth-migration.md.
    r#"
    CREATE TABLE IF NOT EXISTS account_sessions (
        id TEXT PRIMARY KEY,
        account_user_id TEXT NOT NULL,
        token_hash TEXT NOT NULL UNIQUE,
        created_at INTEGER NOT NULL,
        expires_at INTEGER NOT NULL,
        last_seen_at INTEGER NOT NULL,
        device_id TEXT,
        device_name TEXT,
        revoked_at INTEGER
    );

    CREATE INDEX IF NOT EXISTS idx_account_sessions_account
        ON account_sessions(account_user_id);

    ALTER TABLE account_email_codes ADD COLUMN link_token_hash TEXT;
    "#,
    // user_version 20 — pin_member_offers_exit (historically labelled
    // "019_pin_member_offers_exit.sql"). A member device offers itself as a
    // SOCKS5 exit node for this network (Phase 1 exit-node data plane).
    // Device-sovereign: set by the device on /sync; surfaced in the signed
    // netmap so consumers can pick an exit. Independent of serves_models —
    // a relay-only device (e.g. a MacBook Air behind NAT) can be a
    // dedicated exit provider.
    r#"
    ALTER TABLE pin_members ADD COLUMN offers_exit INTEGER NOT NULL DEFAULT 0;
    "#,
    // user_version 21, 22, 23 — historical one-shot data fixes for a single
    // production account (an email change, a case-split account merge and a
    // duplicate network rename; historically labelled 020-022). They already
    // ran in production, so they are kept as no-ops purely to preserve the
    // user_version numbering. The data they touched is deliberately not
    // reproduced in source.
    r#"
    DELETE FROM schema_version WHERE 0;
    "#,
    r#"
    DELETE FROM schema_version WHERE 0;
    "#,
    r#"
    DELETE FROM schema_version WHERE 0;
    "#,
    // user_version 24 — auth_hardening.
    // - account_email_bonuses: the welcome bonus is granted at most once per
    //   verified email address, on the verified-email login that creates the
    //   account (see ledger::resolve_login_account).
    // - index the magic-link token lookup.
    // - index token expiry for the periodic auth-row sweep.
    // Device tokens and share-key tokens are rewritten as SHA-256 digests by
    // the code step for this version (`hash_plaintext_bearer_tokens`). That
    // step is one-way: plaintext bearers are never stored again.
    r#"
    CREATE TABLE IF NOT EXISTS account_email_bonuses (
        email TEXT PRIMARY KEY,
        account_user_id TEXT NOT NULL,
        amount_credits INTEGER NOT NULL,
        granted_at INTEGER NOT NULL
    );

    CREATE INDEX IF NOT EXISTS idx_account_email_codes_link_token
        ON account_email_codes(link_token_hash)
        WHERE link_token_hash IS NOT NULL;

    CREATE INDEX IF NOT EXISTS idx_tokens_expires ON tokens(expires_at);
    "#,
];

/// user_version whose code step hashes plaintext device / share-key tokens.
const HASH_BEARER_TOKENS_VERSION: i64 = 24;

/// Env var that allows booting on an in-memory ledger when the configured DB
/// path cannot be opened. Local development only: an in-memory ledger loses
/// every balance, session and deposit on restart.
pub const ALLOW_IN_MEMORY_DB_ENV: &str = "TEALE_ALLOW_IN_MEMORY_DB";

pub fn in_memory_fallback_allowed() -> bool {
    std::env::var(ALLOW_IN_MEMORY_DB_ENV).is_ok_and(|v| v.trim() == "1")
}

/// Open the ledger DB at `path`. If it cannot be opened, startup fails unless
/// `TEALE_ALLOW_IN_MEMORY_DB=1` explicitly opts into an in-memory ledger.
pub fn open_or_fail(path: &str) -> anyhow::Result<DbPool> {
    match open(path) {
        Ok(pool) => Ok(pool),
        Err(err) if in_memory_fallback_allowed() => {
            tracing::warn!(
                "could not open ledger DB at {} ({}); {}=1 so falling back to an \
                 in-memory ledger (all state is lost on restart)",
                path,
                err,
                ALLOW_IN_MEMORY_DB_ENV
            );
            open_in_memory()
        }
        Err(err) => Err(anyhow::anyhow!(
            "could not open ledger DB at {path}: {err}. Refusing to start on an in-memory \
             ledger; fix the volume/path or set {ALLOW_IN_MEMORY_DB_ENV}=1 for local development"
        )),
    }
}

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

/// Open an in-memory DB — used by tests (and by `open_or_fail` when the
/// in-memory fallback is explicitly allowed).
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
    // re-run harmlessly. Each migration (SQL, optional code step, version
    // bump) commits atomically, so a failure leaves the DB at the previous
    // version instead of half-migrated.
    let current: i64 = conn.query_row("PRAGMA user_version", [], |r| r.get(0))?;
    for (i, sql) in MIGRATIONS.iter().enumerate() {
        let target = (i + 1) as i64;
        if target > current {
            let tx = conn.unchecked_transaction()?;
            tx.execute_batch(sql)?;
            if target == HASH_BEARER_TOKENS_VERSION {
                hash_plaintext_bearer_tokens(&tx)?;
            }
            // PRAGMA user_version doesn't accept a bound parameter; the value
            // is a controlled integer so string interpolation is safe here.
            tx.execute_batch(&format!("PRAGMA user_version = {}", target))?;
            tx.commit()?;
        }
    }
    Ok(())
}

/// One-way migration of device tokens and share-key tokens to SHA-256
/// digests (`ledger::hash_bearer_token`). Rows already carrying the hashed
/// prefix are skipped, so re-running is harmless. Expired device tokens are
/// dropped instead of hashed.
fn hash_plaintext_bearer_tokens(conn: &Connection) -> anyhow::Result<()> {
    conn.execute("DELETE FROM tokens WHERE expires_at <= ?", [unix_now()])?;
    let device_tokens: Vec<String> = {
        let mut stmt = conn.prepare("SELECT token FROM tokens WHERE token NOT LIKE 'sha256:%'")?;
        let rows = stmt.query_map([], |r| r.get::<_, String>(0))?;
        rows.collect::<Result<Vec<_>, _>>()?
    };
    for token in &device_tokens {
        conn.execute(
            "UPDATE tokens SET token = ? WHERE token = ?",
            rusqlite::params![ledger::hash_bearer_token(token), token],
        )?;
    }
    let share_tokens: Vec<(String, String)> = {
        let mut stmt =
            conn.prepare("SELECT key_id, token FROM share_keys WHERE token NOT LIKE 'sha256:%'")?;
        let rows = stmt.query_map([], |r| Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?)))?;
        rows.collect::<Result<Vec<_>, _>>()?
    };
    for (key_id, token) in &share_tokens {
        conn.execute(
            "UPDATE share_keys SET token = ? WHERE key_id = ?",
            rusqlite::params![ledger::hash_bearer_token(token), key_id],
        )?;
    }
    if !device_tokens.is_empty() || !share_tokens.is_empty() {
        tracing::info!(
            device_tokens = device_tokens.len(),
            share_keys = share_tokens.len(),
            "hashed plaintext bearer tokens at rest"
        );
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

#[cfg(test)]
mod tests {
    use super::*;

    fn user_version(conn: &Connection) -> i64 {
        conn.pragma_query_value(None, "user_version", |r| r.get(0))
            .unwrap()
    }

    #[test]
    fn migrations_reach_latest_version() {
        let pool = open_in_memory().unwrap();
        let conn = pool.lock();
        assert_eq!(user_version(&conn), MIGRATIONS.len() as i64);
    }

    #[test]
    fn bearer_hash_migration_rewrites_plaintext_rows_once() {
        let conn = Connection::open_in_memory().unwrap();
        conn.pragma_update(None, "foreign_keys", "ON").unwrap();
        // Bring the DB to the version just before the hashing step.
        for sql in &MIGRATIONS[..(HASH_BEARER_TOKENS_VERSION - 1) as usize] {
            conn.execute_batch(sql).unwrap();
        }
        let previous = HASH_BEARER_TOKENS_VERSION - 1;
        conn.execute_batch(&format!("PRAGMA user_version = {previous}"))
            .unwrap();
        let now = unix_now();
        conn.execute(
            "INSERT INTO devices (device_id, first_seen, last_seen) VALUES ('dev', ?, ?)",
            [now, now],
        )
        .unwrap();
        conn.execute(
            "INSERT INTO tokens (token, device_id, expires_at) VALUES ('tok_dev_live', 'dev', ?)",
            [now + 3600],
        )
        .unwrap();
        conn.execute(
            "INSERT INTO tokens (token, device_id, expires_at) VALUES ('tok_dev_old', 'dev', ?)",
            [now - 1],
        )
        .unwrap();
        conn.execute(
            "INSERT INTO share_keys
                (key_id, token, issuer_device_id, label, expires_at, budget_credits,
                 consumed_credits, created_at, revoked_at)
             VALUES ('k1', 'tok_share_raw', 'dev', NULL, ?, 10, 0, ?, NULL)",
            [now + 3600, now],
        )
        .unwrap();

        migrate(&conn).unwrap();
        assert_eq!(user_version(&conn), HASH_BEARER_TOKENS_VERSION);

        let tokens: Vec<String> = {
            let mut stmt = conn.prepare("SELECT token FROM tokens").unwrap();
            let rows = stmt.query_map([], |r| r.get(0)).unwrap();
            rows.collect::<Result<Vec<_>, _>>().unwrap()
        };
        assert_eq!(tokens, vec![ledger::hash_bearer_token("tok_dev_live")]);
        let share: String = conn
            .query_row(
                "SELECT token FROM share_keys WHERE key_id = 'k1'",
                [],
                |r| r.get(0),
            )
            .unwrap();
        assert_eq!(share, ledger::hash_bearer_token("tok_share_raw"));

        // Re-running the code step leaves hashed rows untouched.
        hash_plaintext_bearer_tokens(&conn).unwrap();
        let share_again: String = conn
            .query_row(
                "SELECT token FROM share_keys WHERE key_id = 'k1'",
                [],
                |r| r.get(0),
            )
            .unwrap();
        assert_eq!(share_again, share);
    }
}
