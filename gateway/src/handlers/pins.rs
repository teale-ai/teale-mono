//! Private Inference Network (PIN) control-plane endpoints.
//!
//! The gateway coordinates PINs but never sees prompt content: scheduling
//! requests carry only a model id + context estimate, and usage reports
//! carry token COUNTS. Nothing in this module may write to `ledger` or
//! `balances` (see spec §8).
//!
//! Non-enumeration: unknown networks and networks the caller has no standing
//! in both return 404, and `/v1/pins/join` returns 202 whether or not the
//! join code matched anything.

use axum::extract::{Path, Query, State};
use axum::http::StatusCode;
use axum::{Extension, Json};
use serde::{Deserialize, Serialize};
use std::collections::HashMap;

use crate::auth::AuthPrincipal;
use crate::db::{unix_now, DbPool};
use crate::error::GatewayError;
use crate::ledger;
use crate::pins;
use crate::state::AppState;

fn require_pool(state: &AppState) -> Result<&DbPool, GatewayError> {
    state
        .db
        .as_ref()
        .ok_or_else(|| GatewayError::Other(anyhow::anyhow!("db not initialized")))
}

fn require_device(principal: &AuthPrincipal) -> Result<String, GatewayError> {
    principal
        .device_id()
        .map(|s| s.to_string())
        .ok_or_else(|| GatewayError::Unauthorized("PIN endpoints require a device token".into()))
}

/// The account behind a caller, when there is one: a device's linked account
/// or an API key's owning account.
fn account_of(pool: &DbPool, principal: &AuthPrincipal) -> Option<String> {
    if let Some(device_id) = principal.device_id() {
        return ledger::account_user_id_for_device(pool, device_id);
    }
    if let crate::auth::PrincipalKind::ApiKey {
        account_user_id, ..
    } = &principal.kind
    {
        return Some(account_user_id.clone());
    }
    None
}

#[derive(Debug, Clone, PartialEq)]
enum PinActor {
    Staff { account: String, role: String },
    Member { device_id: String },
}

impl PinActor {
    fn is_staff(&self) -> bool {
        matches!(self, PinActor::Staff { .. })
    }
}

/// Resolve the caller's standing in a network. Staff standing (via linked
/// account) wins over device membership. Callers with no standing get 404 —
/// indistinguishable from the network not existing.
fn resolve_actor(
    pool: &DbPool,
    principal: &AuthPrincipal,
    pin_id: &str,
) -> Result<PinActor, GatewayError> {
    if let Some(account) = account_of(pool, principal) {
        if let Some(role) = pins::role_of(pool, pin_id, &account).map_err(GatewayError::Other)? {
            return Ok(PinActor::Staff { account, role });
        }
    }
    if let Some(device_id) = principal.device_id() {
        let status = pins::member_status(pool, pin_id, device_id).map_err(GatewayError::Other)?;
        if matches!(status.as_deref(), Some("active")) {
            return Ok(PinActor::Member {
                device_id: device_id.to_string(),
            });
        }
    }
    Err(GatewayError::NotFound("unknown network".into()))
}

fn require_admin_actor(
    pool: &DbPool,
    principal: &AuthPrincipal,
    pin_id: &str,
) -> Result<String, GatewayError> {
    match resolve_actor(pool, principal, pin_id)? {
        PinActor::Staff { account, role } if role == pins::ROLE_ADMIN => Ok(account),
        // Staff-but-not-admin learns the network exists (they're in it);
        // that's a 403. Everyone else gets the non-enumeration 404 above.
        PinActor::Staff { .. } | PinActor::Member { .. } => {
            Err(GatewayError::Forbidden("requires the admin role".into()))
        }
    }
}

fn require_staff_actor(
    pool: &DbPool,
    principal: &AuthPrincipal,
    pin_id: &str,
) -> Result<String, GatewayError> {
    match resolve_actor(pool, principal, pin_id)? {
        PinActor::Staff { account, .. } => Ok(account),
        PinActor::Member { .. } => Err(GatewayError::Forbidden(
            "requires the admin or modelrator role".into(),
        )),
    }
}

// ---------------------------------------------------------------- create/list

#[derive(Deserialize)]
pub struct CreatePinReq {
    name: String,
}

