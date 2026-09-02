//! External verifiability for the credit ledger.
//!
//! The ledger is append-only SQLite, which means "trust us" is the current
//! security model: anyone with write access to the DB could rewrite history
//! and only a careful balance re-derivation would notice. This module makes
//! history externally verifiable **without** introducing a token or any new
//! custody of keys:
//!
//! 1. Every ledger row gets a deterministic `entry_hash` (SHA-256 over a
//!    canonical encoding of the row) and a `chain_hash` (SHA-256 over the
//!    previous row's chain_hash ++ this row's entry_hash), computed lazily
//!    in batches and stored in the `ledger_entry_hashes` side table. The
//!    money path (`INSERT INTO ledger …`) is deliberately untouched.
//! 2. Periodically the operator anchors a contiguous id range: the gateway
//!    builds a Merkle tree over the range's entry hashes and emits a memo
//!    string carrying the range, the Merkle root, and the chain tip.
//! 3. The operator signs a Solana Memo transaction containing that exact
//!    memo (any wallet; the configured anchor authority) and submits the
//!    signature back. The gateway verifies the on-chain transaction
//!    byte-for-byte via RPC and marks the anchor confirmed. The gateway
//!    never holds a Solana private key — same posture as USDC deposits,
//!    which it only verifies, never signs.
//! 4. Any supply node or auditor can then fetch an inclusion proof for one
//!    of their ledger rows, recompute the entry hash from the row data,
//!    fold the Merkle path, and compare the root against the memo published
//!    on Solana. A gateway that rewrites history produces proofs that no
//!    longer match the anchored root.
//!
//! Spec: `docs/ledger-verifiability.md`. Everything an external verifier
//! needs to reimplement this (encodings, tree rules, memo format) is in
//! that document; the doc is the source of truth, this file follows it.

use anyhow::bail;
use rusqlite::params;
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};

use crate::db::{unix_now, DbPool};

/// Domain tag prepended to the canonical row encoding. Bumped only if the
/// encoding changes; anchors record which version they were built with.
pub const ENTRY_ENCODING_VERSION: &str = "TEALE-LEDGER-V1";

/// Version tag inside the published memo. Independent of the row encoding
/// version so the memo format can evolve without re-hashing history.
pub const MEMO_FORMAT_VERSION: &str = "V1";

/// Solana Memo program v2. The anchor transaction is a single instruction
/// to this program whose data is the memo's UTF-8 bytes.
pub const MEMO_PROGRAM_ID: &str = "MemoSq4gqABAXKb96qnH8TysNcWxMyWCqXgDLGmfcHr";

/// One ledger row as hashed. Field order and types mirror the `ledger`
/// table; `None` options encode as empty strings (see `encode_entry`).
#[derive(Debug, Clone)]
pub struct LedgerRow {
    pub id: i64,
    pub device_id: String,
    pub type_: String,
    pub amount: i64,
    pub timestamp: i64,
    pub ref_request_id: Option<String>,
    pub note: Option<String>,
}

/// Canonical binary encoding of a row. Unambiguous by construction: every
/// variable-length field is length-prefixed, so delimiters can never be
/// confused with content (a `note` may contain any bytes, including the
/// tag itself). Integers are 8-byte little-endian signed.
///
/// layout:
///   "TEALE-LEDGER-V1" (15 raw bytes)
///   id              i64 LE
///   timestamp       i64 LE
///   amount          i64 LE
///   device_id       u32 LE len ++ utf8
///   type            u32 LE len ++ utf8
///   ref_request_id  u32 LE len ++ utf8 (len 0 when NULL)
///   note            u32 LE len ++ utf8 (len 0 when NULL)
pub fn encode_entry(row: &LedgerRow) -> Vec<u8> {
    let mut out = Vec::with_capacity(64 + row.device_id.len() + row.type_.len());
    out.extend_from_slice(ENTRY_ENCODING_VERSION.as_bytes());
    out.extend_from_slice(&row.id.to_le_bytes());
    out.extend_from_slice(&row.timestamp.to_le_bytes());
    out.extend_from_slice(&row.amount.to_le_bytes());
    push_len_prefixed(&mut out, &row.device_id);
    push_len_prefixed(&mut out, &row.type_);
    push_len_prefixed(&mut out, row.ref_request_id.as_deref().unwrap_or(""));
    push_len_prefixed(&mut out, row.note.as_deref().unwrap_or(""));
    out
}

