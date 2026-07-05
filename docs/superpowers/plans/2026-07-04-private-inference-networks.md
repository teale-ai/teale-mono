# Private Inference Networks (PIN) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship PIN per `docs/superpowers/specs/2026-07-04-private-inference-networks-design.md` — gateway control plane, cross-platform encrypted data plane, priority queueing, token accounting, shared desktop UI, CLI — rollout-ready for a 200+ employee company that is ~90% Windows, ~10% macOS.

**Architecture:** Gateway = coordination server (membership, signed netmaps, scheduling metadata, usage counters — never prompts). Data plane = direct device↔device Noise-encrypted UDP (LAN → hole-punch → relay-ciphertext fallback), Rust port of WANKit's transport so Windows/Linux/Mac interoperate. Desktop UI is the single shared `DesktopCompanionWeb` bundle rendered by both the Windows tray (wry) and the Mac app, backed by identical local-API endpoints on each platform.

**Tech Stack:** Rust (axum gateway, teale-node, protocol crate), Swift (mac-app), vanilla JS web UI, SQLite (numbered migrations in `gateway/src/db.rs`), existing relay.

**Conventions binding on every task:**
- TDD: write the failing test first, watch it fail, implement, watch it pass.
- Wire JSON is camelCase (`#[serde(rename_all = "camelCase")]`), matching the existing `protocol/` ↔ Swift Codable convention. Check `protocol/src/relay.rs` for the pattern before writing any new wire type.
- **Never write to `ledger`/`balances` from any PIN code path.** Wave 1 adds a regression test asserting this.
- Commit after each task with a conventional message (`feat(gateway): …`, `feat(node): …`). Do NOT push or open PRs.
- Run `cargo fmt` and `cargo clippy --workspace` before each commit; `cd mac-app && swift build && swift test` for Swift tasks.

**Key existing code to read before touching anything (per wave):**
- Gateway: `gateway/src/db.rs` (MIGRATIONS array + `migrate()`), `gateway/src/auth.rs` (AuthPrincipal), `gateway/src/handlers/groups.rs` (closest CRUD-handler analog), `gateway/src/registry.rs`, `gateway/src/scheduler.rs`, `gateway/src/identity.rs`, `gateway/src/main.rs` route table.
- Node: `node/src/status_server.rs` (AppState, snapshot, local HTTP API on 11437), `node/src/inference.rs`, `node/src/cluster.rs`, `node/src/relay.rs`, `node/src/config.rs`, `node/src/main.rs`.
- Swift transport reference: `mac-app/Sources/WANKit/Noise/*.swift`, `WireGuardTransport.swift`, `STUNClient.swift`, `NATTraversal.swift`.
- UI: `mac-app/Sources/InferencePoolApp/Resources/DesktopCompanionWeb/{index.html,app.js,app.css}`.

---

## Wave 1 — Gateway control plane

Deliverable: gateway exposes the full `/v1/pins/*` API with tests; deployable independently (old clients unaffected).

### Task 1.1: Schema migration 013

**Files:**
- Modify: `gateway/src/db.rs` (append to `MIGRATIONS`)
- Test: `gateway/src/pins.rs` (new module; tests live inline per gateway convention)

- [ ] **Step 1: Write failing test** — create `gateway/src/pins.rs` with only a test module; register `pub mod pins;` in `gateway/src/main.rs` (or `lib.rs` if present — follow how `ledger` is registered):

```rust
#[cfg(test)]
mod tests {
    use crate::db;

    #[test]
    fn migration_013_creates_pin_tables() {
        let pool = db::open_in_memory().expect("db");
        let conn = pool.lock().unwrap();
        for table in ["pins", "pin_roles", "pin_members", "pin_usage", "pin_model_policy"] {
            let n: i64 = conn
                .query_row(
                    "SELECT count(*) FROM sqlite_master WHERE type='table' AND name=?",
                    [table],
                    |r| r.get(0),
                )
                .unwrap();
            assert_eq!(n, 1, "missing table {table}");
        }
    }
}
```

- [ ] **Step 2:** `cargo test -p teale-gateway migration_013` → FAIL (tables missing).
- [ ] **Step 3:** Append migration 013 to `MIGRATIONS` in `gateway/src/db.rs`:

```sql
-- 013_pins.sql — Private Inference Networks control plane. The gateway is
-- coordination-only: membership, netmaps, scheduling metadata, usage COUNTS.
-- PIN paths never touch ledger/balances (see spec §8).
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
```

- [ ] **Step 4:** `cargo test -p teale-gateway migration_013` → PASS.
- [ ] **Step 5:** Commit: `feat(gateway): add PIN schema (migration 013)`

### Task 1.2: `pins.rs` storage layer — lifecycle

**Files:**
- Modify: `gateway/src/pins.rs`

Public API to implement (all take `&DbPool`, return `anyhow::Result<…>`; mirror `ledger.rs` style). Structs `Pin`, `PinRole`, `PinMember`, `PinSettings` (serde for `settings` JSON: `din_contribution_default: bool`, `priority_policy: String` = `"pin_first"`).