pub async fn create_pin(
    State(state): State<AppState>,
    Extension(principal): Extension<AuthPrincipal>,
    Json(req): Json<CreatePinReq>,
) -> Result<Json<pins::Pin>, GatewayError> {
    let pool = require_pool(&state)?;
    let account = account_of(pool, &principal).ok_or_else(|| {
        GatewayError::Forbidden(
            "creating a network requires a device linked to a Teale account".into(),
        )
    })?;
    let pin = pins::create_pin(pool, &req.name, &account).map_err(GatewayError::Other)?;
    Ok(Json(pin))
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct MyPinsResponse {
    pub staff: Vec<pins::PinSummary>,
    pub memberships: Vec<pins::PinMembershipSummary>,
}

pub async fn list_pins(
    State(state): State<AppState>,
    Extension(principal): Extension<AuthPrincipal>,
) -> Result<Json<MyPinsResponse>, GatewayError> {
    let pool = require_pool(&state)?;
    let staff = match account_of(pool, &principal) {
        Some(account) => pins::pins_for_account(pool, &account).map_err(GatewayError::Other)?,
        None => Vec::new(),
    };
    let memberships = match principal.device_id() {
        Some(device_id) => pins::pins_for_device(pool, device_id).map_err(GatewayError::Other)?,
        None => Vec::new(),
    };
    Ok(Json(MyPinsResponse { staff, memberships }))
}

// ----------------------------------------------------------------------- join

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct JoinReq {
    join_code: String,
    #[serde(default)]
    display_name: Option<String>,
    node_pubkey: String,
}

/// Always 202 with an identical body — valid code, invalid code, or rate
/// limited. The join code must never become an oracle for which networks
/// exist (spec §13).
pub async fn join(
    State(state): State<AppState>,
    Extension(principal): Extension<AuthPrincipal>,
    Json(req): Json<JoinReq>,
) -> Result<(StatusCode, Json<serde_json::Value>), GatewayError> {
    let device_id = require_device(&principal)?;
    let pool = require_pool(&state)?;
    let submitted = serde_json::json!({ "status": "submitted" });

    if !state.pin_join_limiter.allow(&device_id, unix_now()) {
        return Ok((StatusCode::ACCEPTED, Json(submitted)));
    }
    if let Some(pin) = pins::find_by_join_code(pool, &req.join_code).map_err(GatewayError::Other)? {
        pins::submit_join(
            pool,
            &pin.pin_id,
            &device_id,
            &req.node_pubkey,
            req.display_name.as_deref(),
        )
        .map_err(GatewayError::Other)?;
    }
    Ok((StatusCode::ACCEPTED, Json(submitted)))
}

// --------------------------------------------------------------- detail/roster

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PinDetail {
    pub pin_id: String,
    pub name: String,
    pub settings: pins::PinSettings,
    pub netmap_generation: i64,
    pub created_at: i64,
    /// Caller's standing: "admin" | "modelrator" | "member".
    pub your_role: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub pending_count: Option<i64>,
}

pub async fn get_pin(
    State(state): State<AppState>,
    Extension(principal): Extension<AuthPrincipal>,
    Path(pin_id): Path<String>,
) -> Result<Json<PinDetail>, GatewayError> {
    let pool = require_pool(&state)?;
    let actor = resolve_actor(pool, &principal, &pin_id)?;
    let pin = pins::get_pin(pool, &pin_id)
        .map_err(GatewayError::Other)?
        .ok_or_else(|| GatewayError::NotFound("unknown network".into()))?;
    let pending_count = if actor.is_staff() {
        Some(
            pins::members(pool, &pin_id)
                .map_err(GatewayError::Other)?
                .iter()
                .filter(|m| m.status == "pending")
                .count() as i64,
        )
    } else {
        None
    };
    let your_role = match &actor {
        PinActor::Staff { role, .. } => role.clone(),
        PinActor::Member { .. } => "member".to_string(),
    };
    Ok(Json(PinDetail {
        pin_id: pin.pin_id,
        name: pin.name,
        settings: pin.settings,
        netmap_generation: pin.netmap_generation,
        created_at: pin.created_at,
        your_role,
        pending_count,
    }))
}

pub async fn list_members(
    State(state): State<AppState>,
    Extension(principal): Extension<AuthPrincipal>,
    Path(pin_id): Path<String>,
) -> Result<Json<Vec<pins::PinMember>>, GatewayError> {
    let pool = require_pool(&state)?;
    let actor = resolve_actor(pool, &principal, &pin_id)?;
    let mut members = pins::members(pool, &pin_id).map_err(GatewayError::Other)?;
    if !actor.is_staff() {
        // Members see the roster but not the approval queue.
        members.retain(|m| m.status != "pending");
    }
    Ok(Json(members))
}

// ----------------------------------------------------------- member lifecycle

pub async fn approve_member(
    State(state): State<AppState>,
    Extension(principal): Extension<AuthPrincipal>,
    Path((pin_id, device_id)): Path<(String, String)>,
) -> Result<Json<serde_json::Value>, GatewayError> {
    let pool = require_pool(&state)?;
    let account = require_admin_actor(pool, &principal, &pin_id)?;
    pins::approve_member(pool, &pin_id, &device_id, &account)
        .map_err(|e| GatewayError::Conflict(e.to_string()))?;
    Ok(Json(serde_json::json!({ "status": "active" })))
}

pub async fn deny_member(
    State(state): State<AppState>,
    Extension(principal): Extension<AuthPrincipal>,
    Path((pin_id, device_id)): Path<(String, String)>,
) -> Result<Json<serde_json::Value>, GatewayError> {
    let pool = require_pool(&state)?;
    require_admin_actor(pool, &principal, &pin_id)?;
    pins::deny_member(pool, &pin_id, &device_id)
        .map_err(|e| GatewayError::Conflict(e.to_string()))?;
    Ok(Json(serde_json::json!({ "status": "denied" })))
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PatchMemberReq {
    #[serde(default)]
    display_name: Option<String>,
    #[serde(default)]
    serves_models: Option<bool>,
    #[serde(default)]
    disabled: Option<bool>,
}

pub async fn patch_member(
    State(state): State<AppState>,
    Extension(principal): Extension<AuthPrincipal>,
    Path((pin_id, device_id)): Path<(String, String)>,
    Json(req): Json<PatchMemberReq>,
) -> Result<Json<serde_json::Value>, GatewayError> {
    let pool = require_pool(&state)?;
    // Rename + serving toggle: admin or modelrator. Disable: admin only.
    if req.disabled.is_some() {
        require_admin_actor(pool, &principal, &pin_id)?;
    } else {
        require_staff_actor(pool, &principal, &pin_id)?;
    }
    if req.display_name.is_some() || req.serves_models.is_some() {
        pins::update_member(
            pool,
            &pin_id,
            &device_id,
            req.display_name.as_deref(),
            req.serves_models,
        )
        .map_err(|e| GatewayError::Conflict(e.to_string()))?;
    }
    if let Some(disabled) = req.disabled {
        pins::set_member_disabled(pool, &pin_id, &device_id, disabled)
            .map_err(|e| GatewayError::Conflict(e.to_string()))?;
    }
    Ok(Json(serde_json::json!({ "status": "ok" })))
}

pub async fn remove_member(
    State(state): State<AppState>,
    Extension(principal): Extension<AuthPrincipal>,
    Path((pin_id, device_id)): Path<(String, String)>,
) -> Result<Json<serde_json::Value>, GatewayError> {
    let pool = require_pool(&state)?;
    let account = require_admin_actor(pool, &principal, &pin_id)?;
    pins::remove_member(pool, &pin_id, &device_id, &account)
        .map_err(|e| GatewayError::Conflict(e.to_string()))?;
    Ok(Json(serde_json::json!({ "status": "removed" })))
}

// ------------------------------------------------------------ codes/roles/etc

pub async fn rotate_code(
    State(state): State<AppState>,
    Extension(principal): Extension<AuthPrincipal>,
    Path(pin_id): Path<String>,
) -> Result<Json<serde_json::Value>, GatewayError> {
    let pool = require_pool(&state)?;
    require_admin_actor(pool, &principal, &pin_id)?;
    let code = pins::rotate_join_code(pool, &pin_id).map_err(GatewayError::Other)?;
    Ok(Json(serde_json::json!({ "joinCode": code })))
}

pub async fn get_join_code(
    State(state): State<AppState>,
    Extension(principal): Extension<AuthPrincipal>,
    Path(pin_id): Path<String>,
) -> Result<Json<serde_json::Value>, GatewayError> {
    let pool = require_pool(&state)?;
    require_admin_actor(pool, &principal, &pin_id)?;
    let pin = pins::get_pin(pool, &pin_id)
        .map_err(GatewayError::Other)?
        .ok_or_else(|| GatewayError::NotFound("unknown network".into()))?;
    Ok(Json(serde_json::json!({ "joinCode": pin.join_code })))
}

#[derive(Deserialize)]
pub struct SetRoleReq {
    /// "admin" | "modelrator" | null (revoke).
    pub role: Option<String>,
}

pub async fn set_role(
    State(state): State<AppState>,
    Extension(principal): Extension<AuthPrincipal>,
    Path((pin_id, account)): Path<(String, String)>,
    Json(req): Json<SetRoleReq>,
) -> Result<Json<serde_json::Value>, GatewayError> {
    let pool = require_pool(&state)?;
    let granter = require_admin_actor(pool, &principal, &pin_id)?;
    match req.role.as_deref() {
        Some(role) => pins::grant_role(pool, &pin_id, &account, role, &granter)
            .map_err(|e| GatewayError::BadRequest(e.to_string()))?,
        None => pins::revoke_role(pool, &pin_id, &account)
            .map_err(|e| GatewayError::Conflict(e.to_string()))?,
    }
    Ok(Json(serde_json::json!({ "status": "ok" })))
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SettingsReq {
    #[serde(default)]
    din_contribution_default: Option<bool>,
    #[serde(default)]
    priority_policy: Option<String>,
}

pub async fn put_settings(
    State(state): State<AppState>,
    Extension(principal): Extension<AuthPrincipal>,
    Path(pin_id): Path<String>,
    Json(req): Json<SettingsReq>,
) -> Result<Json<pins::PinSettings>, GatewayError> {
    let pool = require_pool(&state)?;
    require_staff_actor(pool, &principal, &pin_id)?;
    let pin = pins::get_pin(pool, &pin_id)
        .map_err(GatewayError::Other)?
        .ok_or_else(|| GatewayError::NotFound("unknown network".into()))?;
    let mut settings = pin.settings;
    if let Some(v) = req.din_contribution_default {
        settings.din_contribution_default = v;
    }
    if let Some(v) = req.priority_policy {
        if v != "pin_first" && v != "equal" {
            return Err(GatewayError::BadRequest(
                "priorityPolicy must be pin_first or equal".into(),
            ));
        }
        settings.priority_policy = v;
    }
    pins::set_settings(pool, &pin_id, &settings).map_err(GatewayError::Other)?;
    Ok(Json(settings))
}

pub async fn delete_pin(
    State(state): State<AppState>,
    Extension(principal): Extension<AuthPrincipal>,
    Path(pin_id): Path<String>,
) -> Result<Json<serde_json::Value>, GatewayError> {
    let pool = require_pool(&state)?;
    let account = require_admin_actor(pool, &principal, &pin_id)?;
    let pin = pins::get_pin(pool, &pin_id)
        .map_err(GatewayError::Other)?
        .ok_or_else(|| GatewayError::NotFound("unknown network".into()))?;
    if pin.owner_account_user_id != account {
        return Err(GatewayError::Forbidden(
            "only the owner can delete a network".into(),
        ));
    }
    pins::delete_pin(pool, &pin_id).map_err(GatewayError::Other)?;
    Ok(Json(serde_json::json!({ "status": "deleted" })))
}

// ----------------------------------------------------------------------- sync

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SyncReq {
    #[serde(default)]
    endpoints: Vec<teale_protocol::PinEndpoint>,
    #[serde(default)]
    loaded_models: Vec<String>,
    #[serde(default)]
    known_generation: Option<i64>,
    /// (modelId, appliedState, error) reconciliation reports.
    #[serde(default)]
    model_policy_status: Vec<ModelPolicyStatusReq>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ModelPolicyStatusReq {
    model_id: String,
    applied_state: String,
    #[serde(default)]
    error: Option<String>,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SyncResponse {
    /// "pending" | "active" | "disabled" | "none"
    pub membership: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub netmap: Option<teale_protocol::SignedPinNetmap>,
    #[serde(skip_serializing_if = "Vec::is_empty")]
    pub model_policy: Vec<pins::ModelPolicyEntry>,
    pub settings: Option<pins::PinSettings>,
}

/// Member-device poll: advertise endpoints + report policy status, receive
/// membership state, the netmap (when newer than `knownGeneration`), and the
/// device's desired model loadout. Pending/removed devices get membership
/// status only — same 200 shape, no oracle.
pub async fn sync(
    State(state): State<AppState>,
    Extension(principal): Extension<AuthPrincipal>,
    Path(pin_id): Path<String>,
    Json(req): Json<SyncReq>,
) -> Result<Json<SyncResponse>, GatewayError> {
    let device_id = require_device(&principal)?;
    let pool = require_pool(&state)?;
    let status = pins::member_status(pool, &pin_id, &device_id)
        .map_err(GatewayError::Other)?
        .unwrap_or_else(|| "none".to_string());
    if status != "active" {
        let membership = if status == "removed" {
            "none".into()
        } else {
            status
        };
        return Ok(Json(SyncResponse {
            membership,
            netmap: None,
            model_policy: Vec::new(),
            settings: None,
        }));
    }

    let endpoints_json =
        serde_json::to_string(&req.endpoints).map_err(|e| GatewayError::Other(e.into()))?;
    let loaded_models_json =
        serde_json::to_string(&req.loaded_models).map_err(|e| GatewayError::Other(e.into()))?;
    pins::update_member_endpoints(
        pool,
        &pin_id,
        &device_id,
        &endpoints_json,
        &loaded_models_json,
    )
    .map_err(GatewayError::Other)?;
    if !req.model_policy_status.is_empty() {
        let statuses: Vec<(String, String, Option<String>)> = req
            .model_policy_status
            .into_iter()
            .map(|s| (s.model_id, s.applied_state, s.error))
            .collect();
        pins::report_model_policy_status(pool, &pin_id, &device_id, &statuses)
            .map_err(GatewayError::Other)?;
    }

    let pin = pins::get_pin(pool, &pin_id)
        .map_err(GatewayError::Other)?
        .ok_or_else(|| GatewayError::NotFound("unknown network".into()))?;
    let netmap = if req.known_generation != Some(pin.netmap_generation) {
        let identity = state
            .identity
            .as_ref()
            .ok_or_else(|| GatewayError::Other(anyhow::anyhow!("gateway identity unavailable")))?;
        let devices = state.registry.snapshot_devices();
        let by_pubkey: HashMap<String, Vec<String>> = devices
            .into_iter()
            .map(|d| (d.node_id.clone(), d.capabilities.loaded_models))
            .collect();
        let netmap = pins::build_netmap(pool, &pin_id, |pubkey| {
            by_pubkey.get(pubkey).map(|models| pins::LiveMemberInfo {
                loaded_models: models.clone(),
            })
        })
        .map_err(GatewayError::Other)?;
        Some(pins::sign_netmap(netmap, identity).map_err(GatewayError::Other)?)
    } else {
        pins::touch_member_last_seen(pool, &pin_id, &device_id).map_err(GatewayError::Other)?;
        None
    };
    let model_policy =
        pins::model_policy(pool, &pin_id, Some(&device_id)).map_err(GatewayError::Other)?;
    Ok(Json(SyncResponse {
        membership: "active".into(),
        netmap,
        model_policy,
        settings: Some(pin.settings),
    }))
}

// ------------------------------------------------------------------- schedule

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ScheduleReq {
    model: String,
    #[serde(default)]
    ctx_estimate: Option<u32>,
    /// Node pubkeys to exclude (already-failed candidates in a cascade).
    #[serde(default)]
    exclude: Vec<String>,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ScheduleResponse {
    pub device_id: String,
    pub node_pubkey: String,
    pub display_name: Option<String>,
    pub endpoints: Vec<teale_protocol::PinEndpoint>,
}

/// PIN-scoped device selection. The request carries metadata only (model
/// id + context estimate) — never prompt content; the field set of
/// ScheduleReq is the enforcement.
pub async fn schedule(
    State(state): State<AppState>,
    Extension(principal): Extension<AuthPrincipal>,
    Path(pin_id): Path<String>,
    Json(req): Json<ScheduleReq>,
) -> Result<Json<ScheduleResponse>, GatewayError> {
    let pool = require_pool(&state)?;
    resolve_actor(pool, &principal, &pin_id)?;

    let members = pins::members(pool, &pin_id).map_err(GatewayError::Other)?;
    let serving: HashMap<String, &pins::PinMember> = members
        .iter()
        .filter(|m| m.status == "active" && m.serves_models)
        .map(|m| (m.node_pubkey.clone(), m))
        .collect();

    // Candidates = live registry devices that are serving members of this
    // network. Requester's own device may serve itself; no self-exclusion.
    let candidates: Vec<_> = state
        .registry
        .snapshot_devices()
        .into_iter()
        .filter(|d| serving.contains_key(&d.node_id))
        .collect();

    let picked = state
        .scheduler
        .pick(
            &candidates,
            &req.model,
            &req.exclude,
            &state.registry,
            req.ctx_estimate,
        )
        .ok_or_else(|| GatewayError::NoEligibleDevice(req.model.clone()))?;

    let member = serving
        .get(&picked.node_id)
        .expect("picked device is a serving member");
    Ok(Json(ScheduleResponse {
        device_id: member.device_id.clone(),
        node_pubkey: member.node_pubkey.clone(),
        display_name: member.display_name.clone(),
        endpoints: serde_json::from_str(&member.endpoints).unwrap_or_default(),
    }))
}

// -------------------------------------------------------------- model policy

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SetModelsReq {
    models: Vec<ModelStateReq>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ModelStateReq {
    model_id: String,
    desired_state: String,
}

pub async fn set_device_models(
    State(state): State<AppState>,
    Extension(principal): Extension<AuthPrincipal>,
    Path((pin_id, device_id)): Path<(String, String)>,
    Json(req): Json<SetModelsReq>,
) -> Result<Json<Vec<pins::ModelPolicyEntry>>, GatewayError> {
    let pool = require_pool(&state)?;
    let account = require_staff_actor(pool, &principal, &pin_id)?;
    let status = pins::member_status(pool, &pin_id, &device_id).map_err(GatewayError::Other)?;
    if !matches!(status.as_deref(), Some("active") | Some("disabled")) {
        return Err(GatewayError::NotFound("unknown device".into()));
    }
    let models: Vec<(String, String)> = req
        .models
        .into_iter()
        .map(|m| (m.model_id, m.desired_state))
        .collect();
    pins::set_model_policy(pool, &pin_id, &device_id, &models, &account)
        .map_err(|e| GatewayError::BadRequest(e.to_string()))?;
    let policy =
        pins::model_policy(pool, &pin_id, Some(&device_id)).map_err(GatewayError::Other)?;
    Ok(Json(policy))
}

pub async fn get_models(
    State(state): State<AppState>,
    Extension(principal): Extension<AuthPrincipal>,
    Path(pin_id): Path<String>,
) -> Result<Json<Vec<pins::ModelPolicyEntry>>, GatewayError> {
    let pool = require_pool(&state)?;
    resolve_actor(pool, &principal, &pin_id)?;
    let policy = pins::model_policy(pool, &pin_id, None).map_err(GatewayError::Other)?;
    Ok(Json(policy))
}

// -------------------------------------------------------------------- usage

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct UsageReportReq {
    batch_id: String,
    entries: Vec<pins::UsageEntry>,
}

pub async fn usage_report(
    State(state): State<AppState>,
    Extension(principal): Extension<AuthPrincipal>,
    Path(pin_id): Path<String>,
    Json(req): Json<UsageReportReq>,
) -> Result<Json<serde_json::Value>, GatewayError> {
    let device_id = require_device(&principal)?;
    let pool = require_pool(&state)?;
    let status = pins::member_status(pool, &pin_id, &device_id).map_err(GatewayError::Other)?;
    if status.as_deref() != Some("active") {
        return Err(GatewayError::NotFound("unknown network".into()));
    }
    if req.batch_id.trim().is_empty() {
        return Err(GatewayError::BadRequest("batchId is required".into()));
    }
    let applied = pins::record_usage_batch(pool, &pin_id, &device_id, &req.batch_id, &req.entries)
        .map_err(|e| GatewayError::BadRequest(e.to_string()))?;
    Ok(Json(serde_json::json!({
        "status": if applied { "applied" } else { "duplicate" }
    })))
}

#[derive(Deserialize)]
pub struct UsageQuery {
    #[serde(default)]
    from: Option<String>,
    #[serde(default)]
    to: Option<String>,
    /// "day" | "device" | "model" — grouping for the `totals` block.
    #[serde(default)]
    by: Option<String>,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct UsageResponse {
    pub rows: Vec<pins::UsageRow>,
    /// key → (requests, tokensIn, tokensOut) grouped per `by`.
    pub totals: Vec<UsageTotal>,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct UsageTotal {
    pub key: String,
    pub requests: i64,
    pub tokens_in: i64,
    pub tokens_out: i64,
}

pub async fn usage(
    State(state): State<AppState>,
    Extension(principal): Extension<AuthPrincipal>,
    Path(pin_id): Path<String>,
    Query(q): Query<UsageQuery>,
) -> Result<Json<UsageResponse>, GatewayError> {
    let pool = require_pool(&state)?;
    let actor = resolve_actor(pool, &principal, &pin_id)?;
    // Staff see the whole network; members see only their own consumption.
    let consumer_filter = match &actor {
        PinActor::Staff { .. } => None,
        PinActor::Member { device_id } => Some(device_id.clone()),
    };
    let rows = pins::usage_rows(
        pool,
        &pin_id,
        q.from.as_deref(),
        q.to.as_deref(),
        consumer_filter.as_deref(),
    )
    .map_err(GatewayError::Other)?;

    let by = q.by.as_deref().unwrap_or("day");
    let mut grouped: HashMap<String, (i64, i64, i64)> = HashMap::new();
    for row in &rows {
        let key = match by {
            "device" => row.provider_device_id.clone(),
            "model" => row.model_id.clone(),
            "consumer" => row.consumer_device_id.clone(),
            _ => row.day.clone(),
        };
        let entry = grouped.entry(key).or_default();
        entry.0 += row.requests;
        entry.1 += row.tokens_in;
        entry.2 += row.tokens_out;
    }
    let mut totals: Vec<UsageTotal> = grouped
        .into_iter()
        .map(|(key, (requests, tokens_in, tokens_out))| UsageTotal {
            key,
            requests,
            tokens_in,
            tokens_out,
        })
        .collect();
    totals.sort_by(|a, b| a.key.cmp(&b.key));
    Ok(Json(UsageResponse { rows, totals }))
}

#[cfg(test)]
mod tests {
    use std::sync::Arc;

    use axum::extract::{Path, Query, State};
    use axum::{Extension, Json};
    use tokio::sync::broadcast;

    use super::*;
    use crate::auth::{AuthPrincipal, PrincipalKind, TokenTable};
    use crate::config::Config;
    use crate::db::open_in_memory;
    use crate::ledger::AccountLinkMetadata;
    use crate::model_metrics::ModelMetricsTracker;
    use crate::registry::Registry;
    use crate::relay_client::RelayHandle;
    use crate::scheduler::Scheduler;
    use teale_protocol::{HardwareCapability, NodeCapabilities};

    fn test_state(pool: DbPool) -> AppState {
        let cfg = Config::defaults();
        let dir = std::env::temp_dir().join(format!("pin-handler-{}", uuid::Uuid::new_v4()));
        let identity =
            crate::identity::GatewayIdentity::load_or_create(dir.join("id.key").to_str().unwrap())
                .unwrap();
        AppState {
            config: cfg.clone(),
            tokens: TokenTable::default(),
            registry: Registry::new(cfg.reliability.clone()),
            scheduler: Arc::new(Scheduler::new(cfg.scheduler.clone())),
            relay: RelayHandle::test_handle(),
            catalog: Arc::new(vec![]),
            db: Some(pool),
            group_tx: broadcast::channel(8).0,
            model_metrics: Arc::new(ModelMetricsTracker::new()),
            share_key_issuers: Default::default(),
            providers: crate::providers::ProvidersHandle::empty_for_test(),
            identity: Some(Arc::new(identity)),
            pin_join_limiter: Default::default(),
        }
    }

    fn device(device_id: &str) -> AuthPrincipal {
        AuthPrincipal {
            kind: PrincipalKind::Device {
                device_id: device_id.into(),
            },
        }
    }

    /// Create an account + link a device to it (the staff-auth path).
    fn link(pool: &DbPool, device_id: &str, account: &str) {
        ledger::link_device_to_account(
            pool,
            device_id,
            account,
            &AccountLinkMetadata {
                device_name: None,
                platform: None,
                display_name: None,
                phone: None,
                email: None,
                github_username: None,
            },
        )
        .unwrap();
    }

    fn caps(loaded: &[&str]) -> NodeCapabilities {
        NodeCapabilities {
            hardware: HardwareCapability {
                chip_family: "m4Max".into(),
                chip_name: "m4Max".into(),
                total_ram_gb: 64.0,
                gpu_core_count: 40,
                memory_bandwidth_gbs: 546.0,
                tier: 1,
                gpu_backend: Some("metal".into()),
                platform: Some("macOS".into()),
                gpu_vram_gb: None,
            },
            loaded_models: loaded.iter().map(|s| s.to_string()).collect(),
            max_model_size_gb: 48.0,
            is_available: true,
            ptn_ids: None,
            swappable_models: vec![],
            max_concurrent_requests: Some(4),
            effective_context: Some(32768),
            on_ac_power: None,
        }
    }

    /// Owner creates network; returns (state, pin, join_code).
    async fn network(pool: DbPool) -> (AppState, crate::pins::Pin) {
        let state = test_state(pool.clone());
        link(&pool, "owner-dev", "owner-acct");
        let Json(pin) = create_pin(
            State(state.clone()),
            Extension(device("owner-dev")),
            Json(CreatePinReq {
                name: "teale-hq".into(),
            }),
        )
        .await
        .unwrap();
        (state, pin)
    }

    async fn knock(state: &AppState, dev: &str, code: &str) {
        let (status, Json(body)) = join(
            State(state.clone()),
            Extension(device(dev)),
            Json(JoinReq {
                join_code: code.into(),
                display_name: None,
                node_pubkey: format!("{dev}-pubkey"),
            }),
        )
        .await
        .unwrap();
        assert_eq!(status, StatusCode::ACCEPTED);
        assert_eq!(body, serde_json::json!({"status":"submitted"}));
    }

    #[tokio::test]
    async fn join_is_not_an_oracle() {
        let pool = open_in_memory().unwrap();
        let (state, pin) = network(pool.clone()).await;

        // Wrong code and right code: byte-identical responses.
        knock(&state, "dev-1", "WRONG-CODE-XX").await;
        knock(&state, "dev-1", &pin.join_code).await;

        // Only the right code produced a pending membership.
        let Json(mine) = list_pins(State(state.clone()), Extension(device("dev-1")))
            .await
            .unwrap();
        assert_eq!(mine.memberships.len(), 1);
        assert_eq!(mine.memberships[0].status, "pending");
    }

    #[tokio::test]
    async fn join_rate_limit_stops_brute_force_silently() {
        let pool = open_in_memory().unwrap();
        let (state, pin) = network(pool.clone()).await;

        for _ in 0..crate::state::PinJoinLimiter::MAX_PER_WINDOW {
            knock(&state, "brute-dev", "WRONG-GUESS-01").await;
        }
        // Over the limit: same 202, but the correct code no longer lands.
        knock(&state, "brute-dev", &pin.join_code).await;
        let Json(mine) = list_pins(State(state.clone()), Extension(device("brute-dev")))
            .await
            .unwrap();
        assert!(
            mine.memberships.is_empty(),
            "limited knock must not enqueue"
        );
    }

    #[tokio::test]
    async fn approval_flow_and_role_gates() {
        let pool = open_in_memory().unwrap();
        let (state, pin) = network(pool.clone()).await;
        knock(&state, "dev-1", &pin.join_code).await;

        // Modelrator cannot approve (403), stranger sees 404.
        link(&pool, "mod-dev", "mod-acct");
        crate::pins::grant_role(&pool, &pin.pin_id, "mod-acct", "modelrator", "owner-acct")
            .unwrap();
        let err = approve_member(
            State(state.clone()),
            Extension(device("mod-dev")),
            Path((pin.pin_id.clone(), "dev-1".into())),
        )
        .await
        .unwrap_err();
        assert!(matches!(err, GatewayError::Forbidden(_)));

        let err = approve_member(
            State(state.clone()),
            Extension(device("stranger-dev")),
            Path((pin.pin_id.clone(), "dev-1".into())),
        )
        .await
        .unwrap_err();
        assert!(matches!(err, GatewayError::NotFound(_)));

        approve_member(
            State(state.clone()),
            Extension(device("owner-dev")),
            Path((pin.pin_id.clone(), "dev-1".into())),
        )
        .await
        .unwrap();

        // Member sees roster without pending entries; staff sees all.
        knock(&state, "dev-2", &pin.join_code).await;
        let Json(as_member) = list_members(
            State(state.clone()),
            Extension(device("dev-1")),
            Path(pin.pin_id.clone()),
        )
        .await
        .unwrap();
        assert!(as_member.iter().all(|m| m.status != "pending"));
        let Json(as_staff) = list_members(
            State(state.clone()),
            Extension(device("owner-dev")),
            Path(pin.pin_id.clone()),
        )
        .await
        .unwrap();
        assert!(as_staff.iter().any(|m| m.status == "pending"));
    }

    #[tokio::test]
    async fn unknown_network_is_404_for_outsiders() {
        let pool = open_in_memory().unwrap();
        let (state, pin) = network(pool.clone()).await;
        let err = get_pin(
            State(state.clone()),
            Extension(device("outsider")),
            Path(pin.pin_id.clone()),
        )
        .await
        .unwrap_err();
        assert!(matches!(err, GatewayError::NotFound(_)));
        let err = get_pin(
            State(state),
            Extension(device("outsider")),
            Path("no-such-network".into()),
        )
        .await
        .unwrap_err();
        assert!(matches!(err, GatewayError::NotFound(_)));
    }

    async fn sync_once(
        state: &AppState,
        dev: &str,
        pin_id: &str,
        known_generation: Option<i64>,
    ) -> SyncResponse {
        let Json(resp) = sync(
            State(state.clone()),
            Extension(device(dev)),
            Path(pin_id.to_string()),
            Json(SyncReq {
                endpoints: vec![teale_protocol::PinEndpoint {
                    kind: "lan".into(),
                    addr: "10.0.0.9:41641".into(),
                }],
                loaded_models: vec!["advertised-model".into()],
                known_generation,
                model_policy_status: vec![],
            }),
        )
        .await
        .unwrap();
        resp
    }

    #[tokio::test]
    async fn sync_lifecycle_pending_active_removed() {
        let pool = open_in_memory().unwrap();
        let (state, pin) = network(pool.clone()).await;
        knock(&state, "dev-1", &pin.join_code).await;

        let resp = sync_once(&state, "dev-1", &pin.pin_id, None).await;
        assert_eq!(resp.membership, "pending");
        assert!(resp.netmap.is_none());

        crate::pins::approve_member(&pool, &pin.pin_id, "dev-1", "owner-acct").unwrap();
        let resp = sync_once(&state, "dev-1", &pin.pin_id, None).await;
        assert_eq!(resp.membership, "active");
        let signed = resp.netmap.expect("netmap on first active sync");
        let gen = signed.netmap.generation;
        assert!(signed.verify(&state.identity.as_ref().unwrap().public_key_hex()));
        // Endpoints advertised via sync appear in the netmap.
        let me = signed
            .netmap
            .members
            .iter()
            .find(|m| m.device_id == "dev-1")
            .unwrap();
        assert_eq!(me.endpoints[0].addr, "10.0.0.9:41641");
        // Registry is empty in this test: netmap falls back to the models
        // the device advertised on sync.
        assert_eq!(me.loaded_models, vec!["advertised-model".to_string()]);

        // Same generation → no netmap payload.
        let resp = sync_once(&state, "dev-1", &pin.pin_id, Some(gen)).await;
        assert!(resp.netmap.is_none());

        // Membership change bumps generation → netmap returned again.
        knock(&state, "dev-2", &pin.join_code).await;
        crate::pins::approve_member(&pool, &pin.pin_id, "dev-2", "owner-acct").unwrap();
        let resp = sync_once(&state, "dev-1", &pin.pin_id, Some(gen)).await;
        assert!(resp.netmap.is_some());

        crate::pins::remove_member(&pool, &pin.pin_id, "dev-1", "owner-acct").unwrap();
        let resp = sync_once(&state, "dev-1", &pin.pin_id, None).await;
        assert_eq!(resp.membership, "none");
        assert!(resp.netmap.is_none());
    }

    #[tokio::test]
    async fn schedule_picks_serving_member_with_model() {
        let pool = open_in_memory().unwrap();
        let (state, pin) = network(pool.clone()).await;
        for dev in ["dev-a", "dev-b", "dev-c"] {
            knock(&state, dev, &pin.join_code).await;
            crate::pins::approve_member(&pool, &pin.pin_id, dev, "owner-acct").unwrap();
        }
        // dev-c opts out of serving.
        crate::pins::update_member(&pool, &pin.pin_id, "dev-c", None, Some(false)).unwrap();

        // Registry: dev-a has the model; dev-b lacks it; dev-c has it but
        // doesn't serve. An unrelated DIN device also has it and must never
        // be picked for PIN traffic.
        state
            .registry
            .upsert_device("dev-a-pubkey".into(), "A".into(), caps(&["qwen3-4b"]));
        state
            .registry
            .upsert_device("dev-b-pubkey".into(), "B".into(), caps(&[]));
        state
            .registry
            .upsert_device("dev-c-pubkey".into(), "C".into(), caps(&["qwen3-4b"]));
        state
            .registry
            .upsert_device("din-outsider".into(), "X".into(), caps(&["qwen3-4b"]));

        let Json(resp) = schedule(
            State(state.clone()),
            Extension(device("dev-b")),
            Path(pin.pin_id.clone()),
            Json(ScheduleReq {
                model: "qwen3-4b".into(),
                ctx_estimate: None,
                exclude: vec![],
            }),
        )
        .await
        .unwrap();
        assert_eq!(resp.device_id, "dev-a");
        assert_eq!(resp.node_pubkey, "dev-a-pubkey");

        // Excluding the only candidate → 503-shaped error.
        let err = schedule(
            State(state.clone()),
            Extension(device("dev-b")),
            Path(pin.pin_id.clone()),
            Json(ScheduleReq {
                model: "qwen3-4b".into(),
                ctx_estimate: None,
                exclude: vec!["dev-a-pubkey".into()],
            }),
        )
        .await
        .unwrap_err();
        assert!(matches!(err, GatewayError::NoEligibleDevice(_)));
    }

    #[tokio::test]
    async fn model_policy_round_trip_via_sync() {
        let pool = open_in_memory().unwrap();
        let (state, pin) = network(pool.clone()).await;
        knock(&state, "dev-1", &pin.join_code).await;
        crate::pins::approve_member(&pool, &pin.pin_id, "dev-1", "owner-acct").unwrap();

        let Json(policy) = set_device_models(
            State(state.clone()),
            Extension(device("owner-dev")),
            Path((pin.pin_id.clone(), "dev-1".into())),
            Json(SetModelsReq {
                models: vec![ModelStateReq {
                    model_id: "glm-5.2".into(),
                    desired_state: "loaded".into(),
                }],
            }),
        )
        .await
        .unwrap();
        assert_eq!(policy.len(), 1);
        assert_eq!(policy[0].applied_state, None);

        // Device sees the policy on sync and reports progress.
        let resp = sync_once(&state, "dev-1", &pin.pin_id, None).await;
        assert_eq!(resp.model_policy.len(), 1);
        assert_eq!(resp.model_policy[0].desired_state, "loaded");

        let Json(resp2) = sync(
            State(state.clone()),
            Extension(device("dev-1")),
            Path(pin.pin_id.clone()),
            Json(SyncReq {
                endpoints: vec![],
                loaded_models: vec![],
                known_generation: None,
                model_policy_status: vec![ModelPolicyStatusReq {
                    model_id: "glm-5.2".into(),
                    applied_state: "loaded".into(),
                    error: None,
                }],
            }),
        )
        .await
        .unwrap();
        assert_eq!(
            resp2.model_policy[0].applied_state.as_deref(),
            Some("loaded")
        );

        // Invalid desired state rejected.
        let err = set_device_models(
            State(state.clone()),
            Extension(device("owner-dev")),
            Path((pin.pin_id.clone(), "dev-1".into())),
            Json(SetModelsReq {
                models: vec![ModelStateReq {
                    model_id: "x".into(),
                    desired_state: "banana".into(),
                }],
            }),
        )
        .await
        .unwrap_err();
        assert!(matches!(err, GatewayError::BadRequest(_)));
    }

    #[tokio::test]
    async fn usage_reporting_dedup_scope_and_ledger_isolation() {
        let pool = open_in_memory().unwrap();
        let (state, pin) = network(pool.clone()).await;
        for dev in ["provider-dev", "consumer-dev"] {
            knock(&state, dev, &pin.join_code).await;
            crate::pins::approve_member(&pool, &pin.pin_id, dev, "owner-acct").unwrap();
        }

        let ledger_before: i64 = {
            let conn = pool.lock();
            conn.query_row("SELECT count(*) FROM ledger", [], |r| r.get(0))
                .unwrap()
        };

        let report = UsageReportReq {
            batch_id: "batch-1".into(),
            entries: vec![crate::pins::UsageEntry {
                day: "2026-07-04".into(),
                consumer_device_id: "consumer-dev".into(),
                model_id: "qwen3-4b".into(),
                requests: 3,
                tokens_in: 1200,
                tokens_out: 450,
            }],
        };
        let Json(resp) = usage_report(
            State(state.clone()),
            Extension(device("provider-dev")),
            Path(pin.pin_id.clone()),
            Json(report),
        )
        .await
        .unwrap();
        assert_eq!(resp["status"], "applied");

        // Replaying the same batch id is dropped.
        let Json(resp) = usage_report(
            State(state.clone()),
            Extension(device("provider-dev")),
            Path(pin.pin_id.clone()),
            Json(UsageReportReq {
                batch_id: "batch-1".into(),
                entries: vec![crate::pins::UsageEntry {
                    day: "2026-07-04".into(),
                    consumer_device_id: "consumer-dev".into(),
                    model_id: "qwen3-4b".into(),
                    requests: 3,
                    tokens_in: 1200,
                    tokens_out: 450,
                }],
            }),
        )
        .await
        .unwrap();
        assert_eq!(resp["status"], "duplicate");

        // Staff sees totals; totals reflect exactly one application.
        let Json(staff_usage) = usage(
            State(state.clone()),
            Extension(device("owner-dev")),
            Path(pin.pin_id.clone()),
            Query(UsageQuery {
                from: None,
                to: None,
                by: Some("model".into()),
            }),
        )
        .await
        .unwrap();
        assert_eq!(staff_usage.totals.len(), 1);
        assert_eq!(staff_usage.totals[0].tokens_in, 1200);

        // A member who consumed nothing sees nothing.
        let Json(member_usage) = usage(
            State(state.clone()),
            Extension(device("provider-dev")),
            Path(pin.pin_id.clone()),
            Query(UsageQuery {
                from: None,
                to: None,
                by: None,
            }),
        )
        .await
        .unwrap();
        assert!(member_usage.rows.is_empty());

        // The consumer sees their own rows.
        let Json(consumer_usage) = usage(
            State(state.clone()),
            Extension(device("consumer-dev")),
            Path(pin.pin_id.clone()),
            Query(UsageQuery {
                from: None,
                to: None,
                by: None,
            }),
        )
        .await
        .unwrap();
        assert_eq!(consumer_usage.rows.len(), 1);

        // THE invariant: the entire PIN flow wrote zero ledger rows.
        let ledger_after: i64 = {
            let conn = pool.lock();
            conn.query_row("SELECT count(*) FROM ledger", [], |r| r.get(0))
                .unwrap()
        };
        assert_eq!(
            ledger_before, ledger_after,
            "PIN flow must never touch the ledger"
        );
    }

    #[tokio::test]
    async fn settings_and_admin_only_surfaces() {
        let pool = open_in_memory().unwrap();
        let (state, pin) = network(pool.clone()).await;
        link(&pool, "mod-dev", "mod-acct");
        crate::pins::grant_role(&pool, &pin.pin_id, "mod-acct", "modelrator", "owner-acct")
            .unwrap();

        // Modelrator can change settings…
        let Json(settings) = put_settings(
            State(state.clone()),
            Extension(device("mod-dev")),
            Path(pin.pin_id.clone()),
            Json(SettingsReq {
                din_contribution_default: Some(false),
                priority_policy: None,
            }),
        )
        .await
        .unwrap();
        assert!(!settings.din_contribution_default);

        // …but not read or rotate the join code, or delete the network.
        assert!(matches!(
            get_join_code(
                State(state.clone()),
                Extension(device("mod-dev")),
                Path(pin.pin_id.clone())
            )
            .await
            .unwrap_err(),
            GatewayError::Forbidden(_)
        ));
        assert!(matches!(
            rotate_code(
                State(state.clone()),
                Extension(device("mod-dev")),
                Path(pin.pin_id.clone())
            )
            .await
            .unwrap_err(),
            GatewayError::Forbidden(_)
        ));
        assert!(matches!(
            delete_pin(
                State(state.clone()),
                Extension(device("mod-dev")),
                Path(pin.pin_id.clone())
            )
            .await
            .unwrap_err(),
            GatewayError::Forbidden(_)
        ));

        // Admin reads the code; owner deletes.
        let Json(code) = get_join_code(
            State(state.clone()),
            Extension(device("owner-dev")),
            Path(pin.pin_id.clone()),
        )
        .await
        .unwrap();
        assert_eq!(code["joinCode"], serde_json::json!(pin.join_code));
        delete_pin(
            State(state.clone()),
            Extension(device("owner-dev")),
            Path(pin.pin_id.clone()),
        )
        .await
        .unwrap();
    }
}
