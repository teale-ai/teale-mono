//! Group chat endpoints.
//!
//! Gateway-brokered (MVP). Every participant posts messages via REST and
//! either polls /messages or subscribes to /stream via SSE.

use std::convert::Infallible;
use std::time::Duration;

use axum::{
    extract::{Path, Query, State},
    http::HeaderMap,
    response::{sse::Event, Response, Sse},
    Extension, Json,
};
use futures::stream::Stream;
use rusqlite::params;
use serde::{Deserialize, Serialize};
use uuid::Uuid;

use crate::auth::AuthPrincipal;
use crate::db::{unix_now, DbPool};
use crate::error::GatewayError;
use crate::state::AppState;

fn require_device(principal: &AuthPrincipal) -> Result<String, GatewayError> {
    principal
        .device_id()
        .map(|s| s.to_string())
        .ok_or_else(|| GatewayError::Unauthorized("groups require a device token".into()))
}

fn require_pool(state: &AppState) -> Result<&DbPool, GatewayError> {
    state
        .db
        .as_ref()
        .ok_or_else(|| GatewayError::Other(anyhow::anyhow!("db not initialized")))
}

#[derive(Deserialize)]
pub struct CreateGroupReq {
    title: String,
    #[serde(default, rename = "memberDeviceIDs")]
    member_device_ids: Vec<String>,
}

#[derive(Serialize)]
pub struct GroupSummary {
    #[serde(rename = "groupID")]
    group_id: String,
    title: String,
    #[serde(rename = "createdBy")]
    created_by: String,
    #[serde(rename = "createdAt")]
    created_at: i64,
    #[serde(rename = "memberCount")]
    member_count: i64,
}

pub async fn create_group(
    State(state): State<AppState>,
    Extension(principal): Extension<AuthPrincipal>,
    Json(req): Json<CreateGroupReq>,
) -> Result<Json<GroupSummary>, GatewayError> {
    let device_id = require_device(&principal)?;
    let pool = require_pool(&state)?;
    let group_id = Uuid::new_v4().to_string();
    let now = unix_now();

    let mut conn = pool.lock();
    let tx = conn.transaction().map_err(wrap)?;
    tx.execute(
        "INSERT INTO groups (id, title, created_by, created_at) VALUES (?, ?, ?, ?)",
        params![&group_id, &req.title, &device_id, now],
    )
    .map_err(wrap)?;
    tx.execute(
        "INSERT INTO group_members (group_id, device_id, joined_at) VALUES (?, ?, ?)",
        params![&group_id, &device_id, now],
    )
    .map_err(wrap)?;
    for m in &req.member_device_ids {
        if m == &device_id {
            continue;
        }
        tx.execute(
            "INSERT OR IGNORE INTO group_members (group_id, device_id, joined_at) VALUES (?, ?, ?)",
            params![&group_id, m, now],
        )
        .map_err(wrap)?;
    }
    tx.commit().map_err(wrap)?;
    let member_count = 1 + req.member_device_ids.len() as i64;

    Ok(Json(GroupSummary {
        group_id,
        title: req.title,
        created_by: device_id,
        created_at: now,
        member_count,
    }))
}

#[derive(Deserialize)]
pub struct AddMemberReq {
    #[serde(rename = "deviceID")]
    device_id: String,
}

pub async fn add_member(
    State(state): State<AppState>,
    Path(group_id): Path<String>,
    Extension(principal): Extension<AuthPrincipal>,
    Json(req): Json<AddMemberReq>,
) -> Result<Json<serde_json::Value>, GatewayError> {
    let adder = require_device(&principal)?;
    let pool = require_pool(&state)?;
    let conn = pool.lock();
    let is_member: bool = conn
        .query_row(
            "SELECT 1 FROM group_members WHERE group_id = ? AND device_id = ?",
            params![&group_id, &adder],
            |r| r.get::<_, i64>(0),
        )
        .map(|_| true)
        .unwrap_or(false);
    if !is_member {
        return Err(GatewayError::Unauthorized("not a group member".into()));
    }
    conn.execute(
        "INSERT OR IGNORE INTO group_members (group_id, device_id, joined_at) VALUES (?, ?, ?)",
        params![&group_id, &req.device_id, unix_now()],
    )
    .map_err(wrap)?;
    Ok(Json(serde_json::json!({ "ok": true })))
}