fn push_len_prefixed(out: &mut Vec<u8>, s: &str) {
    out.extend_from_slice(&(s.len() as u32).to_le_bytes());
    out.extend_from_slice(s.as_bytes());
}

pub fn entry_hash(row: &LedgerRow) -> [u8; 32] {
    Sha256::digest(&encode_entry(row)).into()
}

/// Chain hash binds each row to every row before it: editing, deleting, or
/// reordering any historical row changes every subsequent chain hash, which
/// is what the anchored chain tip attests to. Genesis prev = 32 zero bytes.
pub fn chain_hash(prev: &[u8; 32], entry: &[u8; 32]) -> [u8; 32] {
    let mut h = Sha256::new();
    h.update(prev);
    h.update(entry);
    h.finalize().into()
}

/// One step of a Merkle inclusion proof: the sibling hash and whether the
/// running hash is on the left (`is_left = true`) or right of the sibling.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct ProofStep {
    pub sibling: String, // hex
    pub is_left: bool,
}

/// Merkle tree rules (must match the doc byte-for-byte):
/// - leaves are the 32-byte entry hashes, ordered by ledger id ascending;
/// - an internal node is SHA256(0x01 ++ left ++ right);
/// - an odd node at any level is **promoted unchanged** (not duplicated).
pub fn merkle_root(leaves: &[[u8; 32]]) -> [u8; 32] {
    if leaves.is_empty() {
        return [0u8; 32];
    }
    let mut level: Vec<[u8; 32]> = leaves.to_vec();
    while level.len() > 1 {
        let mut next = Vec::with_capacity((level.len() + 1) / 2);
        let mut i = 0;
        while i < level.len() {
            if i + 1 < level.len() {
                next.push(hash_pair(&level[i], &level[i + 1]));
            } else {
                next.push(level[i]);
            }
            i += 2;
        }
        level = next;
    }
    level[0]
}

fn hash_pair(left: &[u8; 32], right: &[u8; 32]) -> [u8; 32] {
    let mut h = Sha256::new();
    h.update([0x01]);
    h.update(left);
    h.update(right);
    h.finalize().into()
}

/// Build an inclusion proof for `index`. Panics if index is out of range;
/// callers take the index from the anchored range so this cannot happen in
/// the handler path.
pub fn merkle_proof(leaves: &[[u8; 32]], index: usize) -> Vec<ProofStep> {
    assert!(index < leaves.len(), "proof index out of range");
    let mut steps = Vec::new();
    let mut level: Vec<[u8; 32]> = leaves.to_vec();
    let mut idx = index;
    while level.len() > 1 {
        let sibling_idx = if idx % 2 == 0 { idx + 1 } else { idx - 1 };
        if sibling_idx < level.len() {
            steps.push(ProofStep {
                sibling: hex::encode(level[sibling_idx]),
                is_left: idx % 2 == 1,
            });
        }
        // Promote odd nodes unchanged, matching merkle_root.
        let mut next = Vec::with_capacity((level.len() + 1) / 2);
        let mut i = 0;
        while i < level.len() {
            if i + 1 < level.len() {
                next.push(hash_pair(&level[i], &level[i + 1]));
            } else {
                next.push(level[i]);
            }
            i += 2;
        }
        level = next;
        idx /= 2;
    }
    steps
}

