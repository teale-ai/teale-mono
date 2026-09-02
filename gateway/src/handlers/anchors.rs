//! Ledger verifiability endpoints.
//!
//! - `POST /v1/admin/ledger/anchors/prepare`  (static bearer) — build a
//!   pending anchor over every unanchored ledger row and return the memo
//!   the operator must publish on Solana.
//! - `POST /v1/admin/ledger/anchors/finalize` (static bearer) — after the
//!   memo transaction is on-chain, verify it via RPC and confirm the anchor.
//! - `POST /v1/admin/ledger/anchors/abandon`  (static bearer) — drop a
//!   pending anchor whose memo was never (or wrongly) published.
//! - `GET  /v1/ledger/anchors`                (public) — confirmed anchors:
//!   the Merkle roots + Solana signatures anyone can audit against.
//! - `GET  /v1/ledger/proof/:entry_id`        (device or static bearer) —
//!   Merkle inclusion proof for one ledger row. Devices may only fetch
//!   proofs for their own rows; static (operator) bearers may fetch any.
//!
//! The gateway never holds a Solana key. Anchoring is operator-signed:
//! prepare emits the exact memo, the operator signs it externally (one
//! `solana transfer --with-memo` command), finalize verifies the published
//! transaction byte-for-byte before marking the anchor confirmed.

use axum::{
    extract::{Path, State},
    Extension, Json,
};
use serde::{Deserialize, Serialize};

use crate::anchoring::{self, AnchorRecord, PreparedAnchor};
use crate::auth::{AuthPrincipal, PrincipalKind};
use crate::db::DbPool;
use crate::error::GatewayError;
use crate::solana;
use crate::state::AppState;

fn require_static(principal: &AuthPrincipal) -> Result<(), GatewayError> {
    match &principal.kind {
        PrincipalKind::Static { .. } => Ok(()),
        _ => Err(GatewayError::Forbidden(
            "anchor admin endpoints require a static bearer".into(),
        )),
    }
}

