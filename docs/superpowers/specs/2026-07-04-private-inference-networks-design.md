# Private Inference Networks (PIN) — Design

**Date:** 2026-07-04
**Status:** Draft for review
**Supersedes:** Private TealeNet (PTN, `mac-app/Sources/TealeNetKit/`) and the passcode/organizationID routing experiment (commit `8f61ac0`).

## 1. Summary

A **Private Inference Network (PIN)** lets a business, team, or family run LLM inference entirely on their own devices. Prompts and completions never leave the network's devices; Teale's gateway acts only as a **coordination server** (the Tailscale model: central control plane, decentralized data plane). Devices join with a shareable network code plus admin approval, admins and modelrators manage the fleet from the desktop apps or CLI, token usage is tracked per device with **no credit/ledger involvement**, and devices can optionally contribute excess capacity to the public DIN with PIN traffic holding queue priority.

## 2. Motivation

There is a growing movement toward running open-weight models on company-owned hardware so prompts and data are not fed to frontier labs. Teale already has the substrate — device identity, relay, scheduler, supply mode, desktop apps — but the previous attempt (PTN) failed because it was Apple-only, had no central admin surface, and its device-held CA key made recovery and multi-admin painful. PIN rebuilds the feature on the gateway + Rust node so it is cross-platform, administrable, and first-class.

## 3. Terminology

| Term | Meaning |
|---|---|
| PIN | A private inference network (the network itself). |
| Join code | The stable, shareable, admin-rotatable code used to request membership (also colloquially "the PIN"). |
| Coordination server | The Teale gateway acting as control plane: membership, netmaps, scheduling metadata, usage counters. Never sees prompt content. |
| Netmap | A gateway-signed snapshot of a PIN's membership (device pubkeys, roles, endpoints, generation number) that devices cache and use to authenticate peers. |
| Modelrator | The fleet-ops role (intentional spelling): moderates/sets models and operational settings. |
| DIN | The public distributed inference network (existing credit-based system). |

## 4. Roles & permissions

Three roles. `admin` and `modelrator` attach to **Teale accounts** (people). `member` attaches to **devices**, which may be account-less.

| Capability | admin | modelrator | member |
|---|---|---|---|
| Approve / deny join requests | ✓ | — | — |
| Remove / disable devices | ✓ | — | — |
| Assign roles (grant/revoke admin, modelrator) | ✓ | — | — |
| Rotate join code | ✓ | — | — |
| Delete network | ✓ (owner) | — | — |
| Set model loadouts, push model loads | ✓ | ✓ | — |
| Network operational settings (DIN defaults, priority policy) | ✓ | ✓ | — |
| Rename devices, toggle a device's "serves models" flag | ✓ | ✓ | — |
| View devices, status, usage | ✓ | ✓ | ✓ (own usage; member-visible roster) |
| Consume inference from the PIN | ✓ | ✓ | ✓ |
| Serve models (if serving enabled on the device) | ✓ | ✓ | ✓ |

