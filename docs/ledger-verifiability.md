# Ledger Verifiability — Solana-Anchored Credit Ledger

**Status:** Implemented (gateway), pre-launch
**Date:** 2026-09-02
**Scope:** device `ledger` + `ledger_anchors`. Account and provider ledgers
are follow-ons (same scheme, their own anchor streams).

## Why

Credits are money. Today the ledger is append-only SQLite, which is
"trust the operator": anyone with write access to `ledger.db` could rewrite
history, and the only defense is re-deriving balances by hand. Suppliers
are being asked to leave expensive hardware online for credits — they
deserve proof their earnings history can't be edited after the fact.

**Deliberately not built:** a token. No mint, no monetary policy, no
tradable asset. USDC on Solana stays the settlement rail. This scheme adds
*verifiability* — the property people reach for a token to get — without an
asset to defend.

## The scheme in one paragraph

Every ledger row gets a deterministic SHA-256 hash. Rows are chained
(each row's hash mixes in the previous row's chain hash, git-style), so
editing or deleting any row changes every chain hash after it. Periodically
the operator anchors a contiguous id range: the gateway builds a Merkle
tree over the range's entry hashes and the operator publishes a single
Solana memo transaction carrying the root and chain tip. After that,
tampering with any anchored row is detectable by anyone: recompute the
row's hash, fold the Merkle proof, and compare against the root that is
permanently on Solana. The gateway never holds a Solana key — it emits the
memo, the operator signs it externally, the gateway verifies the published
transaction byte-for-byte before confirming the anchor. Same
verify-don't-custody posture as USDC deposits.

## Wire formats (source of truth for external verifiers)

### Entry hash

`entry_hash = SHA256(encode_entry(row))`, where `encode_entry` is:

```
"TEALE-LEDGER-V1"            (15 raw bytes, domain tag)
id              i64 LE
timestamp       i64 LE
amount          i64 LE
device_id       u32 LE byte-length ++ UTF-8 bytes
type            u32 LE byte-length ++ UTF-8 bytes
ref_request_id  u32 LE byte-length ++ UTF-8 bytes (length 0 when NULL)
note            u32 LE byte-length ++ UTF-8 bytes (length 0 when NULL)
```

Every variable-length field is length-prefixed, so field boundaries can
never be confused with content. Rust reference: `gateway/src/anchoring.rs`.

### Chain hash

```
chain_hash(row_1) = SHA256(0x00 * 32 ++ entry_hash(row_1))
chain_hash(row_n) = SHA256(chain_hash(row_{n-1}) ++ entry_hash(row_n))
```

The chain tip anchored at time T attests to the full content and order of
every row up to T — that is what makes *deletions* visible, not just edits.

### Merkle tree

- Leaves: entry hashes, ordered by ledger id ascending, contiguous range.
- Internal node: `SHA256(0x01 ++ left ++ right)`.
- Odd node at a level: **promoted unchanged** (never duplicated).

### Anchor memo

```
TEALE:ANCHOR:V1:{first_entry_id}:{last_entry_id}:{entry_count}:{merkle_root_hex}:{chain_tip_hex}
```

Published as a Solana Memo program
(`MemoSq4gqABAXKb96qnH8TysNcWxMyWCqXgDLGmfcHr`) instruction, UTF-8 bytes,
in a transaction whose fee payer is the configured anchor authority.
~150 bytes; one transaction costs ~0.000005 SOL — anchoring hourly costs
under $0.02/month at any SOL price seen to date.

## Operational flow

1. **Prepare** (operator, cadence TBD — hourly to daily):
   `POST /v1/admin/ledger/anchors/prepare` (static bearer). The gateway
   backfills `ledger_entry_hashes`, checks the new range is contiguous
   (gaps mean a deleted row — it refuses to anchor), builds the tree, and
   returns the pending anchor with the exact `memo` and a suggested
   `solana transfer --with-memo` command.
2. **Sign + publish** (operator, external): any wallet holding the anchor
   authority key. `solana transfer <self> 0.000001 --with-memo '<memo>'`.
   The gateway is never in the signing path.
3. **Finalize** (operator):
   `POST /v1/admin/ledger/anchors/finalize {anchorId, txSignature}`. The
   gateway fetches the transaction over RPC and requires: settled at the
   configured commitment, no on-chain error, fee payer == configured
   `solana.anchor_authority_address`, and a memo instruction whose data is
   byte-identical to the pending anchor's memo. Only then does the anchor
   flip to `confirmed`.
4. **Abandon** a pending anchor (typo'd memo, wrong wallet):
   `POST /v1/admin/ledger/anchors/abandon`. Confirmed anchors are immutable.

## Verification flow (supply node / auditor)

1. `GET /v1/ledger/proof/:entry_id` with your device bearer → the row, its
   entry/chain hashes, the Merkle path, and the anchor (root + tx
   signature). Devices can fetch only their own rows; the operator's static
   bearer can fetch any.
2. Recompute `entry_hash` from the row fields (spec above — ~30 lines in
   any language).
3. Fold the proof steps; compare with the anchor's `merkle_root`.
4. Independently fetch the anchor transaction from any Solana RPC and
   confirm the memo matches the anchor object the gateway gave you. At this
   point the gateway cannot lie about your row without Solana-level
   forgery.
5. Full-history auditors additionally walk the chain: fetch every row
   (operator export), recompute all chain hashes, and check the anchored
   tip. Chain verification is what catches *omitted* rows; Merkle proofs
   alone can't (a row you never see can't be proved missing).

Public audit surface: `GET /v1/ledger/anchors` lists every confirmed
anchor — the roots and tx signatures are public even though row contents
aren't.

## What this does and doesn't prove

- **Proves:** an anchored row's content, order, and existence as of the
  anchor time; any later edit, reorder, or deletion (via chain tip).
- **Doesn't prove:** that the gateway showed you *all* your rows (compare
  your local transaction list against proofs, or run a full chain audit);
  anything about rows not yet anchored (latency between prepare calls is
  the trust window — shrink it by anchoring more often); anything about
  the *balances* table (it's a denormalized cache — verifiers re-derive it
  from rows).
- **Threat model note:** the gateway operator can still fork *future*
  history; it cannot retroactively edit anchored history. Anchoring
  cadence is the knob between the two.

## Follow-ons (not in this patch)

- Same scheme for `account_ledger` and `provider_ledger` (independent
  anchor streams, same memo format with a different stream tag).
- `teale-node verify` subcommand implementing the client flow end-to-end.
- Anchor cadence automation once prepare/finalize has soaked manually.
- Public `GET /v1/ledger/anchors/:id/export` (full row set for a range)
  so third-party auditors can chain-walk without an operator DB dump.