```rust
pub fn create_pin(pool, name: &str, owner_account: &str) -> Result<Pin>;         // generates pin_id (uuid) + join code, inserts owner into pin_roles as admin
pub fn generate_join_code() -> String;                                            // XXXX-XXXX-XX from alphabet "ABCDEFGHJKMNPQRSTVWXYZ23456789" (~50 bits)
pub fn find_by_join_code(pool, code: &str) -> Result<Option<Pin>>;                // case-insensitive, dash-insensitive
pub fn submit_join(pool, pin_id, device_id, node_pubkey, display_name) -> Result<()>; // upsert status='pending' (re-knock refreshes requested_at; no-op if already active)
pub fn approve_member(pool, pin_id, device_id, approver_account) -> Result<()>;   // pending→active, joined_at=now, bump netmap_generation
pub fn deny_member(pool, pin_id, device_id) -> Result<()>;                        // delete pending row only
pub fn remove_member(pool, pin_id, device_id, remover) -> Result<()>;             // →removed + bump generation
pub fn set_member_disabled(pool, pin_id, device_id, disabled: bool) -> Result<()>; // bump generation
pub fn update_member(pool, pin_id, device_id, display_name: Option<&str>, serves_models: Option<bool>) -> Result<()>; // bump generation on serves_models change
pub fn rotate_join_code(pool, pin_id) -> Result<String>;
pub fn grant_role(pool, pin_id, account, role, granted_by) -> Result<()>;
pub fn revoke_role(pool, pin_id, account) -> Result<()>;                          // must refuse to remove last admin / owner
pub fn role_of(pool, pin_id, account) -> Result<Option<String>>;                  // owner counts as 'admin'
pub fn pins_for_account(pool, account) -> Result<Vec<PinSummary>>;                // includes pending_count for staff
pub fn pins_for_device(pool, device_id) -> Result<Vec<PinMembershipSummary>>;     // status per pin
pub fn members(pool, pin_id) -> Result<Vec<PinMember>>;
pub fn touch_member_last_seen(pool, pin_id, device_id) -> Result<()>;
pub fn delete_pin(pool, pin_id) -> Result<()>;                                    // soft delete (deleted_at)
```

- [ ] **Step 1:** Write failing tests covering: create→join→approve→active lifecycle; deny deletes; non-admin approval rejected at storage layer (approver must have admin role — assert error); rotate invalidates old code lookup; last-admin protection; `generate_join_code` format regex `^[A-Z2-9]{4}-[A-Z2-9]{4}-[A-Z2-9]{2}$` and dash/case-insensitive lookup; netmap_generation bumps exactly on approve/remove/disable/serves_models change and NOT on rename.
- [ ] **Step 2:** Run → FAIL. **Step 3:** Implement. **Step 4:** Run → PASS.
- [ ] **Step 5:** Commit: `feat(gateway): PIN storage layer (lifecycle, roles, join codes)`

Note: `account_wallets` row must exist for owner (FK). Tests create one via existing `ledger` helpers (see `ledger::link_device_to_account` tests for the pattern).

### Task 1.3: Netmap types + signing

**Files:**
- Create: `protocol/src/pin.rs` (register in `protocol/src/lib.rs`)
- Modify: `gateway/src/pins.rs` (netmap assembly), `gateway/src/identity.rs` (reuse signing)

Wire types in `protocol/src/pin.rs` (camelCase serde):

```rust
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct PinNetmap {
    pub pin_id: String,
    pub name: String,
    pub generation: i64,
    pub issued_at: i64,
    pub members: Vec<PinNetmapMember>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct PinNetmapMember {
    pub device_id: String,
    pub node_pubkey: String,          // Ed25519 hex (relay identity)
    pub display_name: Option<String>,
    pub serves_models: bool,
    pub disabled: bool,
    pub endpoints: Vec<PinEndpoint>,  // {kind: "lan"|"reflexive"|"relay", addr: "ip:port"}
    pub loaded_models: Vec<String>,
    pub last_seen: Option<i64>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct SignedPinNetmap {
    pub netmap: PinNetmap,
    pub gateway_pubkey: String,   // Ed25519 hex
    pub signature: String,        // hex Ed25519 over canonical JSON of `netmap`
}
```

Canonical JSON = `serde_json::to_vec` of `PinNetmap` with **sorted keys** — implement `canonical_json(&PinNetmap) -> Vec<u8>` in `protocol/src/pin.rs` (serialize to `serde_json::Value`, recursively sort maps, then to bytes; same approach PTN used so Swift can reproduce it). `SignedPinNetmap::verify(&self) -> bool` lives in the protocol crate so node and gateway share it.

- [ ] **Step 1:** Failing tests in `protocol`: round-trip serde; canonical bytes stable regardless of field insertion order; sign/verify with `ed25519-dalek` (already a workspace dep — confirm in `Cargo.toml`, add if absent); tampered member ⇒ verify false.
- [ ] **Step 2–4:** FAIL → implement → PASS (`cargo test -p teale-protocol pin`).
- [ ] **Step 5:** In `gateway/src/pins.rs`: `build_signed_netmap(pool, registry, identity, pin_id) -> Result<SignedPinNetmap>` — members = active(+disabled flagged) rows; `loaded_models`/`last_seen` enriched from the in-memory registry when the device is online; endpoints from `pin_members.endpoints`. Test with in-memory DB + stub registry.
- [ ] **Step 6:** Commit: `feat(protocol,gateway): signed PIN netmaps`

