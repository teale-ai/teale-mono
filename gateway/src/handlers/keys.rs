//! Programmatic API key management endpoints.
//!
//! - `POST   /v1/keys`        — mint a new live or provisioning key
//! - `GET    /v1/keys`        — list keys for the calling account
//! - `GET    /v1/keys/:id`    — get one key
//! - `PATCH  /v1/keys/:id`    — update name / credit_limit / disabled
//! - `DELETE /v1/keys/:id`    — revoke a key
//! - `GET    /v1/key`         — info about the key making the request
//! - `GET    /v1/credits`     — credit balance + lifetime usage of the calling account
//!
//! Authorization model:
//! - A device bearer linked to an account can do everything (the user's
//!   primary auth from the Mac/Android app).
//! - A provisioning API key can do everything except inference.
//! - A live API key can read its own info via `/v1/key` and read
//!   `/v1/credits`, but cannot CRUD other keys.

use axum::{
    extract::{Path, State},
    http::StatusCode,
    Extension, Json,
};
use serde::Deserialize;
use serde_json::{json, Value};

use crate::api_keys::{
    self, ApiKeyError, ApiKeyMinted, ApiKeyPublic, ApiKeyRole, CreateApiKeyParams,
    UpdateApiKeyParams,
};
use crate::auth::{AuthPrincipal, PrincipalKind};
use crate::error::GatewayError;
use crate::ledger;
use crate::state::AppState;

/// Resolve the account_user_id this principal acts on behalf of, and whether
/// it is allowed to manage keys (CRUD on `/v1/keys`).
struct Caller {
    account_user_id: String,
    can_manage: bool,
    self_key_id: Option<String>,
}

fn resolve_caller(state: &AppState, principal: &AuthPrincipal) -> Result<Caller, GatewayError> {
    let pool = state
        .db
        .as_ref()
        .ok_or_else(|| GatewayError::Other(anyhow::anyhow!("db not initialized")))?;
    match &principal.kind {
        PrincipalKind::Device { device_id } => {
            let account_user_id =
                ledger::account_user_id_for_device(pool, device_id).ok_or_else(|| {
                    GatewayError::NotFound("device is not linked to an account".into())
                })?;
            Ok(Caller {
                account_user_id,
                can_manage: true,
                self_key_id: None,
            })
        }
        PrincipalKind::ApiKey {
            key_id,
            account_user_id,
            role,
            ..
        } => Ok(Caller {
            account_user_id: account_user_id.clone(),
            can_manage: matches!(role, ApiKeyRole::Provisioning),
            self_key_id: Some(key_id.clone()),
        }),
        PrincipalKind::Static { .. } | PrincipalKind::Share { .. } => Err(GatewayError::Forbidden(
            "not authorized to manage api keys".into(),
        )),
    }
}

fn require_manage(caller: &Caller) -> Result<(), GatewayError> {
    if caller.can_manage {
        Ok(())
    } else {
        Err(GatewayError::Forbidden(
            "live api keys cannot manage other keys; use a provisioning key or device bearer"
                .into(),
        ))
    }
}

#[derive(Debug, Deserialize)]
pub struct CreateKeyReq {
    #[serde(default)]
    pub name: Option<String>,
    #[serde(default)]
    pub role: Option<ApiKeyRole>,
    #[serde(default, rename = "creditLimit")]
    pub credit_limit: Option<i64>,
}

pub async fn create(
    State(state): State<AppState>,
    Extension(principal): Extension<AuthPrincipal>,
    Json(req): Json<CreateKeyReq>,
) -> Result<(StatusCode, Json<ApiKeyMinted>), GatewayError> {
    let caller = resolve_caller(&state, &principal)?;
    require_manage(&caller)?;
    let pool = state
        .db
        .as_ref()
        .ok_or_else(|| GatewayError::Other(anyhow::anyhow!("db not initialized")))?;
    let minted = api_keys::create_api_key(
        pool,
        &caller.account_user_id,
        CreateApiKeyParams {
            name: req.name,
            role: req.role,
            credit_limit: req.credit_limit,
        },
    )
    .map_err(map_api_key_error)?;
    Ok((StatusCode::CREATED, Json(minted)))
}

#[derive(Debug, serde::Serialize)]
pub struct KeyListRes {
    keys: Vec<ApiKeyPublic>,
}

pub async fn list(
    State(state): State<AppState>,
    Extension(principal): Extension<AuthPrincipal>,
) -> Result<Json<KeyListRes>, GatewayError> {
    let caller = resolve_caller(&state, &principal)?;
    require_manage(&caller)?;
    let pool = state
        .db
        .as_ref()
        .ok_or_else(|| GatewayError::Other(anyhow::anyhow!("db not initialized")))?;
    let keys = api_keys::list_api_keys(pool, &caller.account_user_id).map_err(map_api_key_error)?;
    Ok(Json(KeyListRes { keys }))
}