/// Fold a proof: start from the leaf (the entry hash), apply each step,
/// compare against the expected root. Re-derivable by any client that has
/// the row data and the proof.
pub fn verify_proof(leaf: &[u8; 32], proof: &[ProofStep], expected_root: &[u8; 32]) -> bool {
    let mut running = *leaf;
    for step in proof {
        let sibling = match hex::decode(&step.sibling) {
            Ok(bytes) if bytes.len() == 32 => {
                let mut arr = [0u8; 32];
                arr.copy_from_slice(&bytes);
                arr
            }
            _ => return false,
        };
        running = if step.is_left {
            hash_pair(&sibling, &running)
        } else {
            hash_pair(&running, &sibling)
        };
    }
    &running == expected_root
}

/// The exact memo string published on Solana. Field order is wire law:
/// `TEALE:ANCHOR:V1:{first}:{last}:{count}:{merkle_root_hex}:{chain_tip_hex}`
pub fn anchor_memo(first: i64, last: i64, count: i64, root: &[u8; 32], tip: &[u8; 32]) -> String {
    format!(
        "TEALE:ANCHOR:{MEMO_FORMAT_VERSION}:{first}:{last}:{count}:{}:{}",
        hex::encode(root),
        hex::encode(tip)
    )
}

/// A confirmed-or-pending anchor row as returned to clients.
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct AnchorRecord {
    pub id: i64,
    pub created_at: i64,
    pub first_entry_id: i64,
    pub last_entry_id: i64,
    pub entry_count: i64,
    pub merkle_root: String,
    pub chain_tip: String,
    pub memo: String,
    pub status: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub tx_signature: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub confirmed_at: Option<i64>,
}

/// Result of `prepare_anchor`: the pending anchor plus everything the
/// operator needs to sign it.
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PreparedAnchor {
    #[serde(flatten)]
    pub record: AnchorRecord,
    /// Suggested CLI one-liner (solana CLI) to sign the memo from the
    /// configured anchor authority wallet.
    pub sign_command: String,
}

/// Rows that exist in `ledger` but have no entry hash yet. Ordered by id —
/// that order is part of the consensus between gateway and verifiers.
fn fetch_unhashed_rows(conn: &rusqlite::Connection) -> rusqlite::Result<Vec<LedgerRow>> {
    let mut stmt = conn.prepare(
        "SELECT l.id, l.device_id, l.type, l.amount, l.timestamp, l.ref_request_id, l.note
         FROM ledger l
         LEFT JOIN ledger_entry_hashes h ON h.entry_id = l.id
         WHERE h.entry_id IS NULL
         ORDER BY l.id ASC",
    )?;
    let rows = stmt
        .query_map([], |r| {
            Ok(LedgerRow {
                id: r.get(0)?,
                device_id: r.get(1)?,
                type_: r.get(2)?,
                amount: r.get(3)?,
                timestamp: r.get(4)?,
                ref_request_id: r.get(5)?,
                note: r.get(6)?,
            })
        })?
        .collect::<rusqlite::Result<Vec<_>>>()?;
    Ok(rows)
}

/// Bring `ledger_entry_hashes` up to date with `ledger`, extending the
/// chain. Idempotent; safe to call before every prepare. Returns the number
/// of rows hashed in this call.
pub fn backfill_entry_hashes(pool: &DbPool) -> anyhow::Result<usize> {
    let conn = pool.lock();
    let rows = fetch_unhashed_rows(&conn)?;
    let mut prev: [u8; 32] = conn
        .query_row(
            "SELECT chain_hash FROM ledger_entry_hashes ORDER BY entry_id DESC LIMIT 1",
            [],
            |r| r.get::<_, String>(0),
        )
        .ok()
        .and_then(|hexstr| hex::decode(hexstr).ok())
        .and_then(|bytes| <[u8; 32]>::try_from(bytes.as_slice()).ok())
        .unwrap_or([0u8; 32]);
    let count = rows.len();
    for row in &rows {
        let eh = entry_hash(row);
        let ch = chain_hash(&prev, &eh);
        conn.execute(
            "INSERT INTO ledger_entry_hashes (entry_id, entry_hash, chain_hash) VALUES (?, ?, ?)",
            params![row.id, hex::encode(eh), hex::encode(ch)],
        )?;
        prev = ch;
    }
    Ok(count)
}