### Task 1.4: `/v1/pins` handlers — CRUD + join + non-oracle

**Files:**
- Create: `gateway/src/handlers/pins.rs` (register in `gateway/src/handlers/mod.rs`)
- Modify: `gateway/src/main.rs` (routes)

Routes (all under existing bearer middleware):

```text
POST   /v1/pins                       account-linked device → create (resolve account via ledger::account_for_device; 403 if unlinked)
GET    /v1/pins                       union of pins_for_account (if linked) + pins_for_device
POST   /v1/pins/join                  device principal; ALWAYS 202 {"status":"submitted"} (valid or not); rate-limit 5/hour/device + 20/hour/IP (in-memory HashMap<key, VecDeque<Instant>> in AppState)
GET    /v1/pins/:id                   staff or active member
GET    /v1/pins/:id/members           staff: full; member: roster subset (no endpoints of disabled devices)
POST   /v1/pins/:id/members/:dev/approve   admin
POST   /v1/pins/:id/members/:dev/deny      admin
PATCH  /v1/pins/:id/members/:dev      admin/modelrator: display_name, serves_models, disabled
DELETE /v1/pins/:id/members/:dev      admin
POST   /v1/pins/:id/rotate-code       admin → {"joinCode": "..."}
GET    /v1/pins/:id/join-code         admin → {"joinCode": "..."}
PUT    /v1/pins/:id/roles/:account    admin {"role":"admin"|"modelrator"|null}
PUT    /v1/pins/:id/settings          admin/modelrator
GET    /v1/pins/:id/netmap            active member device (or staff) → SignedPinNetmap; device also POSTs its current endpoints+loaded models here-ish — see Task 1.5
DELETE /v1/pins/:id                   owner only
```

Authorization helper in `handlers/pins.rs`:

```rust
enum PinActor { Staff { account: String, role: StaffRole }, Member { device_id: String } }
fn resolve_actor(pool, principal: &AuthPrincipal, pin_id: &str) -> Result<PinActor, GatewayError>
// Device principal → staff if its linked account holds a role, else active member, else 404 (not 403 — non-enumeration)
```

- [ ] **Step 1:** Failing axum integration tests (follow the existing handler-test pattern — find one with `tower::ServiceExt::oneshot` in `gateway/src/handlers/` and copy the harness): join with bad code → 202 identical body to good code; joiner sees `pending` in GET /v1/pins; approve as admin works; approve as member → 404; rotate; role grant; unknown pin id → 404 for non-members.
- [ ] **Step 2–4:** FAIL → implement → PASS.
- [ ] **Step 5:** Commit: `feat(gateway): /v1/pins handlers with non-oracle join`

### Task 1.5: Device sync endpoint (netmap fetch + endpoint/model advertisement)

**Files:**
- Modify: `gateway/src/handlers/pins.rs`, `gateway/src/pins.rs`

`POST /v1/pins/:id/sync` (member device): body `{"endpoints":[PinEndpoint], "loadedModels":[…], "knownGeneration": n}` → updates `pin_members.endpoints` + `last_seen`, returns `{"netmap": SignedPinNetmap | null}` (null when generation unchanged — cheap poll), plus `{"membership":"pending"|"active"|"none"}` so pending devices poll the same endpoint (a `pending` device gets membership status only, never a netmap), plus `{"modelPolicy":[…]}` for this device (Task 1.7). Devices poll every 60s.

- [ ] **Step 1:** Failing tests: pending device gets `{"membership":"pending"}` and no netmap; active device gets netmap once, then `null` until generation bump; endpoints persisted; removed device gets `"none"` and 200 (not an oracle — same shape).
- [ ] **Step 2–4:** FAIL → implement → PASS. **Step 5:** Commit: `feat(gateway): PIN device sync (netmap poll + endpoint advertisement)`

### Task 1.6: Scheduling endpoint

**Files:**
- Modify: `gateway/src/handlers/pins.rs`, `gateway/src/scheduler.rs` (extract a reusable scoring fn if needed)

`POST /v1/pins/:id/schedule` (active member): `{"model": "...", "ctxEstimate": 8192}` → `{"deviceId","nodePubkey","endpoints":[…]}` or 503 `{"error":"no_capacity"}`. Candidates = active, `serves_models`, not disabled, model in registry `loaded_models` (fall back to netmap `loaded_models` when the device lacks a live registry entry). Score with the existing scheduler scoring for registry-known devices; unknown-liveness devices rank last. **No prompt content in this request — enforce by type (only model + ctxEstimate fields exist).**

- [ ] **Step 1:** Failing tests: picks the loaded+least-loaded member; excludes disabled/`serves_models=false`/pending; consumer-only requester still allowed to schedule; 503 when empty.
- [ ] **Step 2–4:** FAIL → implement → PASS. **Step 5:** Commit: `feat(gateway): PIN-scoped scheduling`

### Task 1.7: Model policy + usage reporting + ledger isolation