#[derive(Deserialize)]
pub struct PostMessageReq {
    #[serde(default = "default_msg_type")]
    #[serde(rename = "type")]
    type_: String,
    content: String,
    #[serde(default, rename = "refMessageID")]
    ref_message_id: Option<String>,
}

fn default_msg_type() -> String {
    "text".into()
}

#[derive(Serialize, Clone)]
pub struct GroupMessage {
    pub id: String,
    #[serde(rename = "groupID")]
    pub group_id: String,
    #[serde(rename = "senderDeviceID")]
    pub sender_device_id: String,
    #[serde(rename = "type")]
    pub type_: String,
    pub content: String,
    #[serde(rename = "refMessageID", skip_serializing_if = "Option::is_none")]
    pub ref_message_id: Option<String>,
    pub timestamp: i64,
}

pub async fn post_message(
    State(state): State<AppState>,
    Path(group_id): Path<String>,
    Extension(principal): Extension<AuthPrincipal>,
    Json(req): Json<PostMessageReq>,
) -> Result<Json<GroupMessage>, GatewayError> {
    let sender = require_device(&principal)?;
    let pool = require_pool(&state)?;
    let id = Uuid::new_v4().to_string();
    let ts = unix_now();

    {
        let conn = pool.lock();
        let is_member: bool = conn
            .query_row(
                "SELECT 1 FROM group_members WHERE group_id = ? AND device_id = ?",
                params![&group_id, &sender],
                |r| r.get::<_, i64>(0),
            )
            .map(|_| true)
            .unwrap_or(false);
        if !is_member {
            return Err(GatewayError::Unauthorized("not a group member".into()));
        }
        conn.execute(
            "INSERT INTO group_messages (id, group_id, sender_device_id, type, content, ref_message_id, timestamp)
             VALUES (?, ?, ?, ?, ?, ?, ?)",
            params![&id, &group_id, &sender, &req.type_, &req.content, req.ref_message_id.as_ref(), ts],
        )
        .map_err(wrap)?;
    }

    let msg = GroupMessage {
        id,
        group_id,
        sender_device_id: sender,
        type_: req.type_,
        content: req.content,
        ref_message_id: req.ref_message_id,
        timestamp: ts,
    };

    // Broadcast to any live SSE subscribers.
    state.group_tx.send(msg.clone()).ok();

    Ok(Json(msg))
}

#[derive(Deserialize)]
pub struct SinceQuery {
    #[serde(default)]
    since: Option<i64>,
    #[serde(default = "default_msg_limit")]
    limit: i64,
}
fn default_msg_limit() -> i64 {
    100
}

#[derive(Serialize)]
pub struct MessagesRes {
    messages: Vec<GroupMessage>,
}

pub async fn list_messages(
    State(state): State<AppState>,
    Path(group_id): Path<String>,
    Extension(principal): Extension<AuthPrincipal>,
    Query(q): Query<SinceQuery>,
) -> Result<Json<MessagesRes>, GatewayError> {
    let device_id = require_device(&principal)?;
    let pool = require_pool(&state)?;
    let conn = pool.lock();
    let is_member: bool = conn
        .query_row(
            "SELECT 1 FROM group_members WHERE group_id = ? AND device_id = ?",
            params![&group_id, &device_id],
            |r| r.get::<_, i64>(0),
        )
        .map(|_| true)
        .unwrap_or(false);
    if !is_member {
        return Err(GatewayError::Unauthorized("not a group member".into()));
    }

    let since = q.since.unwrap_or(0);
    let limit = q.limit.clamp(1, 500);
    let mut stmt = conn
        .prepare(
            "SELECT id, group_id, sender_device_id, type, content, ref_message_id, timestamp
             FROM group_messages WHERE group_id = ? AND timestamp > ?
             ORDER BY timestamp ASC LIMIT ?",
        )
        .map_err(wrap)?;
    let messages: Vec<GroupMessage> = stmt
        .query_map(params![&group_id, since, limit], |r| {
            Ok(GroupMessage {
                id: r.get(0)?,
                group_id: r.get(1)?,
                sender_device_id: r.get(2)?,
                type_: r.get(3)?,
                content: r.get(4)?,
                ref_message_id: r.get(5)?,
                timestamp: r.get(6)?,
            })
        })
        .map_err(wrap)?
        .filter_map(|r| r.ok())
        .collect();

    Ok(Json(MessagesRes { messages }))
}

