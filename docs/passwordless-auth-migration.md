# Passwordless auth migration: own it in the gateway

Status: phase 1 implemented (gateway). Phases 2-3 are follow-on work in the apps.

## Goal

Replace Supabase Auth with first-party, passwordless auth owned by the
gateway. Email magic links / one-time codes, no passwords, tokens hashed at
rest, real sessions, email delivery via Resend. The gateway is already the
source of truth for accounts, wallets, credits, and API keys; Supabase Auth is
the one remaining external identity dependency, and its email delivery is the
reason `account_email_codes` exists at all (see migration 017).

## What exists today

- **Human accounts** live in `account_wallets`, keyed by `account_user_id`.
  Today that id is a Supabase user UUID, supplied by the app when it links a
  device via `/v1/account/link`.
- **Email verification** is already gateway-native:
  `POST /v1/account/email-code/request|verify` issues 6-digit codes over
  Resend (`account_email_codes`, SHA-256 hashed, 10-minute TTL, 5 attempts).
  It is bound to the device-bearer middleware and only proves email control
  for wallet linking; it does not create a session.
- **Bearer middleware** (`auth.rs`) resolves four token kinds: static env
  tokens, device tokens, share keys, and programmatic API keys. There is no
  token kind that represents a signed-in human.
- **The mac app** (`AuthKit/AuthManager.swift`) does email OTP, phone OTP,
  Apple, and OAuth through Supabase, and writes profiles/devices to the
  Supabase DB (RLS requires its JWT).

## Design

### Identity

Gateway-native accounts are keyed by a deterministic id derived from the
verified email: `email:{address}` (see `ledger::account_user_id_for_email`).
This cannot collide with existing Supabase-UUID account ids. On first login we
look up `account_wallets` by email: if a row already exists (a user who
previously linked with a Supabase UUID), the session binds to **that**
`account_user_id`, so balances, wallets, and linked devices follow the person,
not the id format. Only net-new emails mint an `email:{address}` account.

### Sessions

- Opaque bearer tokens, `tsess_` prefix + 32 random bytes (hex). Only the
  SHA-256 hash of the token is stored (`account_sessions.token_hash`).
- 30-day sliding expiry: resolving a session past its half-life extends it to
  a fresh 30 days (`last_seen_at` + `expires_at` updated in one write).
- Optional device binding (`device_id`, `device_name` captured at verify time)
  so the app can show "signed in on this Mac" and we can audit session origin.
- Explicit revocation (`revoked_at`) for logout.
- Sessions are a **fifth principal kind** in the bearer middleware:
  `PrincipalKind::AccountSession { account_user_id, session_id }`.
- Sessions authorize **account management only**: account summary, API-key
  management, devices, wallet ops. They cannot spend on inference — the
  completions/messages paths keep requiring device tokens or API keys, and the
  settle switch rejects `AccountSession` with 403. Inference spend stays with
  API keys, which is the posture we want anyway.

### Endpoints

Public (no bearer — these are how you get one):

- `POST /v1/auth/email/request` `{email}` — creates a code row that carries
  both a 6-digit code and a magic-link token, and sends one Resend email
  containing both. Same resend-window and TTL rules as the existing codes.
- `POST /v1/auth/email/verify` `{email, code, deviceId?, deviceName?}` —
  consumes the code (existing attempt limits apply), resolves or creates the
  account, mints a session, returns
  `{sessionToken, expiresAt, accountUserID, email}`.
- `GET /v1/auth/link/:token` — magic-link path. Verifies the link token
  (single-use, same row/TTL as the code), mints a session, and 302-redirects
  to the app deep link `teale://auth/session?token=...`. If the request looks
  like a browser with no app to catch the scheme, an HTML fallback page shows
  the token for copy/paste.

Session-authenticated:

- `GET /v1/auth/session` — validates the session bearer and returns the
  account identity (`{accountUserID, email, expiresAt}`). Sliding renewal
  happens here as a side effect of resolution.
- `POST /v1/auth/logout` — revokes the session.

### Storage (migration 018)

```sql
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
```

`link_token_hash` is nullable so existing device-linking code rows (which have
no magic link) keep working unchanged.

### Email

One email, two ways in: the 6-digit code (same-device entry) and a button/link
(cross-device click). Sent through the existing Resend helper with
`GATEWAY_EMAIL_RESEND_API_KEY` / `GATEWAY_EMAIL_FROM`;
`GATEWAY_EMAIL_DEV_LOG_CODES=1` keeps local dev working without a sender. The
link base URL comes from `GATEWAY_PUBLIC_BASE_URL` (default
`https://gateway.teale.com`).

## Phases

1. **Gateway (this PR).** Migration 018, session ledger functions, the five
   endpoints, the fifth middleware principal kind, account/API-key handler
   arms for sessions, tests. Purely additive: Supabase clients keep working;
   nothing user-facing changes until an app opts in.
2. **mac app.** Point `AuthManager`'s email path at the new endpoints
   (request code/link, verify, store session in Keychain, restore via
   `/v1/auth/session`, logout via `/v1/auth/logout`). Profiles + device
   registry move to gateway account endpoints. Apple / phone / OAuth stay on
   Supabase until their gateway equivalents exist — documented follow-on, not
   silently dropped.
3. **Retire Supabase.** Once all sign-in methods have gateway equivalents and
   the apps no longer read Supabase Auth, remove the dependency and the RLS
   profiles path.

## Security notes

- Codes are 6 digits with 5 attempts and a 10-minute TTL; link tokens are
  128-bit random, single-use, same TTL. Both are SHA-256 hashed at rest, so a
  DB read leak does not yield usable credentials.
- Session tokens are 128-bit random, hashed at rest, and bearer-only in
  transit (HTTPS).
- Magic links redirect to an app-scheme URL, never to a page that would log
  the token in access logs beyond the single click.
- Email enumeration: `/v1/auth/email/request` returns the same shape for
  known and unknown addresses (it always sends mail; account creation happens
  at verify time, not request time).