**Files:**
- Modify: `gateway/src/handlers/pins.rs`, `gateway/src/pins.rs`

1. `PUT /v1/pins/:id/models/:dev` (admin/modelrator): `{"models":[{"modelId","desiredState"}]}` → upsert `pin_model_policy` (full replace per device). Policy rides back on `/sync` as `modelPolicy`; device reports back via `/sync` body field `"modelPolicyStatus":[{"modelId","appliedState","error"}]` → update `applied_state/last_error`.
2. `POST /v1/pins/:id/usage-report` (active member, serves_models): `{"entries":[{"day","consumerDeviceId","modelId","requests","tokensIn","tokensOut"}]}` → additive upsert into `pin_usage`. Idempotency: entries carry a `batchId`; store seen batch ids in `pin_usage_batches(pin_id, provider_device_id, batch_id, received_at)` table (add to migration 013 in this task via migration 014 if 013 already committed — prefer adding table in this task as migration 014).
3. `GET /v1/pins/:id/usage?from=YYYY-MM-DD&to=…&by=device|model|day` → aggregates; members get only their own consumer rows.
4. **Ledger isolation regression test**: run join→approve→usage-report→schedule flow, then assert `SELECT count(*) FROM ledger` and `balances` totals unchanged from before.

- [ ] **Step 1:** Failing tests for all four. **Step 2–4:** FAIL → implement → PASS.
- [ ] **Step 5:** Commit: `feat(gateway): PIN model policy, usage rollups, ledger isolation`

---

## Wave 2 — Data plane + node (Windows/Linux — the 90% platform)

Deliverable: two `teale-node` instances on one LAN serve each other PIN inference end-to-end with the gateway coordinating; PIN > DIN queue priority; usage reported.

### Task 2.1: Noise golden vectors from Swift

**Files:**
- Create: `mac-app/Tests/WANKitTests/NoiseVectorDumpTests.swift`
- Create: `protocol/tests/fixtures/noise_vectors.json`

The Rust transport must interop with WANKit's Noise (`mac-app/Sources/WANKit/Noise/`: `NoiseHandshake.swift` — pattern, DH, cipher, hash; `BLAKE2s.swift`; `NoiseCrypto.swift`). Write a Swift test that runs a full handshake between two in-memory parties with **fixed** static/ephemeral keys (inject via test hooks; add an internal init if needed) and dumps JSON: keys, each handshake message hex, transport-key hex, and one encrypted payload hex for each direction. Copy output into `protocol/tests/fixtures/noise_vectors.json`.

- [ ] **Step 1:** Read `NoiseHandshake.swift` fully; document (in the fixture JSON header) the exact pattern (XX or IK), prologue, and any customizations.
- [ ] **Step 2:** Write + run the dump test: `cd mac-app && swift test --filter NoiseVectorDump` → vectors printed; commit fixture.
- [ ] **Step 3:** Commit: `test(protocol): Noise interop golden vectors from WANKit`

### Task 2.2: Rust Noise implementation

**Files:**
- Create: `node/src/pin/mod.rs`, `node/src/pin/noise.rs`
- Modify: `node/src/main.rs` (`mod pin;`), `node/Cargo.toml` (add `blake2` = "0.10", `chacha20poly1305` = "0.10", `x25519-dalek` = "2" — or `snow` if and only if the vectors prove the Swift impl is a standard Noise pattern snow can be configured to match)

API:

```rust
pub struct NoiseInitiator { /* holds local static X25519 key */ }
pub struct NoiseResponder { … }
pub struct NoiseSession { pub fn encrypt(&mut self, plaintext: &[u8]) -> Vec<u8>; pub fn decrypt(&mut self, ct: &[u8]) -> Result<Vec<u8>>; pub remote_static: [u8;32]; }
```

- [ ] **Step 1:** Failing test loading `noise_vectors.json`, replaying both roles byte-for-byte.
- [ ] **Step 2–4:** FAIL → implement → PASS (`cargo test -p teale-node pin::noise`).
- [ ] **Step 5:** Commit: `feat(node): Noise handshake wire-compatible with WANKit`

### Task 2.3: UDP transport (framing, fragmentation, sessions)

**Files:**
- Create: `node/src/pin/transport.rs`

Match WANKit's wire format exactly — read `WireGuardTransport.swift` (`FragmentBuffer`, frame header layout, keepalive cadence 20 s) and replicate: session accept/dial over `tokio::net::UdpSocket`, fragment/reassemble `ClusterMessage` JSON payloads, keepalives, idle teardown (match WANKit's timeout). Peer authentication: after handshake, map `remote_static` X25519 key → expected key derived per netmap entry (WANKit derives WG key from identity — read `WANNodeIdentity` in `WANConfiguration.swift` and mirror the derivation in `node/src/identity.rs`).

- [ ] **Step 1:** Failing loopback tests: dial↔accept on 127.0.0.1, exchange a >64 KiB message (forces fragmentation), unknown-peer static key rejected, keepalive keeps the session alive past idle timeout.
- [ ] **Step 2–4:** FAIL → implement → PASS.
- [ ] **Step 5:** Commit: `feat(node): PIN UDP transport (Noise sessions, fragmentation)`