/// Build a new pending anchor over every hashed-but-unanchored row.
///
/// Fails with a conflict-style error if a pending anchor already exists —
/// finalize or abandon it first, so the published ranges stay contiguous
/// and non-overlapping.
pub fn prepare_anchor(pool: &DbPool) -> anyhow::Result<Option<PreparedAnchor>> {
    backfill_entry_hashes(pool)?;
    let conn = pool.lock();

    let pending: Option<i64> = conn
        .query_row(
            "SELECT id FROM ledger_anchors WHERE status = 'pending' LIMIT 1",
            [],
            |r| r.get(0),
        )
        .ok();
    if pending.is_some() {
        bail!("a pending anchor already exists — finalize or abandon it first");
    }

    let last_anchored: i64 = conn
        .query_row(
            "SELECT COALESCE(MAX(last_entry_id), 0) FROM ledger_anchors WHERE status = 'confirmed'",
            [],
            |r| r.get(0),
        )
        .unwrap_or(0);

    let mut stmt = conn.prepare(
        "SELECT entry_id, entry_hash, chain_hash FROM ledger_entry_hashes
         WHERE entry_id > ? ORDER BY entry_id ASC",
    )?;
    let hashed: Vec<(i64, [u8; 32], [u8; 32])> = stmt
        .query_map(params![last_anchored], |r| {
            Ok((
                r.get::<_, i64>(0)?,
                r.get::<_, String>(1)?,
                r.get::<_, String>(2)?,
            ))
        })?
        .collect::<rusqlite::Result<Vec<_>>>()?
        .into_iter()
        .map(|(id, eh, ch)| {
            let ehb: [u8; 32] = hex::decode(&eh)
                .ok()
                .and_then(|b| <[u8; 32]>::try_from(b.as_slice()).ok())
                .unwrap_or([0u8; 32]);
            let chb: [u8; 32] = hex::decode(&ch)
                .ok()
                .and_then(|b| <[u8; 32]>::try_from(b.as_slice()).ok())
                .unwrap_or([0u8; 32]);
            (id, ehb, chb)
        })
        .collect();

    if hashed.is_empty() {
        return Ok(None); // nothing new to anchor
    }

    // Gap check: anchored ranges must cover a contiguous id run, or a
    // deleted row would be invisible in the gaps between anchors.
    let first = hashed.first().map(|r| r.0).unwrap_or(0);
    let last = hashed.last().map(|r| r.0).unwrap_or(0);
    if last - first + 1 != hashed.len() as i64 {
        bail!(
            "ledger id range {first}..={last} has gaps ({} rows) — investigate before anchoring",
            hashed.len()
        );
    }

    let leaves: Vec<[u8; 32]> = hashed.iter().map(|r| r.1).collect();
    let root = merkle_root(&leaves);
    let tip = hashed.last().map(|r| r.2).unwrap_or([0u8; 32]);
    let memo = anchor_memo(first, last, hashed.len() as i64, &root, &tip);
    let now = unix_now();

    conn.execute(
        "INSERT INTO ledger_anchors
         (created_at, first_entry_id, last_entry_id, entry_count, merkle_root, chain_tip, memo, status)
         VALUES (?, ?, ?, ?, ?, ?, ?, 'pending')",
        params![
            now,
            first,
            last,
            hashed.len() as i64,
            hex::encode(root),
            hex::encode(tip),
            memo
        ],
    )?;
    let anchor_id = conn.last_insert_rowid();

    let record = AnchorRecord {
        id: anchor_id,
        created_at: now,
        first_entry_id: first,
        last_entry_id: last,
        entry_count: hashed.len() as i64,
        merkle_root: hex::encode(root),
        chain_tip: hex::encode(tip),
        memo: memo.clone(),
        status: "pending".to_string(),
        tx_signature: None,
        confirmed_at: None,
    };
    Ok(Some(PreparedAnchor {
        sign_command: format!(
            "solana transfer <ANCHOR_AUTHORITY> 0.000001 --with-memo '{memo}' --fee-payer <ANCHOR_AUTHORITY_KEYPAIR> --allow-unfunded-recipient"
        ),
        record,
    }))
}