Per-device capability flags (orthogonal to role): `serves_models` (set by admin/modelrator; replaces PTN's provider/consumer roles). Per-device **local** opt-outs, controlled only on the device itself: decline remote model pushes; DIN contribution toggle.

The creating account is the **owner** (an admin that cannot be demoted by other admins; ownership is transferable). Every PIN must have ≥1 admin at all times; the last admin cannot leave without transferring.

A device may belong to **multiple PINs** simultaneously and to the DIN.

## 5. Control plane (gateway)

### 5.1 Schema (new SQLite tables)

```sql
pins(
  pin_id TEXT PK,                 -- uuid
  name TEXT,                      -- display name, e.g. "teale-hq"
  join_code TEXT,                 -- plaintext: admins must display it wifi-password-style;
                                  -- it only grants the right to file a join request
  join_code_generation INTEGER,   -- bumped on rotate
  owner_account_user_id TEXT,     -- FK account_wallets
  netmap_generation INTEGER,      -- bumped on any membership/role change
  settings TEXT,                  -- JSON: din_contribution_default, priority_policy, ...
  created_at INTEGER, deleted_at INTEGER
)

pin_roles(                        -- people: admin / modelrator
  pin_id TEXT, account_user_id TEXT, role TEXT CHECK(role IN ('admin','modelrator')),
  granted_by TEXT, granted_at INTEGER,
  PRIMARY KEY (pin_id, account_user_id)
)

pin_members(                      -- devices
  pin_id TEXT, device_id TEXT,
  node_pubkey TEXT,               -- Ed25519 hex, from join request
  display_name TEXT,
  status TEXT CHECK(status IN ('pending','active','disabled','removed')),
  serves_models INTEGER DEFAULT 1,
  approved_by TEXT, requested_at INTEGER, joined_at INTEGER, last_seen INTEGER,
  removed_at INTEGER, removed_by TEXT,
  PRIMARY KEY (pin_id, device_id)
)
-- join requests are pin_members rows with status='pending'
-- (single lifecycle table; deny = delete row; approve = status→active + netmap bump)

pin_usage(                        -- daily aggregates; counts only, never credits
  pin_id TEXT, day TEXT,          -- YYYY-MM-DD (UTC)
  provider_device_id TEXT, consumer_device_id TEXT, model_id TEXT,
  requests INTEGER, tokens_in INTEGER, tokens_out INTEGER,
  PRIMARY KEY (pin_id, day, provider_device_id, consumer_device_id, model_id)
)

pin_model_policy(                 -- admin/modelrator-desired loadout
  pin_id TEXT, device_id TEXT, model_id TEXT,
  desired_state TEXT CHECK(desired_state IN ('loaded','downloaded','none')),
  set_by TEXT, set_at INTEGER,
  applied_state TEXT,             -- device-reported reconciliation status
  applied_at INTEGER, last_error TEXT,
  PRIMARY KEY (pin_id, device_id, model_id)
)
```

The existing `devices`, `account_wallets`, `account_devices`, and token tables are reused unchanged. **The `ledger`/`balances` tables are never written by PIN traffic.**

### 5.2 API surface (`/v1/pins/*`)

Auth: existing bearer paths — device tokens for device-scoped calls, account-backed auth for admin/modelrator calls.

```
POST   /v1/pins                                create (account auth) → pin_id, join code (shown once + retrievable by admin)
GET    /v1/pins                                list my networks (as staff account or member device)
POST   /v1/pins/join                           {join_code, device info, node_pubkey, signature}
                                               → always 202 "request submitted" (non-oracle)
GET    /v1/pins/{id}                           network detail (role-scoped)
GET    /v1/pins/{id}/members                   roster + live status
POST   /v1/pins/{id}/members/{dev}/approve     admin
POST   /v1/pins/{id}/members/{dev}/deny        admin
PATCH  /v1/pins/{id}/members/{dev}             rename, disable/enable, serves_models (admin/modelrator per matrix)
DELETE /v1/pins/{id}/members/{dev}             remove (admin)
POST   /v1/pins/{id}/rotate-code               admin → new join code
PUT    /v1/pins/{id}/roles/{account}           grant/revoke admin|modelrator (admin)
PUT    /v1/pins/{id}/settings                  admin/modelrator per matrix
GET    /v1/pins/{id}/netmap                    member device → signed netmap (long-poll / push-invalidated)
POST   /v1/pins/{id}/schedule                  member device → {model, ctx_estimate} → target device + connection hints
PUT    /v1/pins/{id}/models/{dev}              set desired loadout (admin/modelrator)
POST   /v1/pins/{id}/usage-report              provider device → batched counters
GET    /v1/pins/{id}/usage                     aggregates (role-scoped)
DELETE /v1/pins/{id}                           owner
```

### 5.3 Join flow

1. Admin shares the join code out-of-band ("give me the PIN"). Networks are **not discoverable or searchable**.
2. Joining device: `POST /v1/pins/join` with the code, device metadata (name, platform, hardware caps), its node pubkey, and an Ed25519 signature over a challenge. Response is `202 request submitted` **whether or not the code is valid** — the endpoint is not an oracle for network existence. Rate-limited per device and per source.
3. Valid code → `pin_members` row with `status='pending'`; admins are notified (push via relay to their signed-in devices; badge in app; visible in CLI).
4. Admin approves → status `active`, `netmap_generation` bumped, joiner notified via relay push (or discovers on next poll). Deny → row deleted; the device sees the same "pending" state either way until an approval materializes (no denial oracle).
5. Rotating the join code invalidates future knocks only; existing members are unaffected.

Join code format: `XXXX-XXXX-XX` from a 32-character unambiguous alphabet (~50 bits). Stored plaintext (admins must be able to *read* the current code to share it, wifi-password-style; the code is a low-privilege credential that only grants the ability to file a join request — approval is the actual gate). Revealed via API only to admins.

### 5.4 Netmap & revocation

- The netmap for a PIN contains: generation, and for each active member — device_id, node pubkey, display name, `serves_models`, advertised endpoints (LAN addrs, STUN-reflexive addr), loaded models, last-seen. Signed by the gateway's existing Ed25519 identity; devices pin the gateway pubkey.
- Devices cache the netmap (TTL ~24 h for offline operation) and refresh on relay push whenever the generation bumps.
- **Revocation**: remove/disable → generation bump → push. Peers drop the removed device on refresh; worst-case staleness is minutes online, bounded by cache TTL offline. Removed devices also lose control-plane auth immediately.

## 6. Data plane

### 6.1 Transport

Direct device-to-device, E2E encrypted. Reuse the WANKit design — Noise handshake over UDP with fragment/reassembly, STUN, NAT traversal, keepalives (`mac-app/Sources/WANKit/`) — and **port it to the Rust node** (`node/`) so Mac, Windows, and Linux all interoperate: one wire protocol, two implementations, mirroring how `protocol/` already mirrors the Swift types. Peer authentication binds the Noise static key to the node pubkey listed in the current netmap.

Connection ladder: **LAN discovery (mDNS/Bonjour) → UDP hole-punch (STUN) → relay fallback.** The relay carries only Noise ciphertext, so even the fallback path leaks no prompt content to Teale infrastructure.

Inference messages reuse the existing `ClusterMessage` set (`InferenceRequest/Chunk/Complete/Error`, `Heartbeat`, `LoadModel/ModelLoaded/ModelLoadError`) over the encrypted channel.

### 6.2 Scheduling

- **Online (default):** the requesting device calls `POST /v1/pins/{id}/schedule` with metadata only (model id, context estimate — never the prompt). The gateway answers from its heartbeat registry, scoped to the PIN's active `serves_models` members, using the existing scheduler scoring (EWMA tps × queue × thermal × loaded-weights). Response: target device + connection hints. Requester dials direct.
- **Offline / LAN-only fallback:** if the gateway is unreachable, the device schedules locally from the cached netmap plus direct peer heartbeats (least-loaded among reachable peers with the model loaded). A LAN-only PIN keeps working with degraded placement quality. This is a deliberate enterprise feature, not just resilience.
- Retry: on dial failure or `InferenceError`, requester re-schedules excluding the failed device (max 2 cascades), matching DIN semantics.

## 7. Demand entry points

1. **Teale app chat**: the PIN appears as a model source; its available models are the union of what active serving members have loaded.
2. **Local OpenAI-compatible API** on every member device (existing LocalAPI on Mac, `status_server` on node): `http://localhost:{port}/v1/chat/completions` with PIN-scoped model ids. Any tool on a member machine (IDEs, scripts, internal apps) gets private inference with zero additional auth infrastructure.
3. PIN-scoped API keys for non-member servers: **deferred** to the enterprise tier (Phase 3).

## 8. Token accounting (no credits)

- The **provider** device is the source of truth: per completed request it records `(pin_id, consumer_device_id, model_id, tokens_in, tokens_out)` and reports batched counters to `POST /v1/pins/{id}/usage-report` (flush every ~60 s or 50 requests; durable local queue so offline periods backfill).
- Gateway upserts into `pin_usage` daily aggregates. Admin/modelrator see usage by device, model, and consumer; members see their own.
- **No ledger writes, no balances, no settlement.** PIN work earns zero credits. The same device's DIN traffic flows through the existing ledger untouched.

## 9. DIN interplay & priority

- Per-device local toggle: *Contribute excess capacity to DIN* (reuses existing supply mode; network setting `din_contribution_default` seeds the default for newly joined devices, device keeps final say).
- The node maintains a **two-level priority queue**: PIN requests are admitted ahead of queued DIN requests. No mid-generation preemption in v1 — an in-flight DIN request completes; PIN requests jump the wait line only.
- "Unless otherwise notated": per-device setting `din_priority = pin_first (default) | equal`.
- Heartbeats to the DIN registry already carry queue depth, so the public scheduler naturally routes around PIN-busy devices. A device serving both counts PIN load in `queue_depth` but reports PIN token counts only to `pin_usage`, never to the ledger.

## 10. Fleet administration (model management)

- Admin/modelrator edits a device's desired loadout (`pin_model_policy`): per model, `loaded` / `downloaded` / `none`.
- Gateway pushes the delta to the device via relay using the existing `LoadModel` message family; the device reconciles (download → load → report `ModelLoaded` / `ModelLoadError`), and `applied_state` tracks convergence, surfaced in the UI as ready/in-progress/failed per device×model.
- Provider devices **accept pushes by default**; a local-only toggle ("Allow remote model management") opts out, and opted-out devices show as such to staff.
- Guardrails: the device refuses loads that exceed its `maxModelSizeGB` fit estimate and reports the error rather than thrashing.

## 11. Desktop UI (Mac + Windows, both 5-view apps)

New first-class **Networks** section:

- **Network list** — PINs this device/account belongs to, plus *Create network* and *Join network* (enter code → pending state shown until approved).
- **Devices tab** (per network) — Tailscale-admin-style table: name, platform, role badge, models loaded, live status (online/serving/busy/offline), last seen, tokens today. Row actions per permission matrix. Approval-queue banner with badge count for admins.
- **Models tab** — fleet loadout matrix (devices × models) for admin/modelrator: set desired state, watch reconciliation status.
- **Usage tab** — token charts by day / device / model / consumer. Counts only; no currency anywhere in PIN UI.
- **Settings tab** — network name; join code (reveal + copy + rotate, admin only); DIN contribution default; priority policy; role management; delete/leave network.
- Member-device surface: which networks I'm in, my usage, local opt-outs (remote model management, DIN contribution, serving on/off if permitted).

## 12. CLI

Available on all platforms (Mac `teale` CLI; node binary subcommands on Windows/Linux):

```
teale pin create <name>                 teale pin devices [--net <name>]
teale pin join <code>                   teale pin rename-device <dev> <name>
teale pin requests                      teale pin remove-device <dev>
teale pin approve <dev> | deny <dev>    teale pin models set <dev> <model...> [--state loaded]
teale pin rotate-code                   teale pin usage [--by device|model|day]
teale pin status                        teale pin leave <name>
```

Multi-network: `--net` flag, defaulting to the sole network when unambiguous. Output styled after Tailscale's CLI: human tables by default, `--json` for scripts.

## 13. Security model

- **Identity**: existing Ed25519 node identity; join requests signed; membership bound to pubkey in the netmap; Noise handshake proves possession on every data-plane connection.
- **Non-discoverability**: no enumeration endpoints; join responses identical for valid/invalid codes; per-device and per-IP rate limits on `/v1/pins/join`.
- **Privacy boundary**: gateway/relay see membership metadata, device capabilities, model ids, token *counts*, and scheduling requests — never prompt or completion content. This boundary is the product promise and must be stated in docs and enforced in code review.
- **Join code**: ~50 bits, rotatable; the code only grants the ability to file a join request — approval is the actual gate.
- **Blast radius**: a compromised member device can consume inference and see netmap metadata for its PINs; it cannot approve devices, alter loadouts (unless staff), or read other sessions (all sessions are pairwise-encrypted).

## 14. Error handling & edge cases

- **Gateway unreachable**: cached netmap + local scheduling (§6.2); usage reports queue locally and backfill.
- **Approval races**: approve/remove are serialized via `netmap_generation` (compare-and-bump); duplicate join requests upsert the pending row.
- **Device offline during model push**: policy persists; reconciliation resumes on reconnect; `applied_state` shows pending.
- **Last-admin protection**: cannot demote/remove the final admin; owner transfer required first.
- **Multi-PIN conflicts**: model loadout policies from different PINs may conflict on a shared device — v1 rule: union of desired `downloaded`, but `loaded` conflicts surface to the device's local user to arbitrate (no silent thrash).
- **Clock skew / staleness**: netmap TTL 24 h; devices reject netmaps older than TTL and refuse new data-plane connections (existing sessions may drain) until refreshed.

## 15. Testing

- **Gateway unit tests**: join/approve/deny/remove lifecycle, non-oracle join responses, netmap generation semantics, role matrix enforcement, usage rollups, ledger-isolation (assert zero ledger writes from PIN paths).
- **Protocol interop**: Rust↔Swift Noise handshake + fragment/reassembly golden tests (extend the existing wire-format test approach).
- **Node tests**: priority queue (PIN-before-DIN), local-scheduling fallback, usage batching/backfill, model-policy reconciliation.
- **Stress runner**: PIN scenario — N members, mixed PIN+DIN load, revocation mid-stream.
- **Live validation**: the 6-Mac Tailscale fleet as a real PIN (create, join all, push loadouts, run mixed traffic, verify usage + zero ledger deltas).

## 16. Phasing & forward compatibility

- **Phase 1 (this spec)**: everything above.
- **Phase 2 — mesh/VPN parity**: the netmap already coordinates keys + endpoints; Phase 2 swaps/augments the Noise message transport with real WireGuard tunnels (boringtun in node, NetworkExtension on macOS, Wintun on Windows, VpnService on Android) and assigns PIN IP addresses for general tunneling. Nothing in the Phase 1 schema assumes inference-only: endpoints, pubkeys, and generations are transport-agnostic.
- **Phase 3 — enterprise tier**: self-hosted gateway (the coordination server is already a single binary + SQLite), SSO for staff roles, ACL policies, PIN-scoped API keys for server workloads.

## 17. Out of scope (v1)

- Credits, pricing, or settlement inside a PIN (explicitly never).
- Mid-generation preemption of DIN work.
- Web admin console (desktop apps + CLI are the admin surface for now).
- Android as a PIN *serving* device (can join as consumer; serving depends on the node data-plane port landing on Android later).
- Pre-approved bulk provisioning keys (add when an enterprise asks).

## 18. Migration & cleanup

- `TealeNetKit` (PTN) is retired: the six Swift files and remaining references (`RemoteControlTypes.swift` PTN payloads, `ClusterManager.swift:66-69` passcode/organizationID fields, `ptnIDs` in `NodeCapabilities`) are removed or repurposed as part of implementation. No production data migration exists (PTN never shipped server-side state).