### Task 2.4: Discovery + endpoints (LAN mDNS, STUN)

**Files:**
- Create: `node/src/pin/discovery.rs`
- Modify: `node/Cargo.toml` (`mdns-sd = "0.11"`), `node/src/pin/mod.rs`

Advertise `_teale-pin._udp.local.` with TXT `deviceId=<id>` and the transport port; browse to collect LAN peer addrs. STUN reflexive address via a minimal binding-request client (port the logic from `STUNClient.swift`; server list from same constants). Produce `Vec<PinEndpoint>` (`lan` entries + `reflexive`) for `/sync` advertisement. Dial order in the connector: netmap `lan` addrs (if same-subnet reachable) → `reflexive` (simultaneous-open hole punch, port logic from `NATTraversal.swift`) → relay fallback (Task 2.5).

- [ ] **Step 1:** Failing tests: two in-process discovery instances find each other on loopback mDNS; STUN client parses a canned binding response; endpoint list shape.
- [ ] **Step 2–4:** FAIL → implement → PASS. **Step 5:** Commit: `feat(node): PIN LAN/STUN discovery`

### Task 2.5: PIN manager (join, netmap cache, sync loop, relay fallback)

**Files:**
- Create: `node/src/pin/manager.rs`
- Modify: `node/src/config.rs` (`[pin]` section: `join_code` optional preseed for mass deploy, `data_dir` default), `node/src/main.rs` (spawn manager)

`PinManager` responsibilities:
- Join: `join(code)` → POST `/v1/pins/join`; track pending pins.
- Sync loop: every 60 s (and on demand) POST `/v1/pins/:id/sync` per known pin with current endpoints + loaded models + model-policy status; verify `SignedPinNetmap` signature against pinned gateway pubkey (source: existing gateway pubkey the node already trusts for wallet sync — reuse that constant/config); persist netmap JSON to `{data_dir}/pin/{pin_id}/netmap.json`; reject cached netmaps older than 24 h (`issued_at`).
- Config preseed: on startup, if `config.pin.join_code` set and device not a member of any pin matching, auto-submit join (idempotent — 202 always). This is the 200-laptop IT-rollout path: bake the code into the installer config; admin batch-approves.
- Relay fallback dial: wrap existing relay session machinery (`node/src/relay.rs`) carrying Noise ciphertext frames as relayData (E2E: relay sees ciphertext only).
- Expose state snapshot for the UI: memberships, statuses, peer table.

- [ ] **Step 1:** Failing tests with a mock gateway (spawn axum on an ephemeral port — reuse Wave 1 handlers with in-memory DB for realism): join→pending→approve→sync yields verified netmap on disk; tampered signature rejected; stale cache rejected; preseeded config auto-joins.
- [ ] **Step 2–4:** FAIL → implement → PASS. **Step 5:** Commit: `feat(node): PIN manager (join, signed netmap cache, sync loop)`

### Task 2.6: Serving path + PIN>DIN priority queue

**Files:**
- Create: `node/src/pin/serve.rs`
- Modify: `node/src/inference.rs` (queue integration), `node/src/pin/mod.rs`

Accept transport sessions, authenticate peer against current netmap (active, not disabled), handle `ClusterMessage::InferenceRequest` through the same backend used by DIN traffic, stream `InferenceChunk`/`InferenceComplete` back over the session.

Priority queue — read `node/src/inference.rs` first; integrate at the existing admission point:

```rust
pub enum LaneClass { Pin, Din }
pub struct PriorityAdmission {
    pin: VecDeque<QueuedRequest>,
    din: VecDeque<QueuedRequest>,
    din_priority_equal: bool,   // per-device setting from config/UI
}
impl PriorityAdmission {
    pub fn push(&mut self, lane: LaneClass, req: QueuedRequest);
    pub fn pop(&mut self) -> Option<QueuedRequest>;  // pin lane first unless din_priority_equal (then FIFO across both by enqueue time)
    pub fn depth(&self) -> usize;                    // combined — feeds existing DIN heartbeat queue_depth
}
```

No preemption: in-flight DIN generation completes; PIN jumps the *wait* line only.

- [ ] **Step 1:** Failing tests: `PriorityAdmission` ordering (pin-first; equal mode FIFO); combined depth; serve path rejects a session from a device absent from the netmap; end-to-end in-process: enqueue 1 DIN + 1 PIN while busy → PIN dequeued first.
- [ ] **Step 2–4:** FAIL → implement → PASS. **Step 5:** Commit: `feat(node): PIN serving with PIN-over-DIN queue priority`

### Task 2.7: Demand path + usage batcher

**Files:**
- Create: `node/src/pin/client.rs`, `node/src/pin/usage.rs`
- Modify: `node/src/status_server.rs` (local chat completions route for PIN models)

Demand: local OpenAI-compatible request for a PIN model → `POST /v1/pins/:id/schedule` → dial target (LAN→punch→relay) → stream. On dial failure/`InferenceError`: re-schedule excluding failed device, max 2 cascades. Offline fallback: gateway unreachable → pick least-known-loaded from cached netmap peers reachable on LAN (probe with a 1 s connect timeout), round-robin among ties.