fn require_pool(state: &AppState) -> Result<&DbPool, GatewayError> {
    state
        .db
        .as_ref()
        .ok_or_else(|| GatewayError::Other(anyhow::anyhow!("db not initialized")))
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PrepareRes {
    #[serde(flatten)]
    pub prepared: PreparedAnchor,
    pub instructions: String,
}

/// POST /v1/admin/ledger/anchors/prepare
pub async fn prepare(
    State(state): State<AppState>,
    Extension(principal): Extension<AuthPrincipal>,
) -> Result<Json<PrepareRes>, GatewayError> {
    require_static(&principal)?;
    let pool = require_pool(&state)?;
    let prepared = anchoring::prepare_anchor(pool)
        .map_err(|e| GatewayError::Conflict(format!("prepare anchor: {e}")))?
        .ok_or_else(|| GatewayError::Conflict("no unanchored ledger rows".into()))?;
    let instructions = format!(
        "Publish the memo on Solana from the configured anchor authority ({}), then call /v1/admin/ledger/anchors/finalize with the tx signature.",
        if state.config.solana.anchor_authority_address.is_empty() {
            "NOT CONFIGURED — set solana.anchor_authority_address first"
        } else {
            state.config.solana.anchor_authority_address.as_str()
        }
    );
    Ok(Json(PrepareRes {
        prepared,
        instructions,
    }))
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct FinalizeReq {
    pub anchor_id: i64,
    pub tx_signature: String,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct FinalizeRes {
    pub anchor_id: i64,
    pub status: String,
    pub tx_signature: String,
}

/// POST /v1/admin/ledger/anchors/finalize
pub async fn finalize(
    State(state): State<AppState>,
    Extension(principal): Extension<AuthPrincipal>,
    Json(req): Json<FinalizeReq>,
) -> Result<Json<FinalizeRes>, GatewayError> {
    require_static(&principal)?;
    let pool = require_pool(&state)?;
    if state.config.solana.anchor_authority_address.is_empty() {
        return Err(GatewayError::BadRequest(
            "solana.anchor_authority_address is not configured".into(),
        ));
    }
    let memo = anchoring::pending_anchor_memo(pool, req.anchor_id)
        .map_err(|e| GatewayError::Other(anyhow::anyhow!("lookup anchor: {e}")))?
        .ok_or_else(|| GatewayError::NotFound(format!("no pending anchor {}", req.anchor_id)))?;

    solana::verify_memo_anchor(
        &state.config.solana,
        &req.tx_signature,
        &memo,
        &state.config.solana.anchor_authority_address,
    )
    .await
    .map_err(|e| GatewayError::BadRequest(format!("on-chain verification failed: {e}")))?;

    anchoring::confirm_anchor(pool, req.anchor_id, req.tx_signature.trim())
        .map_err(|e| GatewayError::Conflict(format!("confirm anchor: {e}")))?;

    Ok(Json(FinalizeRes {
        anchor_id: req.anchor_id,
        status: "confirmed".to_string(),
        tx_signature: req.tx_signature,
    }))
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AbandonReq {
    pub anchor_id: i64,
}

/// POST /v1/admin/ledger/anchors/abandon
pub async fn abandon(
    State(state): State<AppState>,
    Extension(principal): Extension<AuthPrincipal>,
    Json(req): Json<AbandonReq>,
) -> Result<Json<serde_json::Value>, GatewayError> {
    require_static(&principal)?;
    let pool = require_pool(&state)?;
    anchoring::abandon_anchor(pool, req.anchor_id)
        .map_err(|e| GatewayError::Conflict(format!("abandon anchor: {e}")))?;
    Ok(Json(serde_json::json!({
        "anchorId": req.anchor_id,
        "status": "abandoned"
    })))
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct AnchorsRes {
    pub anchors: Vec<AnchorRecord>,
}

/// GET /v1/ledger/anchors — public. Confirmed anchors only: a pending
/// anchor's memo isn't on-chain, so publishing it would invite failed
/// verifications.
pub async fn list(State(state): State<AppState>) -> Result<Json<AnchorsRes>, GatewayError> {
    let pool = require_pool(&state)?;
    let anchors = anchoring::list_anchors(pool, true)
        .map_err(|e| GatewayError::Other(anyhow::anyhow!("list anchors: {e}")))?;
    Ok(Json(AnchorsRes { anchors }))
}

/// GET /v1/ledger/proof/:entry_id — device bearer (own rows) or static.
pub async fn proof(
    State(state): State<AppState>,
    Extension(principal): Extension<AuthPrincipal>,
    Path(entry_id): Path<i64>,
) -> Result<Json<serde_json::Value>, GatewayError> {
    let pool = require_pool(&state)?;

    // Device-scoped: a device may only audit its own ledger rows.
    if let PrincipalKind::Device { device_id } = &principal.kind {
        let owns: bool = {
            let conn = pool.lock();
            conn.query_row(
                "SELECT EXISTS(SELECT 1 FROM ledger WHERE id = ? AND device_id = ?)",
                rusqlite::params![entry_id, device_id],
                |r| r.get::<_, i64>(0),
            )
            .map(|v| v == 1)
            .unwrap_or(false)
        };
        if !owns {
            return Err(GatewayError::Forbidden(
                "devices may only fetch proofs for their own ledger rows".into(),
            ));
        }
    } else if !matches!(principal.kind, PrincipalKind::Static { .. }) {
        return Err(GatewayError::Forbidden(
            "proof endpoint requires a device or static bearer".into(),
        ));
    }

    match anchoring::inclusion_proof(pool, entry_id)
        .map_err(|e| GatewayError::Other(anyhow::anyhow!("build proof: {e}")))?
    {
        Some(proof) => Ok(Json(serde_json::to_value(proof).map_err(|e| {
            GatewayError::Other(anyhow::anyhow!("serialize proof: {e}"))
        })?)),
        None => Err(GatewayError::NotFound(format!(
            "entry {entry_id} does not exist or is not covered by a confirmed anchor yet"
        ))),
    }
}