/// Mark a pending anchor confirmed after `solana::verify_memo_anchor` has
/// accepted the on-chain transaction. The handler owns the RPC call; this
/// function owns the state transition.
pub fn confirm_anchor(pool: &DbPool, anchor_id: i64, tx_signature: &str) -> anyhow::Result<()> {
    let conn = pool.lock();
    let updated = conn.execute(
        "UPDATE ledger_anchors SET status = 'confirmed', tx_signature = ?, confirmed_at = ?
         WHERE id = ? AND status = 'pending'",
        params![tx_signature, unix_now(), anchor_id],
    )?;
    if updated == 0 {
        bail!("anchor {anchor_id} is not pending (already confirmed or unknown id)");
    }
    Ok(())
}

/// Abandon a pending anchor whose memo was never published (or was
/// published wrong). Confirmed anchors are immutable.
pub fn abandon_anchor(pool: &DbPool, anchor_id: i64) -> anyhow::Result<()> {
    let conn = pool.lock();
    let updated = conn.execute(
        "UPDATE ledger_anchors SET status = 'abandoned' WHERE id = ? AND status = 'pending'",
        params![anchor_id],
    )?;
    if updated == 0 {
        bail!("anchor {anchor_id} is not pending");
    }
    Ok(())
}

/// The memo a given pending anchor expects on-chain. The finalize handler
/// compares the published transaction against this exact string.
pub fn pending_anchor_memo(pool: &DbPool, anchor_id: i64) -> anyhow::Result<Option<String>> {
    let conn = pool.lock();
    let memo = conn
        .query_row(
            "SELECT memo FROM ledger_anchors WHERE id = ? AND status = 'pending'",
            params![anchor_id],
            |r| r.get(0),
        )
        .ok();
    Ok(memo)
}

/// All anchors, newest first. `confirmed_only` drives the public endpoint;
/// the admin path passes false when it wants to inspect pending state.
pub fn list_anchors(pool: &DbPool, confirmed_only: bool) -> anyhow::Result<Vec<AnchorRecord>> {
    let conn = pool.lock();
    let sql = if confirmed_only {
        "SELECT id, created_at, first_entry_id, last_entry_id, entry_count, merkle_root, chain_tip, memo, status, tx_signature, confirmed_at
         FROM ledger_anchors WHERE status = 'confirmed' ORDER BY id DESC"
    } else {
        "SELECT id, created_at, first_entry_id, last_entry_id, entry_count, merkle_root, chain_tip, memo, status, tx_signature, confirmed_at
         FROM ledger_anchors ORDER BY id DESC"
    };
    let mut stmt = conn.prepare(sql)?;
    let rows = stmt
        .query_map([], |r| {
            Ok(AnchorRecord {
                id: r.get(0)?,
                created_at: r.get(1)?,
                first_entry_id: r.get(2)?,
                last_entry_id: r.get(3)?,
                entry_count: r.get(4)?,
                merkle_root: r.get(5)?,
                chain_tip: r.get(6)?,
                memo: r.get(7)?,
                status: r.get(8)?,
                tx_signature: r.get(9)?,
                confirmed_at: r.get(10)?,
            })
        })?
        .collect::<rusqlite::Result<Vec<_>>>()?;
    Ok(rows)
}