Usage batcher (`usage.rs`): provider side records `(pin, consumer, model, tokens_in, tokens_out)` per completed request into a disk-backed queue (`{data_dir}/pin/usage-queue.jsonl`); flush every 60 s or 50 entries with a UUID `batchId`; delete lines only after 2xx; retry with backoff — offline periods backfill.

- [ ] **Step 1:** Failing tests: schedule→dial→stream against an in-process peer + mock gateway; cascade on peer failure; offline fallback picks a LAN peer; batcher flush/ack/backfill semantics (kill the mock gateway mid-test, restore, assert delivery exactly once by batchId).
- [ ] **Step 2–4:** FAIL → implement → PASS. **Step 5:** Commit: `feat(node): PIN demand path and durable usage reporting`

### Task 2.8: Model policy reconciliation + local API for UI

**Files:**
- Create: `node/src/pin/policy.rs`
- Modify: `node/src/status_server.rs` (add `/pins/*` local routes)

Policy: on each sync, diff `modelPolicy` vs local state; honor `allow_remote_models` local opt-out (config + UI toggle; when off, report `appliedState:"opted_out"`); execute via existing `AppState::start_download` / `load_model`; refuse models exceeding the existing fit estimate and report the error string; report per-model status on next sync.

Local API (the shared web UI consumes these — the **exact same JSON contract** is implemented on Mac in Task 3.3; write the contract down in `docs/pin-local-api.md` as part of this task):

```text
GET  /pins                         → {networks:[{pinId,name,membership,roleOfLinkedAccount,pendingCount,deviceCounts,…}]}
POST /pins/join {code}             → 202
POST /pins/create {name}           → pin summary (requires linked account)
GET  /pins/:id                     → detail: members table rows (name, platform?, status, servesModels, loadedModels, lastSeen, tokensToday)
GET  /pins/:id/requests            → pending list (staff)
POST /pins/:id/approve {deviceId}  / POST /pins/:id/deny {deviceId}
POST /pins/:id/members/:dev        → patch {displayName?, servesModels?, disabled?}
DELETE /pins/:id/members/:dev
POST /pins/:id/rotate-code         → {joinCode}
GET  /pins/:id/join-code           → {joinCode} (admin)
GET  /pins/:id/usage?by=…          → rows for charts
PUT  /pins/:id/models/:dev {models:[…]} ; GET /pins/:id/models → policy+applied matrix
POST /pins/:id/leave
GET/POST /pins/settings/local      → {allowRemoteModels, dinPriorityEqual, dinContribute}
```