#[derive(Serialize)]
pub struct GroupsListRes {
    groups: Vec<GroupSummary>,
}

pub async fn list_mine(
    State(state): State<AppState>,
    Extension(principal): Extension<AuthPrincipal>,
) -> Result<Json<GroupsListRes>, GatewayError> {
    let device_id = require_device(&principal)?;
    let pool = require_pool(&state)?;
    let conn = pool.lock();
    let mut stmt = conn
        .prepare(
            "SELECT g.id, g.title, g.created_by, g.created_at,
                    (SELECT COUNT(*) FROM group_members m WHERE m.group_id = g.id) AS member_count
             FROM groups g
             JOIN group_members gm ON gm.group_id = g.id
             WHERE gm.device_id = ?
             ORDER BY g.created_at DESC",
        )
        .map_err(wrap)?;
    let groups: Vec<GroupSummary> = stmt
        .query_map([&device_id], |r| {
            Ok(GroupSummary {
                group_id: r.get(0)?,
                title: r.get(1)?,
                created_by: r.get(2)?,
                created_at: r.get(3)?,
                member_count: r.get(4)?,
            })
        })
        .map_err(wrap)?
        .filter_map(|r| r.ok())
        .collect();
    Ok(Json(GroupsListRes { groups }))
}

pub async fn stream_messages(
    State(state): State<AppState>,
    Path(group_id): Path<String>,
    headers: HeaderMap,
) -> Result<Sse<impl Stream<Item = Result<Event, Infallible>>>, GatewayError> {
    // SSE can't use Extension<AuthPrincipal> in all cases cleanly (depending
    // on middleware order), so we re-resolve the bearer here.
    let header_val = headers
        .get(axum::http::header::AUTHORIZATION)
        .and_then(|h| h.to_str().ok())
        .unwrap_or("");
    let token = header_val.strip_prefix("Bearer ").unwrap_or("").trim();
    if token.is_empty() {
        return Err(GatewayError::Unauthorized("missing bearer".into()));
    }
    let pool = require_pool(&state)?;
    let device_id = crate::ledger::resolve_token(pool, token)
        .ok_or_else(|| GatewayError::Unauthorized("unknown token".into()))?;

    // Membership check
    {
        let conn = pool.lock();
        let is_member: bool = conn
            .query_row(
                "SELECT 1 FROM group_members WHERE group_id = ? AND device_id = ?",
                params![&group_id, &device_id],
                |r| r.get::<_, i64>(0),
            )
            .map(|_| true)
            .unwrap_or(false);
        if !is_member {
            return Err(GatewayError::Unauthorized("not a group member".into()));
        }
    }

    let mut rx = state.group_tx.subscribe();
    let target_group = group_id.clone();
    let stream = async_stream::stream! {
        loop {
            match rx.recv().await {
                Ok(msg) => {
                    if msg.group_id == target_group {
                        if let Ok(s) = serde_json::to_string(&msg) {
                            yield Ok(Event::default().data(s));
                        }
                    }
                }
                Err(tokio::sync::broadcast::error::RecvError::Lagged(_)) => continue,
                Err(_) => break,
            }
        }
    };
    Ok(Sse::new(stream)
        .keep_alive(axum::response::sse::KeepAlive::new().interval(Duration::from_secs(15))))
}