/// Everything a client needs to verify one ledger row against a confirmed
/// anchor: the row itself (to re-hash), its entry/chain hashes, the Merkle
/// path, and the anchor carrying the on-chain memo + signature.
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct InclusionProof {
    pub entry: serde_json::Value,
    pub entry_hash: String,
    pub chain_hash: String,
    pub proof: Vec<ProofStep>,
    pub anchor: AnchorRecord,
}

/// Build an inclusion proof for `entry_id`. Returns Ok(None) when the entry
/// is not yet covered by a *confirmed* anchor (pending anchors prove
/// nothing — the memo isn't on-chain yet).
pub fn inclusion_proof(pool: &DbPool, entry_id: i64) -> anyhow::Result<Option<InclusionProof>> {
    // Make sure hashes are current so a row landed after the last anchor
    // still reports cleanly as "unanchored" rather than "missing".
    backfill_entry_hashes(pool)?;
    let conn = pool.lock();

    let row = conn
        .query_row(
            "SELECT id, device_id, type, amount, timestamp, ref_request_id, note
             FROM ledger WHERE id = ?",
            params![entry_id],
            |r| {
                Ok(LedgerRow {
                    id: r.get(0)?,
                    device_id: r.get(1)?,
                    type_: r.get(2)?,
                    amount: r.get(3)?,
                    timestamp: r.get(4)?,
                    ref_request_id: r.get(5)?,
                    note: r.get(6)?,
                })
            },
        )
        .ok();

    let Some(row) = row else {
        return Ok(None);
    };

    let anchor: Option<AnchorRecord> = conn
        .query_row(
            "SELECT id, created_at, first_entry_id, last_entry_id, entry_count, merkle_root, chain_tip, memo, status, tx_signature, confirmed_at
             FROM ledger_anchors
             WHERE status = 'confirmed' AND first_entry_id <= ? AND last_entry_id >= ?
             ORDER BY id DESC LIMIT 1",
            params![entry_id, entry_id],
            |r| {
                Ok(AnchorRecord {
                    id: r.get(0)?,
                    created_at: r.get(1)?,
                    first_entry_id: r.get(2)?,
                    last_entry_id: r.get(3)?,
                    entry_count: r.get(4)?,
                    merkle_root: r.get(5)?,
                    chain_tip: r.get(6)?,
                    memo: r.get(7)?,
                    status: r.get(8)?,
                    tx_signature: r.get(9)?,
                    confirmed_at: r.get(10)?,
                })
            },
        )
        .ok();

    let Some(anchor) = anchor else {
        return Ok(None); // anchored-later; caller distinguishes via entry exists
    };

    let mut stmt = conn.prepare(
        "SELECT entry_id, entry_hash, chain_hash FROM ledger_entry_hashes
         WHERE entry_id BETWEEN ? AND ? ORDER BY entry_id ASC",
    )?;
    let hashed: Vec<(i64, String, String)> = stmt
        .query_map(params![anchor.first_entry_id, anchor.last_entry_id], |r| {
            Ok((r.get(0)?, r.get(1)?, r.get(2)?))
        })?
        .collect::<rusqlite::Result<Vec<_>>>()?;

    let leaves: Vec<[u8; 32]> = hashed
        .iter()
        .map(|(_, eh, _)| {
            hex::decode(eh)
                .ok()
                .and_then(|b| <[u8; 32]>::try_from(b.as_slice()).ok())
                .unwrap_or([0u8; 32])
        })
        .collect();
    let position = (entry_id - anchor.first_entry_id) as usize;
    if position >= leaves.len() {
        bail!("entry {entry_id} outside reconstructed anchor range");
    }
    let proof = merkle_proof(&leaves, position);

    let (entry_hash_hex, chain_hash_hex) = hashed
        .get(position)
        .map(|(_, eh, ch)| (eh.clone(), ch.clone()))
        .unwrap_or_default();

    // Sanity: the stored hash must match a fresh recomputation from the row.
    // If it doesn't, the ledger was edited after hashing — say so loudly.
    let recomputed = hex::encode(entry_hash(&row));
    if recomputed != entry_hash_hex {
        bail!(
            "entry {entry_id} hash mismatch: row content changed after hashing (stored {entry_hash_hex}, recomputed {recomputed})"
        );
    }

    Ok(Some(InclusionProof {
        entry: serde_json::json!({
            "id": row.id,
            "deviceId": row.device_id,
            "type": row.type_,
            "amount": row.amount,
            "timestamp": row.timestamp,
            "refRequestId": row.ref_request_id,
            "note": row.note,
        }),
        entry_hash: entry_hash_hex,
        chain_hash: chain_hash_hex,
        proof,
        anchor,
    }))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn row(id: i64, amount: i64) -> LedgerRow {
        LedgerRow {
            id,
            device_id: format!("device-{id:04}"),
            type_: "DIRECT_EARN".to_string(),
            amount,
            timestamp: 1_700_000_000 + id,
            ref_request_id: Some(format!("req-{id}")),
            note: None,
        }
    }

    #[test]
    fn encoding_is_deterministic_and_content_safe() {
        let a = encode_entry(&row(7, 100));
        let b = encode_entry(&row(7, 100));
        assert_eq!(a, b);
        // A note containing the domain tag must not collide with a row
        // whose other fields differ — length-prefixing, not delimiters.
        let mut with_note = row(7, 100);
        with_note.note = Some(ENTRY_ENCODING_VERSION.to_string());
        assert_ne!(encode_entry(&with_note), a);
    }

    #[test]
    fn chain_depends_on_every_previous_row() {
        let h1 = entry_hash(&row(1, 10));
        let h2 = entry_hash(&row(2, 20));
        let c1 = chain_hash(&[0u8; 32], &h1);
        let c2 = chain_hash(&c1, &h2);
        // Rewriting row 1's amount changes c2 even though row 2 is untouched.
        let c1_tampered = chain_hash(&[0u8; 32], &entry_hash(&row(1, 11)));
        let c2_tampered = chain_hash(&c1_tampered, &h2);
        assert_ne!(c2, c2_tampered);
    }

    #[test]
    fn proofs_round_trip_for_small_trees() {
        for n in 1..=9usize {
            let leaves: Vec<[u8; 32]> = (0..n).map(|i| entry_hash(&row(i as i64 + 1, 5))).collect();
            let root = merkle_root(&leaves);
            for (i, leaf) in leaves.iter().enumerate() {
                let proof = merkle_proof(&leaves, i);
                assert!(verify_proof(leaf, &proof, &root), "n={n} i={i}");
                // A flipped bit anywhere must fail.
                let mut wrong = *leaf;
                wrong[0] ^= 1;
                assert!(!verify_proof(&wrong, &proof, &root), "n={n} i={i}");
            }
        }
    }

    #[test]
    fn odd_levels_promote_not_duplicate() {
        // Three leaves: root = H(0x01, H(0x01, l0, l1), l2) under promotion.
        let leaves: Vec<[u8; 32]> = (0..3).map(|i| entry_hash(&row(i + 1, 5))).collect();
        let expected = hash_pair(&hash_pair(&leaves[0], &leaves[1]), &leaves[2]);
        assert_eq!(merkle_root(&leaves), expected);
    }

    #[test]
    fn memo_format_is_stable() {
        let memo = anchor_memo(1, 100, 100, &[0xAB; 32], &[0xCD; 32]);
        assert!(memo.starts_with("TEALE:ANCHOR:V1:1:100:100:"));
        assert_eq!(memo.matches(':').count(), 6);
        assert_eq!(memo.len(), "TEALE:ANCHOR:V1:1:100:100:".len() + 64 + 1 + 64);
    }
}