Node implements these by proxying to the gateway with its device bearer (staff actions work because the device's linked account holds the role) and merging local state.

- [ ] **Step 1:** Failing tests: policy diff→download/load invocation (mock backend), opt-out path, fit-refusal path; local API happy paths against mock gateway.
- [ ] **Step 2–4:** FAIL → implement → PASS. **Step 5:** Commit: `feat(node): model-policy reconciliation + local /pins API`

---

## Wave 3 — Mac app parity (Swift)

Deliverable: Mac app is a full PIN citizen using the same gateway API and an identical local `/pins` contract; PTN retired.

### Task 3.1: PINKit (gateway client + netmap cache)

**Files:**
- Create: `mac-app/Sources/PINKit/PINManager.swift`, `PINGatewayClient.swift`, `PINNetmap.swift`, `PINStore.swift`
- Modify: `mac-app/Package.swift` (new target + test target)

Mirror `node/src/pin/manager.rs`: Codable types matching `protocol/src/pin.rs` camelCase exactly; canonical-JSON signature verification (reuse the sorted-keys canonicalization already in `PTNCertificate.swift` — lift that helper, don't rewrite it); disk cache in Application Support; 60 s sync loop; join/create/approve/etc. calls via the existing `GatewayKit` auth/bearer plumbing.

- [ ] **Step 1:** Failing XCTests: decode a `SignedPinNetmap` fixture **generated by the Rust tests** (commit a shared fixture `protocol/tests/fixtures/signed_netmap.json` from Task 1.3 and reference it from both test suites); verify signature; reject tampered/stale.
- [ ] **Step 2–4:** FAIL → implement → PASS (`swift test --filter PINKit`).
- [ ] **Step 5:** Commit: `feat(mac): PINKit gateway client with signed netmap verification`

### Task 3.2: Data plane + priority queue on Mac

**Files:**
- Modify: `mac-app/Sources/WANKit/WANManager.swift` (accept/dial keyed by PIN netmap), inference dispatch site in `mac-app/Sources/TealeSDK/` (find where DIN `InferenceRequest`s are admitted — grep `InferenceRequest` — and wrap with a Swift `PriorityAdmission` equivalent of Task 2.6's)
- Create: `mac-app/Sources/PINKit/PINServing.swift`, `PINClient.swift`

Serving: authenticate inbound WAN sessions against the PIN netmap (replacing PTN certificate checks); route to the existing Swift inference engine; record usage into a `PINUsageBatcher` (JSONL in Application Support, same flush semantics as Task 2.7). Demand: schedule→dial→stream with the same cascade/offline rules. Interop requirement: a Mac must serve a Rust node and vice versa — the vectors from Task 2.1 guarantee handshake compat; add one integration test that pins the fragment framing golden bytes (encode a fixed ClusterMessage, assert hex) in **both** repos' test suites (`node/src/pin/transport.rs` test + `WANKitTests`).

- [ ] **Step 1:** Failing tests (framing golden bytes; admission ordering; netmap-gated accept). **Step 2–4:** FAIL → implement → PASS.
- [ ] **Step 5:** Commit: `feat(mac): PIN serving/demand over WANKit with PIN-first admission`

### Task 3.3: LocalAPI `/pins` parity

**Files:**
- Modify: `mac-app/Sources/LocalAPI/` (add routes; follow existing route registration), backed by PINKit
- Test: contract test comparing responses to `docs/pin-local-api.md`

Implement the exact contract from Task 2.8 so `DesktopCompanionWeb` needs zero platform branching.

- [ ] **Step 1:** Failing contract XCTests (fixture-driven: same JSON field names as the doc). **Step 2–4:** FAIL → implement → PASS. **Step 5:** Commit: `feat(mac): local /pins API parity with node`

### Task 3.4: Retire PTN

**Files:**
- Delete: `mac-app/Sources/TealeNetKit/` (all 6 files), PTN payloads in `mac-app/Sources/*/RemoteControlTypes.swift`
- Modify: `mac-app/Sources/ClusterKit/Cluster/ClusterManager.swift` (drop `passcode`/`organizationID` fields ~lines 66-69), `protocol/src/hardware.rs` + Swift `NodeCapabilities` (replace `ptnIDs` with `pinIDs` carrying active PIN memberships — keep serde alias `ptnIDs` for wire back-compat), `mac-app/Package.swift`

- [ ] **Step 1:** Grep for every `PTN`/`TealeNet` reference; delete/replace; keep `swift build` + `swift test` green; `cargo test --workspace` green (wire alias test for `ptnIDs`).
- [ ] **Step 2:** Commit: `refactor: retire PTN in favor of PIN`

---

## Wave 4 — Shared desktop UI (`DesktopCompanionWeb`)

Deliverable: “networks” is a first-class view in both apps.

### Task 4.1: Networks view skeleton + navigation

**Files:**
- Modify: `mac-app/Sources/InferencePoolApp/Resources/DesktopCompanionWeb/index.html` (add `<button class="nav-link" data-view-button="networks">` after `demand`, and a `<section class="view" data-view="networks">` with: network list panel, create/join forms, and a detail panel with tab strip `devices | models | usage | settings`), `app.css` (reuse `.model-table`, `.table-wrap` styles; add `.pin-badge`, `.pin-pending-banner`)

- [ ] **Step 1:** Static skeleton renders; nav switches views (existing `data-view-button` wiring in app.js handles registration — add `networks` to its view list).
- [ ] **Step 2:** Commit: `feat(ui): networks view skeleton`

### Task 4.2: Networks logic (list/join/create/approve/devices)

**Files:**
- Modify: `app.js`

Poll `GET /pins` on view activation + 30 s interval (match existing snapshot polling helper). Render: network cards with membership state; pending-approval banner with count for staff; devices table (name, platform, status dot, serving toggle, models, last seen, tokens today) with role-gated row actions (rename inline, disable, remove); join form (code input, normalized uppercase/dashes) showing the pending state after submit; create form; join-code reveal+copy+rotate in settings (admin only). All fetches via the existing `apiUrl()`/`fetch` helper (line ~975).

- [ ] **Step 1:** Wire everything against a running `teale-node` with mock/local gateway; manually verify each action round-trips (this UI codebase has no JS test harness — do not invent one; verification is the Wave 6 fleet pass plus endpoint tests already covering the contract).
- [ ] **Step 2:** Commit: `feat(ui): networks management (join, approve, devices)`

### Task 4.3: Models matrix, usage charts, local settings

**Files:**
- Modify: `app.js`, `index.html`

Models tab: devices × models grid from `GET /pins/:id/models`; staff set desired state per cell (`loaded/downloaded/none`); applied-state chips (ready / in-progress / failed(tooltip=lastError) / opted-out). Usage tab: day/device/model toggles rendering the same lightweight bar-chart approach used in the wallet view (grep `wallet` chart code in app.js and reuse). Settings tab: network settings (staff) + local device toggles (`allowRemoteModels`, `dinContribute`, `dinPriorityEqual`) via `/pins/settings/local`. **No credits/currency anywhere in the networks view.**

- [ ] **Step 1:** Manual round-trip verification as in 4.2. **Step 2:** Commit: `feat(ui): PIN model matrix, usage, settings`

---

## Wave 5 — CLI

### Task 5.1: `teale-node pin …` subcommands (Windows/Linux)

**Files:**
- Modify: `node/src/main.rs` (arg parsing — read how existing flags/subcommands are parsed first and follow that pattern), create `node/src/pin/cli.rs`

Commands (all talk to the local status server on 11437, `--json` flag for machine output, human tables default):
`pin status | pin create <name> | pin join <code> | pin requests | pin approve <device> | pin deny <device> | pin devices | pin rename-device <device> <name> | pin remove-device <device> | pin rotate-code | pin models set <device> <model…> [--state loaded] | pin usage [--by device|model|day] | pin leave` — `--net <name-or-id>` selects among multiple networks, defaulting when unambiguous.

- [ ] **Step 1:** Failing tests for arg parsing + table rendering (unit-test the formatter with fixture JSON). **Step 2–4:** FAIL → implement → PASS. **Step 5:** Commit: `feat(node): pin CLI`

### Task 5.2: `teale pin …` (Mac TealeCLI)

**Files:**
- Modify: `mac-app/Sources/TealeCLI/` (mirror an existing command file for registration pattern), create `Commands/PinCommand.swift`

Same command surface as 5.1, hitting the Mac LocalAPI.

- [ ] **Step 1:** Failing tests → implement → PASS (`swift test --filter PinCommand`). **Step 2:** Commit: `feat(mac): teale pin CLI`

---

## Wave 6 — Validation, hardening, rollout kit

### Task 6.1: Cross-implementation integration test

**Files:**
- Create: `stress/src/scenarios/pin.rs` (or follow stress/'s existing scenario layout)

Scenario: in-process gateway (in-memory DB) + N Rust node instances; create pin, preseed-join all, approve, push a model policy (stub backend), run mixed PIN+DIN load, revoke one device mid-stream. Assert: PIN latency < DIN latency under saturation (queue priority observable), revoked device's sessions rejected within one sync interval, `pin_usage` totals match generated traffic exactly, ledger delta = DIN traffic only.

- [ ] **Step 1:** Write scenario → run → fix until green. **Step 2:** Commit: `test(stress): PIN end-to-end scenario`

### Task 6.2: Fleet validation (live)

Using the 6-Mac Tailscale fleet + at least one Windows node (`docs/fleet-deployment-windows.md`, `scripts/fleet-deploy-mac.sh`):

- [ ] Deploy gateway to staging; create a real PIN; join all fleet machines (mix of preseed + manual); batch-approve; push a small model loadout; run chat from a consumer device hitting a Mac provider from a Windows consumer and vice versa (the interop moment of truth); pull usage; verify zero ledger movement; kill gateway and verify LAN-only inference continues.
- [ ] Record every failure found → fix → re-run until clean twice consecutively.
- [ ] Commit fixes: `fix(pin): fleet validation findings`

### Task 6.3: Enterprise rollout kit (200-employee company, 90% Windows)

**Files:**
- Create: `docs/pin-enterprise-rollout.md`
- Modify: `node/installer/` (accept `PIN_JOIN_CODE` property → writes `[pin] join_code` into `teale-node.windows.toml`), `node/teale-tray` first-run: if a preseeded join is pending, surface a “Waiting for admin approval — <network>” state instead of a blank networks view

Runbook contents: IT deploys installer with `PIN_JOIN_CODE` via MSI property/Intune; admin batch-approves from the app or `teale-node pin approve` loop; modelrator pushes the standard loadout; Mac 10% join via code manually; day-2 ops (rotate code on offboarding, remove devices, usage review); troubleshooting (firewall/UDP, mDNS on corp networks, relay-fallback confirmation).

- [ ] **Step 1:** Installer property plumbing + first-run state; manual verify on a Windows VM or fleet Windows box.
- [ ] **Step 2:** Write the runbook. **Step 3:** Commit: `feat(rollout): PIN enterprise provisioning + runbook`

### Task 6.4: Docs + spec truth-up

- [ ] Update `docs/protocol.md` with PIN wire additions; add `docs/pin-local-api.md` if not landed in 2.8; re-read the spec and amend any place implementation diverged (note divergences in a “Deviations” section rather than silently rewriting history).
- [ ] Commit: `docs: PIN protocol + operations`

---

## Self-review notes (spec coverage)

- Spec §4 roles/permissions → Tasks 1.2/1.4 (matrix enforced in `resolve_actor` + storage guards). Modelrator = `StaffRole::Modelrator` allowed on PATCH members (rename/serves), settings, models; denied on approve/deny/remove/rotate/roles/delete — encode exactly this in the 1.4 tests.
- §5 control plane → 1.1–1.7. §6 data plane → 2.1–2.7 + 3.2. §7 demand → 2.7/3.2 + UI. §8 usage → 1.7/2.7/3.2. §9 DIN priority → 2.6/3.2 (+`dinPriorityEqual`). §10 fleet admin → 1.7/2.8/3.2/4.3. §11 UI → Wave 4. §12 CLI → Wave 5. §13 security → non-oracle (1.4), rate limits (1.4), signature verification (1.3/2.5/3.1), netmap-gated accept (2.6/3.2). §14 edge cases → last-admin (1.2), races via generation bump (1.2), offline (2.5/2.7), multi-PIN loadout conflict → device-side: union of downloads, `loaded` conflicts surface as `appliedState:"conflict"` (2.8). §15 testing → per-task TDD + 6.1/6.2. §17 Android serving out of scope — consumer-join is deferred with it (Android app untouched this cycle; noted in 6.4 docs).
- Windows-first check: Waves 2 (node) and 4 (shared UI) + 6.3 installer cover the 90% platform before Mac parity blocks anything; Wave 3 can run in parallel after Wave 1.