#[derive(Deserialize)]
pub struct RememberReq {
    #[serde(default)]
    category: Option<String>,
    text: String,
    #[serde(default, rename = "sourceMessageID")]
    source_message_id: Option<String>,
}

#[derive(Serialize, Clone)]
pub struct MemoryEntry {
    pub id: String,
    #[serde(rename = "groupID")]
    pub group_id: String,
    pub category: Option<String>,
    pub text: String,
    #[serde(rename = "sourceMessageID", skip_serializing_if = "Option::is_none")]
    pub source_message_id: Option<String>,
    #[serde(rename = "createdAt")]
    pub created_at: i64,
}

pub async fn remember(
    State(state): State<AppState>,
    Path(group_id): Path<String>,
    Extension(principal): Extension<AuthPrincipal>,
    Json(req): Json<RememberReq>,
) -> Result<Json<MemoryEntry>, GatewayError> {
    let device_id = require_device(&principal)?;
    let pool = require_pool(&state)?;
    let conn = pool.lock();
    let is_member: bool = conn
        .query_row(
            "SELECT 1 FROM group_members WHERE group_id = ? AND device_id = ?",
            params![&group_id, &device_id],
            |r| r.get::<_, i64>(0),
        )
        .map(|_| true)
        .unwrap_or(false);
    if !is_member {
        return Err(GatewayError::Unauthorized("not a group member".into()));
    }
    let id = Uuid::new_v4().to_string();
    let now = unix_now();
    conn.execute(
        "INSERT INTO group_memory (id, group_id, category, text, source_message_id, created_at)
         VALUES (?, ?, ?, ?, ?, ?)",
        params![
            &id,
            &group_id,
            req.category.as_ref(),
            &req.text,
            req.source_message_id.as_ref(),
            now
        ],
    )
    .map_err(wrap)?;
    Ok(Json(MemoryEntry {
        id,
        group_id,
        category: req.category,
        text: req.text,
        source_message_id: req.source_message_id,
        created_at: now,
    }))
}

#[derive(Serialize)]
pub struct RecallRes {
    entries: Vec<MemoryEntry>,
}

pub async fn recall(
    State(state): State<AppState>,
    Path(group_id): Path<String>,
    Extension(principal): Extension<AuthPrincipal>,
) -> Result<Json<RecallRes>, GatewayError> {
    let device_id = require_device(&principal)?;
    let pool = require_pool(&state)?;
    let conn = pool.lock();
    let is_member: bool = conn
        .query_row(
            "SELECT 1 FROM group_members WHERE group_id = ? AND device_id = ?",
            params![&group_id, &device_id],
            |r| r.get::<_, i64>(0),
        )
        .map(|_| true)
        .unwrap_or(false);
    if !is_member {
        return Err(GatewayError::Unauthorized("not a group member".into()));
    }
    let mut stmt = conn
        .prepare(
            "SELECT id, group_id, category, text, source_message_id, created_at
             FROM group_memory WHERE group_id = ? ORDER BY created_at ASC",
        )
        .map_err(wrap)?;
    let entries: Vec<MemoryEntry> = stmt
        .query_map([&group_id], |r| {
            Ok(MemoryEntry {
                id: r.get(0)?,
                group_id: r.get(1)?,
                category: r.get(2)?,
                text: r.get(3)?,
                source_message_id: r.get(4)?,
                created_at: r.get(5)?,
            })
        })
        .map_err(wrap)?
        .filter_map(|r| r.ok())
        .collect();
    Ok(Json(RecallRes { entries }))
}

fn wrap(e: rusqlite::Error) -> GatewayError {
    GatewayError::Other(anyhow::anyhow!("db: {}", e))
}

// placate unused-import lint when `Response` is only used in future SSE code
#[allow(dead_code)]
fn _touch_response() -> Option<Response> {
    None
}
