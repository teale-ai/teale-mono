# Passwordless auth migration: own it in the gateway

Status: phase 1 implemented (gateway). Phases 2-3 are follow-on work in the apps.

## Goal

Replace Supabase Auth with first-party, passwordless auth owned by the
gateway. Email magic links / one-time codes, no passwords, tokens hashed at
rest, real sessions, email delivery via Resend. The gateway is already the
source of truth for accounts, wallets, credits, and API keys; Supabase Auth is
the one remaining external identity dependency, and its email delivery is the
reason `account_email_codes` exists at all (see migration user_version 17).

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
- Sessions authorize **account management only**. What a session bearer can
  call today: `GET /v1/account/summary`, `POST /v1/account/send`, API-key
  management (`/v1/keys*`), `POST /v1/account/sweep` and
  `POST /v1/account/devices/remove` for devices linked to the session's
  account, and `POST/GET /v1/pins` (create a network owned by the account /
  list the account's networks). Device linking (`/v1/account/link`) and the
  on-chain wallet endpoints (`/v1/account/wallet/*`) stay device-bound; a
  session is presented to link as an ownership proof (see "Linking devices"
  below). Sessions cannot spend on inference — the completions/messages paths
  keep requiring device tokens or API keys, and the settle switch rejects
  `AccountSession` with 403.
- `last_seen_at` is written at most once a minute per session (and on sliding
  renewal); database errors while resolving a session return 500, not 401.

### Linking devices (ownership proof)

`POST /v1/account/link` is called with the device bearer. Clients that hold a
session add `X-Teale-Account-Session: tsess_…`:

- With the header, the session's account must equal the (normalized)
  `accountUserID`; the device is linked, including re-pointing a device that
  was linked to another account.
- Without the header, the link is allowed only when the account does not
  exist yet, the device is not linked to a different account, and the id is
  not an `email:` id. It creates an empty account (no bonus). Re-linking a
  device to the account it is already on (a metadata refresh) is allowed.
- Anything else is `403` with error code `account_session_required`.
- `account_wallets.email` is never written from link metadata; only verified
  email flows bind it. Login fails closed (409) if more than one wallet
  carries the address.
- The welcome bonus is granted once, when a verified-email first login creates
  the account, at most once per verified address
  (`account_email_bonuses`). Links never mint it. A referral code on link is
  honoured only for a session-backed link of the account's first device.
- Legacy lowercase-UUID accounts are renamed (never merged) to the canonical
  uppercase id when a link names the uppercase form.

### Endpoints

Public (no bearer — these are how you get one):

- `POST /v1/auth/email/request` `{email}` — creates a code row that carries
  both a 6-digit code and a magic-link token, and sends one Resend email
  containing both. Same resend-window and TTL rules as the existing codes.
- `POST /v1/auth/email/verify` `{email, code, deviceId?, deviceName?}` —
  consumes the code (existing attempt limits apply), resolves or creates the
  account, mints a session, returns
  `{sessionToken, expiresAt, accountUserID, email}`.
- `GET /v1/auth/link/:token` — magic-link landing page. Side-effect free (mail
  scanners and prefetchers issue GETs): it neither consumes the token nor
  mints a session, it renders a button that POSTs back to the same URL.
- `POST /v1/auth/link/:token` — consumes the link token (single-use, same
  row/TTL as the code) and mints a session. Browser form posts
  (`Accept: text/html`) get a 303 to the app deep link
  `teale://auth/session?token=...`; other clients get the same JSON as
  `/v1/auth/email/verify`. The session token is never rendered into HTML, and
  the HTTP trace span logs token-bearing paths redacted.
- Rate limits: per client IP (`Fly-Client-IP`, else the socket address),
  10 email requests and 30 verify/link attempts per hour; per address, a 60 s
  resend window and at most 10 emails per rolling 24 h (429).
- The device-bound `POST /v1/account/email-code/verify` is a verified flow
  too: it resolves the same account and also returns `sessionToken` /
  `expiresAt`.

Session-authenticated:

- `GET /v1/auth/session` — validates the session bearer and returns the
  account identity (`{accountUserID, email, expiresAt}`). Sliding renewal
  happens here as a side effect of resolution.
- `POST /v1/auth/logout` — revokes the session.

### Storage (user_version 19, historically labelled "018_account_sessions")

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

1. **Gateway (this PR).** Migration user_version 19, session ledger functions, the five
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
- Magic links are consumed only by an explicit POST from the landing page;
  the resulting session goes to an app-scheme redirect (or JSON), never into
  HTML. Token-bearing request paths are redacted in the HTTP trace span.
- Device tokens and share-key tokens are stored as SHA-256 digests too
  (user_version 24 migrated existing rows one-way).
- Expired tokens/challenges, old email codes and revoked/expired sessions are
  pruned every 10 minutes.
- Email enumeration: `/v1/auth/email/request` returns the same shape for
  known and unknown addresses (it always sends mail; account creation happens
  at verify time, not request time).