pub async fn get(
    State(state): State<AppState>,
    Extension(principal): Extension<AuthPrincipal>,
    Path(key_id): Path<String>,
) -> Result<Json<ApiKeyPublic>, GatewayError> {
    let caller = resolve_caller(&state, &principal)?;
    require_manage(&caller)?;
    let pool = state
        .db
        .as_ref()
        .ok_or_else(|| GatewayError::Other(anyhow::anyhow!("db not initialized")))?;
    let key =
        api_keys::get_api_key(pool, &caller.account_user_id, &key_id).map_err(map_api_key_error)?;
    Ok(Json(key))
}

#[derive(Debug, Deserialize)]
pub struct UpdateKeyReq {
    /// Use `None` to leave unchanged; pass an explicit JSON `null` to clear name.
    #[serde(default, deserialize_with = "deserialize_opt_opt")]
    pub name: Option<Option<String>>,
    /// Use `None` to leave unchanged; pass an explicit JSON `null` to remove the limit.
    #[serde(
        default,
        rename = "creditLimit",
        deserialize_with = "deserialize_opt_opt"
    )]
    pub credit_limit: Option<Option<i64>>,
    #[serde(default)]
    pub disabled: Option<bool>,
}

// Distinguishes "field absent" from "field present and null" so PATCH can
// clear a value vs. leave it alone.
fn deserialize_opt_opt<'de, D, T>(de: D) -> Result<Option<Option<T>>, D::Error>
where
    D: serde::Deserializer<'de>,
    T: serde::Deserialize<'de>,
{
    Option::<T>::deserialize(de).map(Some)
}

pub async fn update(
    State(state): State<AppState>,
    Extension(principal): Extension<AuthPrincipal>,
    Path(key_id): Path<String>,
    Json(req): Json<UpdateKeyReq>,
) -> Result<Json<ApiKeyPublic>, GatewayError> {
    let caller = resolve_caller(&state, &principal)?;
    require_manage(&caller)?;
    let pool = state
        .db
        .as_ref()
        .ok_or_else(|| GatewayError::Other(anyhow::anyhow!("db not initialized")))?;
    let key = api_keys::update_api_key(
        pool,
        &caller.account_user_id,
        &key_id,
        UpdateApiKeyParams {
            name: req.name,
            credit_limit: req.credit_limit,
            disabled: req.disabled,
        },
    )
    .map_err(map_api_key_error)?;
    Ok(Json(key))
}

pub async fn delete(
    State(state): State<AppState>,
    Extension(principal): Extension<AuthPrincipal>,
    Path(key_id): Path<String>,
) -> Result<StatusCode, GatewayError> {
    let caller = resolve_caller(&state, &principal)?;
    require_manage(&caller)?;
    let pool = state
        .db
        .as_ref()
        .ok_or_else(|| GatewayError::Other(anyhow::anyhow!("db not initialized")))?;
    api_keys::delete_api_key(pool, &caller.account_user_id, &key_id).map_err(map_api_key_error)?;
    Ok(StatusCode::NO_CONTENT)
}

/// `GET /v1/key` — info about the key making the request. Only meaningful for
/// API-key principals; device bearers get a small descriptor instead.
pub async fn current(
    State(state): State<AppState>,
    Extension(principal): Extension<AuthPrincipal>,
) -> Result<Json<Value>, GatewayError> {
    let caller = resolve_caller(&state, &principal)?;
    if let Some(self_key_id) = caller.self_key_id.as_deref() {
        let pool = state
            .db
            .as_ref()
            .ok_or_else(|| GatewayError::Other(anyhow::anyhow!("db not initialized")))?;
        let key = api_keys::get_api_key(pool, &caller.account_user_id, self_key_id)
            .map_err(map_api_key_error)?;
        Ok(Json(json!({ "key": key })))
    } else {
        Ok(Json(json!({
            "key": null,
            "principal": "device",
            "accountUserID": caller.account_user_id,
        })))
    }
}

/// `GET /v1/credits` — credit balance + lifetime usage of the calling account.
pub async fn credits(
    State(state): State<AppState>,
    Extension(principal): Extension<AuthPrincipal>,
) -> Result<Json<ledger::CreditsSnapshot>, GatewayError> {
    let caller = resolve_caller(&state, &principal)?;
    let pool = state
        .db
        .as_ref()
        .ok_or_else(|| GatewayError::Other(anyhow::anyhow!("db not initialized")))?;
    let snapshot =
        ledger::credits_snapshot(pool, &caller.account_user_id).map_err(GatewayError::Other)?;
    Ok(Json(snapshot))
}

fn map_api_key_error(err: ApiKeyError) -> GatewayError {
    match err {
        ApiKeyError::NotFound => GatewayError::NotFound("api key not found".into()),
        ApiKeyError::InvalidName => GatewayError::BadRequest("invalid name".into()),
        ApiKeyError::InvalidCreditLimit => GatewayError::BadRequest("invalid creditLimit".into()),
        ApiKeyError::ProvisioningRequired => GatewayError::Forbidden(err.to_string()),
        ApiKeyError::Db(e) => GatewayError::Other(anyhow::anyhow!(e)),
        ApiKeyError::Other(e) => GatewayError::Other(e),
    }
}
