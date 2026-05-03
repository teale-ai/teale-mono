//! POST /v1/chat/completions — OpenAI-compatible chat completion.
//!
//! Flow:
//!   1. Parse request; resolve `model` against our catalog; check per-model floor.
//!   2. Pick a device via scheduler from the registry's eligible set.
//!   3. Open a relay session; register a PendingSession so incoming chunks
//!      flow to our handler's mpsc::Receiver.
//!   4. Send the `inferenceRequest` ClusterMessage.
//!   5. Stream incoming chunks back as SSE (`data: ...\n\n`, terminated by
//!      `data: [DONE]\n\n`). For non-stream requests, buffer and return one
//!      JSON body.
//!   6. On error or session disconnect before completion, retry once on the
//!      next-best device (excluding the failed node).

use std::convert::Infallible;
use std::time::{Duration, Instant};

use axum::{
    extract::State,
    http::{header, HeaderMap},
    response::{sse::Event, IntoResponse, Response, Sse},
    Extension, Json,
};
use futures_util::stream::Stream;
use serde_json::Value;
use tokio::sync::mpsc;
use tracing::{debug, info, warn};
use uuid::Uuid;

use teale_protocol::{openai::ChatCompletionRequest, ClusterMessage, InferenceRequestPayload};

use crate::auth::{AuthPrincipal, PrincipalKind};
use crate::catalog::{
    is_large, resolve_auto, synthesize_live_model, AutoRouteProfile, CatalogModel,
};
use crate::error::GatewayError;
use crate::ledger;
use crate::metrics;
use crate::relay_client::{PendingSession, SessionEvent};
use crate::state::AppState;

fn ttft_deadline_seconds_for_model(
    reliability: &crate::config::ReliabilityConfig,
    catalog_model: &CatalogModel,
) -> u64 {
    if is_large(catalog_model.params_b) {
        reliability.ttft_deadline_seconds
    } else {
        reliability
            .small_ttft_deadline_seconds
            .min(reliability.ttft_deadline_seconds)
    }
}

fn is_transient_warmup_error(message: &str) -> bool {
    let lower = message.to_ascii_lowercase();
    lower.contains("loading model")
        || (lower.contains("unavailable_error") && lower.contains("503"))
}

fn single_supplier_large_cold_start_grace(state: &AppState, catalog_model: &CatalogModel) -> bool {
    if !is_large(catalog_model.params_b) {
        return false;
    }
    let loaded = state.registry.loaded_count(&catalog_model.id);
    let candidate_count = if loaded > 0 {
        loaded as usize
    } else {
        state.registry.eligible_devices(&catalog_model.id).len()
    };
    candidate_count <= 1
}

fn pre_first_token_deadline(state: &AppState, catalog_model: &CatalogModel) -> Duration {
    if single_supplier_large_cold_start_grace(state, catalog_model) {
        Duration::from_secs(state.config.reliability.request_timeout_seconds)
    } else {
        Duration::from_secs(ttft_deadline_seconds_for_model(
            &state.config.reliability,
            catalog_model,
        ))
    }
}

fn resolve_requested_model(state: &AppState, requested_model: &str) -> Option<CatalogModel> {
    if let Some(model) = state
        .catalog
        .iter()
        .find(|m| m.matches(requested_model))
        .cloned()
    {
        return Some(model);
    }

    let live_devices: Vec<_> = state
        .registry
        .snapshot_devices()
        .into_iter()
        .filter(|device| {
            !device.is_quarantined()
                && device.capabilities.is_available
                && !device.heartbeat_is_stale(state.config.reliability.heartbeat_stale_seconds)
                && crate::registry::model_matches_any(
                    requested_model,
                    &device.capabilities.loaded_models,
                )
        })
        .collect();
    if live_devices.is_empty() {
        return None;
    }
    let effective_context = live_devices
        .iter()
        .filter_map(|device| device.capabilities.effective_context)
        .max();
    Some(synthesize_live_model(requested_model, effective_context))
}

pub async fn chat_completions(
    State(state): State<AppState>,
    headers: HeaderMap,
    Extension(principal): Extension<AuthPrincipal>,
    Json(mut req): Json<Value>,
) -> Result<Response, GatewayError> {
    // Try the centralized 3rd-party provider path first. Returns None when
    // the request isn't centralized-routable (no provider serves the model,
    // or user preferences point at the local fleet); in that case we fall
    // through to the existing relay/scheduler cascade with `req` left
    // untouched except for the consumed `provider` field and any
    // `:nitro`/`:floor` slug suffix being stripped.
    if let Some(outcome) = crate::handlers::centralized::try_centralized_dispatch(
        &state, &headers, &principal, &mut req,
    )
    .await
    {
        return outcome;
    }

    let mut excluded: Vec<String> = Vec::new();
    loop {
        let prepared =
            prepare_chat_request_excluding(&state, &headers, &principal, req.clone(), &excluded)?;
        let was_virtual = prepared.was_virtual_resolution;
        let attempted_model = prepared.catalog_model.id.clone();

        let result: Result<Response, GatewayError> = if prepared.streaming {
            run_streaming(
                state.clone(),
                prepared.catalog_model,
                prepared.req_body,
                prepared.consumer,
                prepared.required_ctx,
                prepared.preferred_node_ids,
            )
            .await
            .map(IntoResponse::into_response)
        } else {
            run_buffered(
                state.clone(),
                prepared.catalog_model,
                prepared.req_body,
                prepared.consumer,
                prepared.required_ctx,
                prepared.preferred_node_ids,
            )
            .await
            .map(IntoResponse::into_response)
        };

        match result {
            Ok(response) => return Ok(response),
            Err(err) if should_cascade(&err, was_virtual, &excluded) => {
                warn!(
                    failed_model = %attempted_model,
                    attempt = excluded.len() + 1,
                    "teale/auto cascade: re-resolving with failed model excluded"
                );
                excluded.push(attempted_model);
                continue;
            }
            Err(err) => return Err(err),
        }
    }
}

/// Whether a dispatch failure should trigger a fresh `resolve_auto` pass with
/// the just-failed model excluded. Only fires for virtual-model requests
/// (`teale/auto` etc.) — concrete-model requests bubble the original error to
/// the caller so they can decide what to do.
pub(crate) fn should_cascade(
    err: &GatewayError,
    was_virtual: bool,
    excluded: &[String],
) -> bool {
    if !was_virtual || excluded.len() >= MAX_AUTO_CASCADE_RETRIES {
        return false;
    }
    matches!(
        err,
        GatewayError::NoEligibleDevice(_) | GatewayError::AllUpstreamsFailed(_)
    )
}

pub(crate) struct PreparedChatRequest {
    pub catalog_model: CatalogModel,
    pub req_body: Value,
    pub consumer: Option<ledger::ConsumerPrincipal>,
    pub required_ctx: u32,
    pub preferred_node_ids: Vec<String>,
    pub streaming: bool,
    /// True when the requested model was a virtual one (e.g. `teale/auto`) and
    /// the gateway resolved it to a concrete model. The caller can use this to
    /// decide whether a dispatch failure is recoverable by re-resolving with
    /// the failed model excluded.
    pub was_virtual_resolution: bool,
}

/// Maximum number of times a virtual `teale/auto` request may cascade to a
/// different concrete model after dispatch failures. Bounded so a fully
/// degraded fleet still surfaces an error to the caller within one wall-clock
/// "request" instead of marching through every model in the catalog.
pub(crate) const MAX_AUTO_CASCADE_RETRIES: usize = 3;

#[cfg(test)]
pub(crate) fn prepare_chat_request(
    state: &AppState,
    headers: &HeaderMap,
    principal: &AuthPrincipal,
    req: Value,
) -> Result<PreparedChatRequest, GatewayError> {
    prepare_chat_request_excluding(state, headers, principal, req, &[])
}

pub(crate) fn prepare_chat_request_excluding(
    state: &AppState,
    headers: &HeaderMap,
    principal: &AuthPrincipal,
    mut req: Value,
    excluded_models: &[String],
) -> Result<PreparedChatRequest, GatewayError> {
    // Parse the inbound request loosely so we can copy pass-through fields.
    let mut parsed: ChatCompletionRequest = serde_json::from_value(req.clone())
        .map_err(|e| GatewayError::BadRequest(format!("invalid request body: {}", e)))?;
    let Some(requested_model) = parsed.model.clone() else {
        return Err(GatewayError::BadRequest("`model` is required".into()));
    };

    // Catalog lookup.
    let mut catalog_model = resolve_requested_model(state, &requested_model)
        .ok_or_else(|| GatewayError::ModelNotFound(requested_model.clone()))?;
    let was_virtual_resolution = catalog_model.is_virtual;

    let floor = &state.config.scheduler.per_model_floor;

    // Virtual model resolution (e.g. `teale/auto`). Estimate required context
    // from the inbound messages + max_tokens, then ask the catalog for the
    // smallest concrete model that fits and has healthy supply. Resolution
    // is strict per project policy — no silent downgrade; on miss we 503.
    if catalog_model.is_virtual {
        let required_ctx = estimate_required_context(&parsed);
        let auto_profile = infer_auto_route_profile(headers, &parsed);
        let registry = state.registry.clone();
        let resolved = resolve_auto(
            &state.catalog,
            required_ctx,
            auto_profile,
            |id, need_ctx| {
                // Match the post-resolution floor check (`loaded_count` below):
                // count only devices that have the model loaded right now, not
                // ones whose only claim is `Swappable`. Otherwise resolve_auto
                // can pick a model with theoretical-only supply (weights on
                // disk, RAM available) and the floor check then 503s the
                // request even though a different model with actual loaded
                // supply would have served it.
                registry
                    .eligible_devices(id)
                    .into_iter()
                    .filter(|device| {
                        crate::registry::model_matches_any(id, &device.capabilities.loaded_models)
                    })
                    .filter(|device| {
                        device
                            .capabilities
                            .effective_context
                            .map(|have| have >= need_ctx)
                            .unwrap_or(true)
                    })
                    .count() as u32
            },
            floor.small,
            floor.large,
            excluded_models,
        )
        .cloned()
        .ok_or_else(|| {
            metrics::REQUESTS_TOTAL
                .with_label_values(&[&catalog_model.id, "no_supply"])
                .inc();
            GatewayError::NoEligibleDevice(format!(
                "{} (required_ctx={})",
                catalog_model.id, required_ctx
            ))
        })?;
        info!(
            virtual_id = %catalog_model.id,
            resolved_id = %resolved.id,
            required_ctx,
            auto_profile = auto_profile.as_str(),
            "teale/auto resolved"
        );
        metrics::REQUESTS_TOTAL
            .with_label_values(&[&catalog_model.id, "resolved"])
            .inc();
        catalog_model = resolved;
    }

    // Per-model fleet floor: if we don't have enough healthy devices, 503.
    let required = if is_large(catalog_model.params_b) {
        floor.large
    } else {
        floor.small
    };
    if state.registry.loaded_count(&catalog_model.id) < required {
        metrics::REQUESTS_TOTAL
            .with_label_values(&[&catalog_model.id, "no_supply"])
            .inc();
        return Err(GatewayError::NoEligibleDevice(catalog_model.id));
    }

    let streaming = parsed.stream.unwrap_or(false);
    let consumer = consumer_principal(principal);

    // Pre-flight budget clamp — ledger must never go negative. Instead of
    // rejecting when the paying device (or share-key) can't cover a full
    // catalog-max reservation, we clamp `max_tokens` down to what the
    // effective budget can afford and forward that clamp to the upstream
    // request. Only reject when the budget can't cover the prompt itself
    // plus at least one completion token.
    if let (Some(consumer_p), Some(pool)) = (consumer.as_ref(), state.db.as_ref()) {
        // Compute the spending ceiling for this principal:
        //   Device → wallet balance.
        //   Share-key (funded=1) → pre-funded pool remainder.
        //   Share-key (funded=0, legacy) → min(pool remainder, issuer wallet).
        //     (Old semantics where the pool was just a cap on issuer spend.)
        let effective_budget = match consumer_p {
            ledger::ConsumerPrincipal::Share { key_id, .. } => {
                let pool_remaining = share_key_remaining(pool, key_id).unwrap_or(0);
                if share_key_is_funded(pool, key_id) {
                    pool_remaining
                } else {
                    let issuer_balance = ledger::get_balance(
                        pool,
                        consumer_p
                            .paying_device_id()
                            .expect("share principal has issuer device"),
                    )
                    .balance_credits;
                    pool_remaining.min(issuer_balance)
                }
            }
            ledger::ConsumerPrincipal::Account { account_user_id } => {
                ledger::account_balance_credits(pool, account_user_id)
            }
            ledger::ConsumerPrincipal::Device(_) => {
                ledger::get_balance(
                    pool,
                    consumer_p
                        .paying_device_id()
                        .expect("device principal has device id"),
                )
                .balance_credits
            }
        };

        match compute_clamp(&catalog_model, &parsed, effective_budget) {
            Ok(decision) => {
                // Rewrite `max_tokens` on the outbound JSON so the supplier
                // honors the clamp.
                if let Some(obj) = req.as_object_mut() {
                    obj.insert(
                        "max_tokens".into(),
                        Value::Number(serde_json::Number::from(decision.effective_max)),
                    );
                }
                parsed.max_tokens = Some(decision.effective_max as u32);
                if decision.clamped {
                    debug!(
                        model = %catalog_model.id,
                        client_max = decision.client_max,
                        effective_max = decision.effective_max,
                        effective_budget = effective_budget,
                        "clamped max_tokens to fit budget"
                    );
                }
            }
            Err(required) => {
                return Err(GatewayError::InsufficientCredits {
                    balance: effective_budget,
                    required,
                });
            }
        }
    }

    // Compute context budget once; scheduler uses it to filter out nodes
    // whose effective_context can't cover the request.
    let required_ctx = estimate_required_context(&parsed);
    let preferred_node_ids = preferred_linked_node_ids(state, headers, principal);

    Ok(PreparedChatRequest {
        catalog_model,
        req_body: req,
        consumer,
        required_ctx,
        preferred_node_ids,
        streaming,
        was_virtual_resolution,
    })
}

/// Outcome of the pre-flight budget clamp. Public so unit tests can pin the
/// arithmetic down.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct ClampDecision {
    /// The value we'll force onto the outbound `max_tokens`. Always ≥1.
    pub effective_max: u64,
    /// What the client asked for (or implied via the catalog's hard ceiling).
    pub client_max: u64,
    /// True iff `effective_max < client_max` — i.e. budget bit us.
    pub clamped: bool,
}

/// Compute the clamp. Returns `Err(min_required_credits)` when the budget
/// can't cover the prompt plus at least one completion token; otherwise an
/// accepted decision.
pub(crate) fn compute_clamp(
    model: &CatalogModel,
    req: &ChatCompletionRequest,
    effective_budget: i64,
) -> Result<ClampDecision, i64> {
    let prompt_tokens_est = prompt_tokens_estimate(req);
    let prompt_cost = ledger::cost_credits(
        prompt_tokens_est,
        0,
        model.prompt_price_usd(),
        model.completion_price_usd(),
    );
    let one_out_cost =
        ledger::cost_credits(0, 1, model.prompt_price_usd(), model.completion_price_usd());
    let min_required = prompt_cost.saturating_add(one_out_cost);
    if effective_budget < min_required {
        return Err(min_required);
    }

    let catalog_max = model.max_output_tokens as u64;
    let client_max = req
        .max_tokens
        .map(|v| v as u64)
        .unwrap_or(catalog_max)
        .min(catalog_max)
        .max(1);
    let affordable_out = affordable_out_tokens(model, effective_budget - prompt_cost);
    let effective_max = client_max.min(affordable_out).max(1);
    Ok(ClampDecision {
        effective_max,
        client_max,
        clamped: effective_max < client_max,
    })
}

/// Rough prompt-tokens estimate: `bytes/4 + 16` (fixed padding for role /
/// control tokens upstream will add). Conservative over-estimate for English —
/// keeps our reservation on the safe side of actual tokenizer output.
fn prompt_tokens_estimate(req: &ChatCompletionRequest) -> u64 {
    let prompt_bytes: usize = req
        .messages
        .iter()
        .map(|m| match &m.content {
            Value::String(s) => s.len(),
            other => other.to_string().len(),
        })
        .sum();
    (prompt_bytes as u64).div_ceil(4) + 16
}

/// Given a remaining credit budget after the prompt has been accounted for,
/// return the largest completion-token count that still fits. Floored at 1
/// so the caller can always allow at least one token of response; the caller
/// is responsible for catching the "budget can't cover prompt + 1 token" case
/// up front.
fn affordable_out_tokens(model: &CatalogModel, remaining_after_prompt: i64) -> u64 {
    if remaining_after_prompt <= 0 {
        return 1;
    }
    let completion_price_credits = model.completion_price_usd() * 1_000_000.0;
    if completion_price_credits <= 0.0 {
        // Free completion: the catalog ceiling is the only bound — let the
        // rest of the clamp handle that via min(catalog_max, ...).
        return u64::MAX;
    }
    let affordable = (remaining_after_prompt as f64 / completion_price_credits).floor();
    (affordable as i64).max(1) as u64
}

/// Rough estimate of the context window a request will consume. Used only
/// for `teale/auto` resolution and scheduler `min_context` filter — NOT for
/// hard request validation (the gateway still trusts nodes to honor their
/// advertised n_ctx).
///
/// char_count/4 is a widely-used "fair-enough" heuristic; it over-estimates
/// for CJK and under-estimates for code. We don't pad with a safety margin
/// because that pushes otherwise-legal requests (e.g. exactly 16k prompt
/// + completion on a 16k-catalog model) past the ceiling and forces a 503.
pub(crate) fn estimate_required_context(req: &ChatCompletionRequest) -> u32 {
    let prompt_chars: usize = req
        .messages
        .iter()
        .map(|m| match &m.content {
            Value::String(s) => s.len(),
            other => other.to_string().len(),
        })
        .sum();
    let prompt_est = (prompt_chars / 4) as u32;
    let completion_budget = req.max_tokens.unwrap_or(4096);
    prompt_est.saturating_add(completion_budget)
}

fn infer_auto_route_profile(headers: &HeaderMap, req: &ChatCompletionRequest) -> AutoRouteProfile {
    let user_agent = headers
        .get(header::USER_AGENT)
        .and_then(|v| v.to_str().ok())
        .unwrap_or_default()
        .to_ascii_lowercase();
    let has_agent_user_agent = [
        "openclaw",
        "hermes",
        "codex",
        "claude-code",
        "cline",
        "roo",
        "aider",
    ]
    .iter()
    .any(|needle| user_agent.contains(needle));

    let prompt_chars: usize = req
        .messages
        .iter()
        .map(|m| match &m.content {
            Value::String(s) => s.len(),
            other => other.to_string().len(),
        })
        .sum();

    let has_agent_bootstrap_marker = req.messages.iter().any(|m| {
        let content = match &m.content {
            Value::String(s) => s.as_str(),
            _ => return false,
        };
        [
            "AGENTS.md",
            "TOOLS.md",
            "SOUL.md",
            "HEARTBEAT.md",
            "workspace",
            "repo-level reasoning",
        ]
        .iter()
        .any(|needle| content.contains(needle))
    });

    if has_agent_bootstrap_marker
        || req.tools.is_some()
        || req.tool_choice.is_some()
        || (prompt_chars >= 12_000 && req.max_tokens.unwrap_or(4096) >= 4096)
        || (has_agent_user_agent && prompt_chars >= 4_000)
    {
        AutoRouteProfile::AgentHarness
    } else {
        AutoRouteProfile::Generic
    }
}

fn preferred_linked_node_ids(
    state: &AppState,
    headers: &HeaderMap,
    principal: &AuthPrincipal,
) -> Vec<String> {
    let enabled = headers
        .get("x-teale-prefer-linked-device")
        .and_then(|v| v.to_str().ok())
        .map(|v| matches!(v.trim().to_ascii_lowercase().as_str(), "1" | "true" | "yes"))
        .unwrap_or(false);
    if !enabled {
        return Vec::new();
    }
    let PrincipalKind::Account {
        account_user_id, ..
    } = &principal.kind
    else {
        return Vec::new();
    };
    let Some(pool) = state.db.as_ref() else {
        return Vec::new();
    };
    ledger::account_device_ids(pool, account_user_id).unwrap_or_default()
}

/// Remaining credits on a share-key (budget - consumed), or None if the key
/// can't be looked up — in that case we fall through and let the auth layer
/// handle rejection.
fn share_key_remaining(pool: &crate::db::DbPool, key_id: &str) -> Option<i64> {
    let conn = pool.lock();
    conn.query_row(
        "SELECT budget_credits - consumed_credits FROM share_keys WHERE key_id = ?",
        [key_id],
        |r| r.get::<_, i64>(0),
    )
    .ok()
}

/// Whether a share-key has been migrated to the pre-funded-pool model.
/// Returns true for `funded=1`; false for `funded=0` or lookup failure (the
/// safer default — legacy semantics fall back to debiting the issuer wallet).
fn share_key_is_funded(pool: &crate::db::DbPool, key_id: &str) -> bool {
    let conn = pool.lock();
    conn.query_row(
        "SELECT funded FROM share_keys WHERE key_id = ?",
        [key_id],
        |r| r.get::<_, i64>(0),
    )
    .map(|f| f == 1)
    .unwrap_or(false)
}

/// Build the ledger-facing consumer from an authenticated principal.
/// Static tokens don't settle (they pre-date the credit system), so we
/// return `None` for them.
pub(crate) fn consumer_principal(principal: &AuthPrincipal) -> Option<ledger::ConsumerPrincipal> {
    if let Some((issuer, key_id)) = principal.share_key() {
        return Some(ledger::ConsumerPrincipal::Share {
            issuer_device_id: issuer.to_string(),
            key_id: key_id.to_string(),
        });
    }
    match &principal.kind {
        PrincipalKind::Device { device_id } => {
            Some(ledger::ConsumerPrincipal::Device(device_id.to_string()))
        }
        PrincipalKind::Account {
            account_user_id, ..
        } => Some(ledger::ConsumerPrincipal::Account {
            account_user_id: account_user_id.to_string(),
        }),
        PrincipalKind::Share { .. } | PrincipalKind::Static { .. } => None,
    }
}

pub(crate) async fn pick_and_dispatch(
    state: &AppState,
    catalog_model: &CatalogModel,
    req_body: &Value,
    exclude: &[String],
    min_context: Option<u32>,
    preferred_node_ids: &[String],
) -> Result<(mpsc::Receiver<SessionEvent>, String, String), GatewayError> {
    // Rewrite the `model` field in the outbound payload to the canonical
    // OpenRouter id we advertise, in case the client used an alias.
    let mut outbound: ChatCompletionRequest = serde_json::from_value(req_body.clone())
        .map_err(|e| GatewayError::BadRequest(format!("{}", e)))?;
    outbound.model = Some(catalog_model.id.clone());
    // OpenRouter explicitly requires the `usage` block on every response,
    // including streamed ones. Force `stream_options.include_usage=true` on
    // the outbound request so upstream emits a final usage chunk we can
    // forward — overriding any value the caller sent (we don't want clients
    // opting out of the thing OR needs).
    outbound.stream_options = Some(serde_json::json!({ "include_usage": true }));

    let mut excluded: Vec<String> = exclude.to_vec();
    let mut last_dispatch_error: Option<String> = None;
    let cold_start_grace = single_supplier_large_cold_start_grace(state, catalog_model);
    let max_dispatch_grace_retries =
        (state.config.reliability.request_timeout_seconds / 5).max(1) as u32;
    let mut dispatch_grace_failures = 0u32;
    // Relay open should succeed almost immediately for a connected peer.
    // Keep this much tighter than the TTFT budget so a dead/stuck node
    // doesn't consume the entire request before we even hand off inference.
    let ttft_deadline_seconds =
        ttft_deadline_seconds_for_model(&state.config.reliability, catalog_model);
    let open_timeout = Duration::from_secs(ttft_deadline_seconds.min(4));

    loop {
        let candidates = state.registry.eligible_devices(&catalog_model.id);
        let preferred_candidates: Vec<_> = if preferred_node_ids.is_empty() {
            Vec::new()
        } else {
            candidates
                .iter()
                .filter(|candidate| {
                    preferred_node_ids
                        .iter()
                        .any(|node_id| node_id == &candidate.node_id)
                })
                .cloned()
                .collect()
        };
        let target_node = match state
            .scheduler
            .pick(
                &preferred_candidates,
                &catalog_model.id,
                &excluded,
                &state.registry,
                min_context,
            )
            .or_else(|| {
                state.scheduler.pick(
                    &candidates,
                    &catalog_model.id,
                    &excluded,
                    &state.registry,
                    min_context,
                )
            }) {
            Some(selected) => selected.node_id.clone(),
            None => {
                return Err(match last_dispatch_error {
                    Some(message) => GatewayError::AllUpstreamsFailed(message),
                    None => GatewayError::NoEligibleDevice(catalog_model.id.clone()),
                });
            }
        };

        // Bump live in-flight counter so the next pick_and_dispatch sees this
        // node as busier. Use a scope guard so the counter rolls back if
        // any of the dispatch steps below fail before we successfully hand
        // off a Receiver to the caller (otherwise an open/send failure would
        // leave the counter permanently elevated).
        state.registry.inc_in_flight(&target_node);
        let inc_guard = InFlightGuard::new(state.registry.clone(), target_node.clone());

        // Open a relay session.
        let session_id = match state.relay.open_session(&target_node, open_timeout).await {
            Ok(session_id) => session_id,
            Err(e) => {
                let message = format!("relay open: {}", e);
                warn!(
                    device = %target_node,
                    "dispatch failed before session hand-off: {}",
                    message
                );
                if cold_start_grace && dispatch_grace_failures < max_dispatch_grace_retries {
                    dispatch_grace_failures += 1;
                    last_dispatch_error = Some(message);
                    info!(
                        device = %target_node,
                        attempt = dispatch_grace_failures,
                        "retrying same device after large-model cold-start dispatch failure"
                    );
                    tokio::time::sleep(Duration::from_secs(2)).await;
                    metrics::RETRIES_TOTAL
                        .with_label_values(&["single_supplier_dispatch_grace_retry"])
                        .inc();
                    continue;
                }
                state
                    .registry
                    .quarantine(&target_node, state.config.reliability.quarantine_seconds);
                excluded.push(target_node);
                last_dispatch_error = Some(message);
                continue;
            }
        };

        // Register a PendingSession and start pumping.
        let (tx, rx) = mpsc::channel::<SessionEvent>(128);
        let request_id = Uuid::new_v4().to_string();
        state.relay.register_session(PendingSession {
            request_id: request_id.clone(),
            device_node_id: target_node.clone(),
            session_id: session_id.clone(),
            chunks_tx: tx,
        });

        // Send the inferenceRequest.
        let ir = ClusterMessage::InferenceRequest(Box::new(InferenceRequestPayload {
            request_id: request_id.clone(),
            request: outbound.clone(),
            streaming: true,
        }));
        if let Err(e) = state.relay.send_cluster(&target_node, &session_id, &ir) {
            let message = format!("relay send: {}", e);
            warn!(
                device = %target_node,
                "dispatch failed before session hand-off: {}",
                message
            );
            state.relay.close_session(&target_node, &session_id);
            if cold_start_grace && dispatch_grace_failures < max_dispatch_grace_retries {
                dispatch_grace_failures += 1;
                last_dispatch_error = Some(message);
                info!(
                    device = %target_node,
                    attempt = dispatch_grace_failures,
                    "retrying same device after large-model cold-start dispatch failure"
                );
                tokio::time::sleep(Duration::from_secs(2)).await;
                metrics::RETRIES_TOTAL
                    .with_label_values(&["single_supplier_dispatch_grace_retry"])
                    .inc();
                continue;
            }
            state
                .registry
                .quarantine(&target_node, state.config.reliability.quarantine_seconds);
            excluded.push(target_node);
            last_dispatch_error = Some(message);
            continue;
        }

        // Successful hand-off; caller is responsible for dec_in_flight when
        // the session closes. Defuse the guard so we don't decrement here.
        inc_guard.defuse();
        return Ok((rx, target_node, session_id));
    }
}

/// Decrements the in-flight counter on drop. Defuse() opts out if the
/// caller will handle the decrement itself.
struct InFlightGuard {
    registry: Option<std::sync::Arc<crate::registry::Registry>>,
    node_id: String,
}

impl InFlightGuard {
    fn new(registry: std::sync::Arc<crate::registry::Registry>, node_id: String) -> Self {
        Self {
            registry: Some(registry),
            node_id,
        }
    }
    fn defuse(mut self) {
        self.registry = None;
    }
}

impl Drop for InFlightGuard {
    fn drop(&mut self) {
        if let Some(r) = self.registry.take() {
            r.dec_in_flight(&self.node_id);
        }
    }
}

async fn run_streaming(
    state: AppState,
    catalog_model: CatalogModel,
    req_body: Value,
    consumer: Option<ledger::ConsumerPrincipal>,
    required_ctx: u32,
    preferred_node_ids: Vec<String>,
) -> Result<Sse<impl Stream<Item = Result<Event, Infallible>>>, GatewayError> {
    let started = Instant::now();
    let model_id = catalog_model.id.clone();

    let max_retries = state.config.reliability.max_retries;
    let request_timeout = Duration::from_secs(state.config.reliability.request_timeout_seconds);
    let stream = async_stream::stream! {
        let mut excluded: Vec<String> = Vec::new();
        let mut first_token_at: Option<Instant> = None;
        let mut tokens_out: u64 = 0;
        // If upstream includes a `usage` object in any chunk (stream_options
        // .include_usage=true was set on the outbound request), keep the
        // most recent one so we can emit it in our own final event.
        let mut captured_usage: Option<Value> = None;
        let mut request_id: Option<String> = None;
        let mut final_status = "error";
        let mut tried = 0u32;
        let mut served_by: Option<String> = None;
        let mut reported_tokens: Option<u32> = None;

        loop {
            tried += 1;
            let cold_start_grace = single_supplier_large_cold_start_grace(&state, &catalog_model);
            let ttft_deadline = pre_first_token_deadline(&state, &catalog_model);
            let dispatch = pick_and_dispatch(
                &state,
                &catalog_model,
                &req_body,
                &excluded,
                Some(required_ctx),
                &preferred_node_ids,
            )
            .await;

            let (mut rx, target_node, session_id) = match dispatch {
                Ok(v) => v,
                Err(e) => {
                    let status = error_to_status_label(&e);
                    metrics::REQUESTS_TOTAL.with_label_values(&[&model_id, status]).inc();
                    yield Ok(error_event(&e));
                    yield Ok(done_event());
                    return;
                }
            };

            info!(
                model = %model_id,
                device = %target_node,
                attempt = tried,
                "streaming inference dispatched"
            );

            let mut got_first_token = false;
            let mut retriable_failure = false;
            let mut completed = false;

            loop {
                let deadline = if got_first_token {
                    request_timeout
                } else {
                    ttft_deadline
                };
                let next = tokio::time::timeout(deadline, rx.recv()).await;
                match next {
                    Ok(Some(SessionEvent::Chunk(mut chunk))) => {
                        if !got_first_token {
                            got_first_token = true;
                            first_token_at = Some(Instant::now());
                            metrics::TTFT_SECONDS
                                .with_label_values(&[&model_id])
                                .observe(started.elapsed().as_secs_f64());
                        }
                        // Normalize the chunk so downstream clients see:
                        //  - canonical OpenRouter id in `model` (upstream
                        //    llama-server sometimes leaks the local GGUF
                        //    filename here),
                        //  - a stable chunk `id` across the whole stream
                        //    (capture the first id upstream assigns and
                        //    reuse it if we need to synthesize a trailing
                        //    usage event).
                        if let Some(obj) = chunk.as_object_mut() {
                            obj.insert("model".into(), Value::String(model_id.clone()));
                            if request_id.is_none() {
                                if let Some(id) = obj.get("id").and_then(|v| v.as_str()) {
                                    request_id = Some(id.to_string());
                                }
                            }
                            if let Some(u) = obj.get("usage").cloned() {
                                if !u.is_null() {
                                    captured_usage = Some(u);
                                }
                            }
                        }
                        tokens_out += 1;
                        let data = serde_json::to_string(&chunk).unwrap_or_default();
                        yield Ok(Event::default().data(data));
                    }
                    Ok(Some(SessionEvent::Complete { tokens_out: t })) => {
                        completed = true;
                        reported_tokens = t;
                        if let Some(t) = t {
                            metrics::TOKENS_OUT_TOTAL
                                .with_label_values(&[&model_id])
                                .inc_by(t as f64);
                        } else {
                            metrics::TOKENS_OUT_TOTAL
                                .with_label_values(&[&model_id])
                                .inc_by(tokens_out as f64);
                        }
                        final_status = "ok";
                        break;
                    }
                    Ok(Some(SessionEvent::Error { message, code })) => {
                        warn!(device=%target_node, code=?code, "upstream error: {}", message);
                        if !got_first_token && tried <= max_retries {
                            retriable_failure = true;
                            metrics::RETRIES_TOTAL
                                .with_label_values(&["upstream_error"])
                                .inc();
                        } else {
                            let err = GatewayError::Upstream(message);
                            yield Ok(error_event(&err));
                            final_status = "error";
                            break;
                        }
                        break;
                    }
                    Ok(Some(SessionEvent::Disconnect(reason))) => {
                        warn!(device=%target_node, "upstream disconnect: {}", reason);
                        if !got_first_token && tried <= max_retries {
                            retriable_failure = true;
                            metrics::RETRIES_TOTAL
                                .with_label_values(&["disconnect"])
                                .inc();
                        } else {
                            let err = GatewayError::Upstream(reason);
                            yield Ok(error_event(&err));
                            final_status = "error";
                            break;
                        }
                        break;
                    }
                    Ok(None) => {
                        // Channel closed without completion — treat like disconnect.
                        if !got_first_token && tried <= max_retries {
                            retriable_failure = true;
                            metrics::RETRIES_TOTAL
                                .with_label_values(&["channel_closed"])
                                .inc();
                        } else {
                            let err = GatewayError::Upstream("channel closed before completion".into());
                            yield Ok(error_event(&err));
                            final_status = "error";
                        }
                        break;
                    }
                    Err(_) => {
                        let reason = if got_first_token { "mid_stream" } else { "ttft" };
                        warn!(device=%target_node, "timeout ({})", reason);
                        if !got_first_token && tried <= max_retries {
                            retriable_failure = true;
                            metrics::RETRIES_TOTAL
                                .with_label_values(&["timeout"])
                                .inc();
                        } else {
                            yield Ok(error_event(&GatewayError::UpstreamTimeout));
                            final_status = "timeout";
                        }
                        break;
                    }
                }
            }

            state.relay.close_session(&target_node, &session_id);
            state.registry.dec_in_flight(&target_node);

            if !completed && !got_first_token && !cold_start_grace {
                state
                    .registry
                    .quarantine(&target_node, state.config.reliability.quarantine_seconds);
            }

            if completed {
                served_by = Some(target_node);
                break;
            }
            if !retriable_failure {
                break;
            }

            if cold_start_grace {
                info!(
                    device = %target_node,
                    "retrying same device after large-model cold-start grace"
                );
                tokio::time::sleep(Duration::from_secs(2)).await;
                metrics::RETRIES_TOTAL
                    .with_label_values(&["single_supplier_cold_start_retry"])
                    .inc();
                continue;
            }

            info!(
                device = %target_node,
                "retrying on next-best device after non-streamed failure"
            );
            state.registry.quarantine(&target_node, state.config.reliability.quarantine_seconds);
            excluded.push(target_node);
        }

        // OpenRouter requires `usage` in every response — including streams.
        // Emit a final chunk carrying the usage block before [DONE]. If
        // upstream already reported usage in one of the chunks (via
        // stream_options.include_usage=true) use that; otherwise synthesize
        // a chunk with our locally-observed completion_tokens.
        if final_status == "ok" {
            let usage = captured_usage.clone().unwrap_or_else(|| serde_json::json!({
                "prompt_tokens": 0,
                "completion_tokens": tokens_out,
                "total_tokens": tokens_out,
            }));
            let created = std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .map(|d| d.as_secs())
                .unwrap_or(0);
            let id = request_id.clone().unwrap_or_else(|| format!("chatcmpl-{}", Uuid::new_v4()));
            let final_chunk = serde_json::json!({
                "id": id,
                "object": "chat.completion.chunk",
                "created": created,
                "model": model_id,
                "choices": [],
                "usage": usage,
            });
            yield Ok(Event::default().data(serde_json::to_string(&final_chunk).unwrap_or_default()));
        }

        yield Ok(done_event());

        // Settle Teale Credit ledger on success.
        if final_status == "ok" {
            if let (Some(provider), Some(consumer_p), Some(pool)) = (
                served_by.as_ref(),
                consumer.as_ref(),
                state.db.as_ref(),
            ) {
                let final_tokens_out = reported_tokens.map(|t| t as u64).unwrap_or(tokens_out).max(1);
                let prompt_tokens = captured_usage
                    .as_ref()
                    .and_then(|u| u.get("prompt_tokens").and_then(|v| v.as_u64()))
                    .unwrap_or(0);
                let cost = ledger::cost_credits(
                    prompt_tokens,
                    final_tokens_out,
                    catalog_model.prompt_price_usd(),
                    catalog_model.completion_price_usd(),
                );
                let online: Vec<String> = state.registry.snapshot_devices()
                    .into_iter()
                    .map(|d| d.node_id)
                    .collect();
                let request_id = Uuid::new_v4().to_string();
                match ledger::settle_request(pool, consumer_p, Some(provider.as_str()), &online, cost, &request_id, &model_id) {
                    Ok(()) => info!(
                        consumer=%consumer_p.ledger_actor_id(),
                        provider=%provider,
                        tokens_in=%prompt_tokens,
                        tokens_out=%final_tokens_out,
                        cost=%cost,
                        "settled chat (Teale Credits)"
                    ),
                    Err(e) => warn!("settle_request failed: {}", e),
                }
            }
        }

        metrics::REQUESTS_TOTAL
            .with_label_values(&[&model_id, final_status])
            .inc();
        metrics::TOTAL_LATENCY_SECONDS
            .with_label_values(&[&model_id, final_status])
            .observe(started.elapsed().as_secs_f64());

        if let Some(ft) = first_token_at {
            let ttft_ms = ft.duration_since(started).as_millis();
            let total_ms = started.elapsed().as_millis();
            debug!(
                "request complete: model={} ttft_ms={} total_ms={} tokens_out={}",
                model_id, ttft_ms, total_ms, tokens_out
            );
            // Record a rolling sample for /v1/models percentile reporting.
            // Only record successful streams so bad attempts don't poison the
            // advertised serving speed. Use gateway-observed output chunks so a
            // bad supplier usage report cannot inflate catalog TPS.
            if final_status == "ok" {
                state.model_metrics.record(
                    &model_id,
                    ttft_ms as u32,
                    Some(tokens_out.max(1)),
                    total_ms as u64,
                );
            }
        }
    };

    Ok(Sse::new(stream)
        .keep_alive(axum::response::sse::KeepAlive::new().interval(Duration::from_secs(15))))
}

async fn run_buffered(
    state: AppState,
    catalog_model: CatalogModel,
    req_body: Value,
    consumer: Option<ledger::ConsumerPrincipal>,
    required_ctx: u32,
    preferred_node_ids: Vec<String>,
) -> Result<Json<Value>, GatewayError> {
    let started = Instant::now();
    let model_id = catalog_model.id.clone();

    let max_retries = state.config.reliability.max_retries;
    let request_timeout = Duration::from_secs(state.config.reliability.request_timeout_seconds);
    let mut excluded: Vec<String> = Vec::new();
    let mut tried = 0u32;
    let mut accumulated_text = String::new();
    let mut last_chunk_obj: Option<serde_json::Map<String, Value>> = None;
    let mut captured_usage: Option<Value> = None;
    let mut tokens_out: u64 = 0;
    let mut first_token_at: Option<Instant> = None;

    loop {
        tried += 1;
        let cold_start_grace = single_supplier_large_cold_start_grace(&state, &catalog_model);
        let ttft_deadline = pre_first_token_deadline(&state, &catalog_model);
        let (mut rx, target_node, session_id) = pick_and_dispatch(
            &state,
            &catalog_model,
            &req_body,
            &excluded,
            Some(required_ctx),
            &preferred_node_ids,
        )
        .await?;

        let mut got_first = false;
        let mut retriable = false;
        let mut completed = false;
        let mut err_message: Option<String> = None;

        loop {
            let deadline = if got_first {
                request_timeout
            } else {
                ttft_deadline
            };
            let next = tokio::time::timeout(deadline, rx.recv()).await;
            match next {
                Ok(Some(SessionEvent::Chunk(chunk))) => {
                    if !got_first {
                        got_first = true;
                        first_token_at = Some(Instant::now());
                        metrics::TTFT_SECONDS
                            .with_label_values(&[&model_id])
                            .observe(started.elapsed().as_secs_f64());
                    }
                    tokens_out += 1;
                    if let Some(text) = extract_delta_content(&chunk) {
                        accumulated_text.push_str(&text);
                    }
                    if let Some(obj) = chunk.as_object() {
                        if let Some(u) = obj.get("usage").cloned() {
                            if !u.is_null() {
                                captured_usage = Some(u);
                            }
                        }
                        last_chunk_obj = Some(obj.clone());
                    }
                }
                Ok(Some(SessionEvent::Complete { .. })) => {
                    completed = true;
                    break;
                }
                Ok(Some(SessionEvent::Error { message, .. })) => {
                    err_message = Some(message);
                    if !got_first && tried <= max_retries {
                        retriable = true;
                    }
                    break;
                }
                Ok(Some(SessionEvent::Disconnect(reason))) => {
                    err_message = Some(reason);
                    if !got_first && tried <= max_retries {
                        retriable = true;
                    }
                    break;
                }
                Ok(None) => {
                    err_message = Some("channel closed".into());
                    if !got_first && tried <= max_retries {
                        retriable = true;
                    }
                    break;
                }
                Err(_) => {
                    err_message = Some(if got_first {
                        "timeout mid-stream".into()
                    } else {
                        "ttft timeout".into()
                    });
                    if !got_first && tried <= max_retries {
                        retriable = true;
                    }
                    break;
                }
            }
        }

        state.relay.close_session(&target_node, &session_id);
        state.registry.dec_in_flight(&target_node);

        let single_supplier = single_supplier_large_cold_start_grace(&state, &catalog_model)
            || state.registry.eligible_devices(&model_id).len() <= 1;
        let warmup_retry = !got_first
            && single_supplier
            && err_message
                .as_deref()
                .is_some_and(is_transient_warmup_error);

        if !completed && !got_first && !warmup_retry && !cold_start_grace {
            state
                .registry
                .quarantine(&target_node, state.config.reliability.quarantine_seconds);
        }

        if completed {
            metrics::REQUESTS_TOTAL
                .with_label_values(&[&model_id, "ok"])
                .inc();
            metrics::TOTAL_LATENCY_SECONDS
                .with_label_values(&[&model_id, "ok"])
                .observe(started.elapsed().as_secs_f64());
            metrics::TOKENS_OUT_TOTAL
                .with_label_values(&[&model_id])
                .inc_by(tokens_out as f64);
            if let Some(ft) = first_token_at {
                let ttft_ms = ft.duration_since(started).as_millis() as u32;
                let total_ms = started.elapsed().as_millis() as u64;
                state
                    .model_metrics
                    .record(&model_id, ttft_ms, Some(tokens_out.max(1)), total_ms);
            }

            // Settle Teale Credit ledger.
            if let (Some(consumer_p), Some(pool)) = (consumer.as_ref(), state.db.as_ref()) {
                let prompt_tokens = captured_usage
                    .as_ref()
                    .and_then(|u| u.get("prompt_tokens").and_then(|v| v.as_u64()))
                    .unwrap_or(0);
                let cost = ledger::cost_credits(
                    prompt_tokens,
                    tokens_out.max(1),
                    catalog_model.prompt_price_usd(),
                    catalog_model.completion_price_usd(),
                );
                let online: Vec<String> = state
                    .registry
                    .snapshot_devices()
                    .into_iter()
                    .map(|d| d.node_id)
                    .collect();
                let request_id = Uuid::new_v4().to_string();
                if let Err(e) = ledger::settle_request(
                    pool,
                    consumer_p,
                    Some(target_node.as_str()),
                    &online,
                    cost,
                    &request_id,
                    &model_id,
                ) {
                    warn!("settle_request failed: {}", e);
                }
            }

            let reply = build_non_stream_response(
                &model_id,
                &accumulated_text,
                &last_chunk_obj,
                tokens_out,
            );
            return Ok(Json(reply));
        }

        if let Some(message) = err_message.as_ref() {
            warn!(
                device = %target_node,
                retriable,
                got_first,
                "buffered upstream ended: {}",
                message
            );
        }

        if retriable {
            if warmup_retry || cold_start_grace {
                info!(
                    device = %target_node,
                    "retrying same device after {}",
                    if warmup_retry {
                        "transient warmup failure"
                    } else {
                        "large-model cold-start grace"
                    }
                );
                tokio::time::sleep(Duration::from_secs(2)).await;
                metrics::RETRIES_TOTAL
                    .with_label_values(&[if warmup_retry {
                        "buffered_warmup_retry"
                    } else {
                        "single_supplier_cold_start_retry"
                    }])
                    .inc();
                continue;
            }
            info!(device = %target_node, "retrying (buffered) on next-best device");
            state
                .registry
                .quarantine(&target_node, state.config.reliability.quarantine_seconds);
            excluded.push(target_node);
            metrics::RETRIES_TOTAL
                .with_label_values(&["buffered_failure"])
                .inc();
            continue;
        }

        metrics::REQUESTS_TOTAL
            .with_label_values(&[&model_id, "error"])
            .inc();
        return Err(GatewayError::AllUpstreamsFailed(
            err_message.unwrap_or_else(|| "unknown".into()),
        ));
    }
}

fn extract_delta_content(chunk: &Value) -> Option<String> {
    chunk
        .get("choices")?
        .get(0)?
        .get("delta")?
        .get("content")?
        .as_str()
        .map(str::to_owned)
}

fn build_non_stream_response(
    model_id: &str,
    text: &str,
    last_chunk: &Option<serde_json::Map<String, Value>>,
    tokens_out: u64,
) -> Value {
    let id = last_chunk
        .as_ref()
        .and_then(|o| o.get("id"))
        .and_then(|v| v.as_str())
        .map(str::to_owned)
        .unwrap_or_else(|| format!("chatcmpl-{}", Uuid::new_v4()));
    let created = last_chunk
        .as_ref()
        .and_then(|o| o.get("created"))
        .and_then(|v| v.as_u64())
        .unwrap_or_else(|| {
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .map(|d| d.as_secs())
                .unwrap_or(0)
        });
    serde_json::json!({
        "id": id,
        "object": "chat.completion",
        "created": created,
        "model": model_id,
        "choices": [{
            "index": 0,
            "message": {
                "role": "assistant",
                "content": text,
            },
            "finish_reason": "stop",
        }],
        "usage": {
            "prompt_tokens": 0,
            "completion_tokens": tokens_out,
            "total_tokens": tokens_out,
        },
    })
}

fn error_event(err: &GatewayError) -> Event {
    let body = serde_json::json!({
        "error": {
            "message": err.to_string(),
            "type": err.code(),
            "code": err.code(),
        }
    });
    Event::default().data(body.to_string())
}

fn done_event() -> Event {
    Event::default().data("[DONE]")
}

pub(crate) fn error_to_status_label(err: &GatewayError) -> &'static str {
    match err {
        GatewayError::NoEligibleDevice(_) => "no_supply",
        GatewayError::ModelNotFound(_) => "model_not_found",
        GatewayError::NotFound(_) => "not_found",
        GatewayError::Forbidden(_) => "forbidden",
        GatewayError::Conflict(_) => "conflict",
        GatewayError::BudgetExhausted => "budget_exhausted",
        GatewayError::InsufficientCredits { .. } => "insufficient_credits",
        GatewayError::BadRequest(_) => "bad_request",
        GatewayError::Unauthorized(_) => "unauthorized",
        GatewayError::UpstreamTimeout => "timeout",
        GatewayError::Upstream(_) | GatewayError::AllUpstreamsFailed(_) => "error",
        GatewayError::RelayUnavailable(_) => "relay_unavailable",
        GatewayError::Other(_) => "error",
    }
}

// This is unused right now, but handy when we add request-id echo to logs later.
#[allow(dead_code)]
fn request_id_from_headers(headers: &HeaderMap) -> String {
    headers
        .get("x-request-id")
        .and_then(|v| v.to_str().ok())
        .map(str::to_owned)
        .unwrap_or_else(|| Uuid::new_v4().to_string())
}

#[allow(dead_code)]
pub const CONTENT_TYPE: &str = "application/json";

#[allow(dead_code)]
fn _touch_unused_headers() -> header::HeaderName {
    header::CONTENT_TYPE
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Arc;
    use std::time::Duration;

    use axum::http::HeaderValue;
    use teale_protocol::openai::ApiMessage;
    use teale_protocol::{HardwareCapability, NodeCapabilities};
    use tokio::sync::broadcast;
    use tokio::time::{sleep, Instant};

    use crate::auth::TokenTable;
    use crate::config::{Config, PerModelFloor, RelayConfig, ReliabilityConfig, SchedulerConfig};
    use crate::model_metrics::ModelMetricsTracker;
    use crate::registry::Registry;
    use crate::scheduler::Scheduler;
    use crate::state::{AppState, ShareKeyIssuers};

    fn kimi_like() -> CatalogModel {
        // Mirrors the catalog entry for moonshotai/kimi-k2.6: $0.50/M prompt,
        // $1.00/M completion, 16384 max output.
        serde_yaml::from_str(
            r#"
id: moonshotai/kimi-k2.6
display_name: Kimi K2.6 (test)
owned_by: moonshotai
context_length: 32000
max_output_tokens: 16384
params_b: 1000.0
pricing_prompt: "0.00000050"
pricing_completion: "0.00000100"
quantization: null
"#,
        )
        .unwrap()
    }

    fn free_like() -> CatalogModel {
        serde_yaml::from_str(
            r#"
id: free/tiny
display_name: Free Tiny
owned_by: test
context_length: 4096
max_output_tokens: 2048
params_b: 1.0
pricing_prompt: "0"
pricing_completion: "0"
quantization: null
"#,
        )
        .unwrap()
    }

    fn req_with(user: &str, max_tokens: Option<u32>) -> ChatCompletionRequest {
        ChatCompletionRequest {
            model: Some("moonshotai/kimi-k2.6".into()),
            messages: vec![ApiMessage {
                role: "user".into(),
                content: Value::String(user.into()),
                name: None,
                tool_calls: None,
                tool_call_id: None,
            }],
            temperature: None,
            top_p: None,
            max_tokens,
            stream: None,
            stream_options: None,
            stop: None,
            presence_penalty: None,
            frequency_penalty: None,
            tools: None,
            tool_choice: None,
            response_format: None,
            seed: None,
            user: None,
        }
    }

    fn req_with_system(system: &str, max_tokens: Option<u32>) -> ChatCompletionRequest {
        ChatCompletionRequest {
            model: Some("teale/auto".into()),
            messages: vec![
                ApiMessage {
                    role: "system".into(),
                    content: Value::String(system.into()),
                    name: None,
                    tool_calls: None,
                    tool_call_id: None,
                },
                ApiMessage {
                    role: "user".into(),
                    content: Value::String("hi".into()),
                    name: None,
                    tool_calls: None,
                    tool_call_id: None,
                },
            ],
            temperature: None,
            top_p: None,
            max_tokens,
            stream: None,
            stream_options: None,
            stop: None,
            presence_penalty: None,
            frequency_penalty: None,
            tools: None,
            tool_choice: None,
            response_format: None,
            seed: None,
            user: None,
        }
    }

    fn dispatch_test_config(ttft_deadline_seconds: u64) -> Config {
        Config {
            bind: "127.0.0.1:0".into(),
            display_name: "test-gateway".into(),
            relay: RelayConfig {
                url: "ws://127.0.0.1:0/ws".into(),
            },
            identity_path: "/tmp/test-gateway-identity.key".into(),
            models_yaml: "models.yaml".into(),
            scheduler: SchedulerConfig {
                max_queue_depth: 8,
                swap_penalty: 0.3,
                tps_weight: 1.0,
                per_model_floor: PerModelFloor { large: 1, small: 1 },
            },
            reliability: ReliabilityConfig {
                request_timeout_seconds: 60,
                ttft_deadline_seconds,
                small_ttft_deadline_seconds: ttft_deadline_seconds,
                max_retries: 1,
                heartbeat_stale_seconds: 3600,
                quarantine_seconds: 30,
                discover_interval_seconds: 10,
            },
            synthetic_probes: Default::default(),
        }
    }

    fn dispatch_caps(loaded: &[&str], swappable: &[&str]) -> NodeCapabilities {
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
            swappable_models: swappable.iter().map(|s| s.to_string()).collect(),
            max_concurrent_requests: Some(4),
            effective_context: Some(32768),
            on_ac_power: Some(true),
        }
    }

    fn dispatch_test_state_with_catalog(config: Config, catalog: Vec<CatalogModel>) -> AppState {
        let registry = Registry::new(config.reliability.clone());
        let scheduler = Arc::new(Scheduler::new(config.scheduler.clone()));
        let relay = crate::relay_client::RelayHandle::test_handle();
        let (group_tx, _group_rx) = broadcast::channel(16);
        AppState {
            config,
            tokens: TokenTable::default(),
            registry,
            scheduler,
            relay,
            catalog: Arc::new(catalog),
            db: None,
            group_tx,
            model_metrics: Arc::new(ModelMetricsTracker::new()),
            share_key_issuers: ShareKeyIssuers::default(),
            providers: crate::providers::ProvidersHandle::empty_for_test(),
        }
    }

    fn dispatch_test_state(config: Config, catalog_model: &CatalogModel) -> AppState {
        dispatch_test_state_with_catalog(config, vec![catalog_model.clone()])
    }

    fn virtual_auto() -> CatalogModel {
        serde_yaml::from_str(
            r#"
id: teale/auto
display_name: Teale Auto
owned_by: teale
context_length: 262144
max_output_tokens: 32768
params_b: 0
pricing_prompt: "0.00000010"
pricing_completion: "0.00000020"
virtual: true
aliases: [teale-auto]
"#,
        )
        .unwrap()
    }

    fn concrete(id: &str, params_b: f64, ctx: u32) -> CatalogModel {
        serde_yaml::from_str(&format!(
            r#"
id: {id}
display_name: {id}
owned_by: test
context_length: {ctx}
max_output_tokens: 8192
params_b: {params_b}
pricing_prompt: "0.00000010"
pricing_completion: "0.00000020"
"#
        ))
        .unwrap()
    }

    #[tokio::test]
    async fn teale_auto_skips_models_only_swappable_no_loaded_supply() {
        // Regression: when a smaller-params_b model has no loaded supply but
        // some device claims it as `swappable`, resolve_auto used to count
        // that device — picking the smaller model and then 503ing because
        // the post-resolution `loaded_count` floor check rejects swappable.
        // After the fix, resolve_auto's supply closure mirrors `loaded_count`
        // and falls through to the next-larger model that actually has
        // loaded supply.
        use crate::auth::{AuthPrincipal, PrincipalKind};
        use axum::http::HeaderMap;

        let config = dispatch_test_config(15);
        let small = concrete("test/small", 8.0, 32768);
        let big = concrete("test/big", 35.0, 262144);
        let state = dispatch_test_state_with_catalog(
            config,
            vec![virtual_auto(), small.clone(), big.clone()],
        );

        // One device has `big` actually loaded, and claims `small` as swappable.
        // Pre-fix: resolve_auto picks `small` (smaller params_b) since the
        // closure counts swappable. Post-fix: skips `small` (zero loaded) and
        // picks `big`.
        state.registry.upsert_device(
            "node-A".into(),
            "Tailor 64".into(),
            dispatch_caps(&[&big.id], &[&small.id]),
        );

        let req = serde_json::to_value(req_with_system("system", Some(64))).unwrap();
        let principal = AuthPrincipal {
            kind: PrincipalKind::Static {
                scope: "internal".into(),
            },
        };
        let prepared = prepare_chat_request(&state, &HeaderMap::new(), &principal, req)
            .expect("should resolve to the actually-loaded model");
        assert_eq!(prepared.catalog_model.id, big.id);
    }

    #[tokio::test]
    async fn resolves_live_uncataloged_model_by_exact_id() {
        let config = dispatch_test_config(15);
        let state = dispatch_test_state_with_catalog(config, vec![]);
        state.registry.upsert_device(
            "node-live".into(),
            "Tailor 512g1".into(),
            dispatch_caps(&["acme/live-model"], &[]),
        );

        let resolved =
            resolve_requested_model(&state, "acme/live-model").expect("live model should resolve");
        assert_eq!(resolved.id, "acme/live-model");
        assert_eq!(resolved.context_length, 32768);
        assert_eq!(resolved.max_output_tokens, 8192);
        assert_eq!(
            resolved.pricing_prompt,
            crate::catalog::LIVE_MODEL_DEFAULT_PROMPT_PRICE
        );
        assert_eq!(
            resolved.pricing_completion,
            crate::catalog::LIVE_MODEL_DEFAULT_COMPLETION_PRICE
        );
    }

    #[test]
    fn tight_budget_no_max_tokens_accepts_with_clamp() {
        // Reproduces the production bug: "hi" to kimi-k2.6 with a 4535-credit
        // effective budget. Before: rejected (need 16393). After: accepted,
        // clamped to what fits.
        let model = kimi_like();
        let req = req_with("hi", None);
        let decision = compute_clamp(&model, &req, 4535).expect("should accept, not reject");
        // client_max defaults to the catalog ceiling.
        assert_eq!(decision.client_max, 16384);
        // prompt_tokens_est = (2/4).ceil() + 16 = 17 → 17*0.5e-6*1e6 = 8.5 → 9 credits.
        // remaining = 4535 - 9 = 4526 → affordable = floor(4526 / 1.0) = 4526.
        assert_eq!(decision.effective_max, 4526);
        assert!(decision.clamped);
        // Post-clamp reservation must be within budget.
        let reserved = ledger::cost_credits(
            prompt_tokens_estimate(&req),
            decision.effective_max,
            model.prompt_price_usd(),
            model.completion_price_usd(),
        );
        assert!(reserved <= 4535, "reserved={} should fit in 4535", reserved);
    }

    #[test]
    fn budget_below_prompt_plus_one_rejects() {
        // Effective budget smaller than prompt_cost + 1 completion credit must
        // still reject. For kimi with "hi" the floor is 9 + 1 = 10 credits.
        let model = kimi_like();
        let req = req_with("hi", None);
        let err = compute_clamp(&model, &req, 5).expect_err("should reject");
        assert_eq!(err, 10);
    }

    #[test]
    fn client_max_tokens_smaller_than_affordable_is_preserved() {
        // Well-funded caller with max_tokens=500 should NOT be scaled up.
        let model = kimi_like();
        let req = req_with("hi", Some(500));
        let decision = compute_clamp(&model, &req, 10_000_000).expect("should accept");
        assert_eq!(decision.client_max, 500);
        assert_eq!(decision.effective_max, 500);
        assert!(!decision.clamped);
    }

    #[test]
    fn well_funded_no_max_tokens_uses_catalog_ceiling() {
        // A paying user who omits max_tokens still gets the full catalog
        // ceiling as before — no regression.
        let model = kimi_like();
        let req = req_with("hi", None);
        let decision = compute_clamp(&model, &req, 10_000_000).expect("should accept");
        assert_eq!(decision.effective_max, 16384);
        assert_eq!(decision.client_max, 16384);
        assert!(!decision.clamped);
    }

    #[test]
    fn client_max_above_catalog_clamped_down_to_ceiling() {
        // Client asked for more than the catalog allows; we never reserve
        // past the ceiling regardless of budget.
        let model = kimi_like();
        let req = req_with("hi", Some(50_000));
        let decision = compute_clamp(&model, &req, 10_000_000).expect("should accept");
        assert_eq!(decision.effective_max, 16384);
        // client_max is already capped to catalog_max before the clamp, so
        // the decision reports "not clamped by budget" — the ceiling applied
        // at parse time, not the budget path.
        assert_eq!(decision.client_max, 16384);
    }

    #[test]
    fn free_model_skips_affordability_and_takes_ceiling() {
        // For a free model, the completion-price inverse is undefined; we
        // should clamp to the catalog ceiling without dividing by zero.
        let model = free_like();
        let req = req_with("hello world", None);
        // 2 credits covers prompt_cost(=1) + one_out_cost(=1) since free.
        let decision = compute_clamp(&model, &req, 2).expect("should accept");
        assert_eq!(decision.effective_max, 2048);
    }

    #[test]
    fn tiny_budget_one_token_floor() {
        // Budget equal to prompt_cost + 1 completion token: accepts with a
        // 1-token ceiling.
        let model = kimi_like();
        let req = req_with("hi", None);
        // 10 = 9 prompt + 1 completion.
        let decision = compute_clamp(&model, &req, 10).expect("should accept at floor");
        assert_eq!(decision.effective_max, 1);
        assert!(decision.clamped);
    }

    #[test]
    fn auto_profile_keeps_tiny_openclaw_run_generic() {
        let mut headers = HeaderMap::new();
        headers.insert(header::USER_AGENT, HeaderValue::from_static("OpenClaw/1.0"));
        let req = req_with("hi", Some(128));
        assert_eq!(
            infer_auto_route_profile(&headers, &req),
            AutoRouteProfile::Generic
        );
    }

    #[test]
    fn auto_profile_detects_large_openclaw_prompt() {
        let mut headers = HeaderMap::new();
        headers.insert(header::USER_AGENT, HeaderValue::from_static("OpenClaw/1.0"));
        let req = req_with(&"x".repeat(4_500), Some(4096));
        assert_eq!(
            infer_auto_route_profile(&headers, &req),
            AutoRouteProfile::AgentHarness
        );
    }

    #[test]
    fn auto_profile_detects_agent_bootstrap_prompt() {
        let headers = HeaderMap::new();
        let req = req_with_system(
            "Load AGENTS.md and TOOLS.md from the workspace.",
            Some(8192),
        );
        assert_eq!(
            infer_auto_route_profile(&headers, &req),
            AutoRouteProfile::AgentHarness
        );
    }

    #[test]
    fn transient_warmup_error_detects_loading_model() {
        assert!(is_transient_warmup_error(
            "backend returned 503 Service Unavailable: {\"error\":{\"message\":\"Loading model\",\"type\":\"unavailable_error\",\"code\":503}}"
        ));
        assert!(!is_transient_warmup_error("ttft timeout"));
    }

    #[tokio::test]
    async fn large_single_supplier_uses_request_timeout_for_first_token_deadline() {
        let model = kimi_like();
        let state = dispatch_test_state(dispatch_test_config(18), &model);
        state.registry.upsert_device(
            "node-a".into(),
            "Node A".into(),
            dispatch_caps(&[&model.id], &[]),
        );

        assert!(single_supplier_large_cold_start_grace(&state, &model));
        assert_eq!(
            pre_first_token_deadline(&state, &model),
            Duration::from_secs(state.config.reliability.request_timeout_seconds)
        );
    }

    #[tokio::test]
    async fn small_single_supplier_keeps_normal_first_token_deadline() {
        let model = free_like();
        let state = dispatch_test_state(dispatch_test_config(18), &model);
        state.registry.upsert_device(
            "node-a".into(),
            "Node A".into(),
            dispatch_caps(&[&model.id], &[]),
        );

        assert!(!single_supplier_large_cold_start_grace(&state, &model));
        assert_eq!(
            pre_first_token_deadline(&state, &model),
            Duration::from_secs(18)
        );
    }

    #[tokio::test]
    async fn large_loaded_supplier_keeps_grace_even_with_extra_swappable_node() {
        let model = kimi_like();
        let state = dispatch_test_state(dispatch_test_config(18), &model);
        state.registry.upsert_device(
            "node-a".into(),
            "Node A".into(),
            dispatch_caps(&[&model.id], &[]),
        );
        state.registry.upsert_device(
            "node-b".into(),
            "Node B".into(),
            dispatch_caps(&[], &[&model.id]),
        );

        assert!(single_supplier_large_cold_start_grace(&state, &model));
        assert_eq!(
            pre_first_token_deadline(&state, &model),
            Duration::from_secs(state.config.reliability.request_timeout_seconds)
        );
    }

    #[tokio::test]
    async fn pick_and_dispatch_quarantines_failed_open_and_tries_next_device() {
        let model = free_like();
        let state = dispatch_test_state(dispatch_test_config(1), &model);
        state.registry.upsert_device(
            "node-a".into(),
            "Node A".into(),
            dispatch_caps(&[&model.id], &[]),
        );
        state.registry.upsert_device(
            "node-b".into(),
            "Node B".into(),
            dispatch_caps(&[], &[&model.id]),
        );

        let relay = state.relay.clone();
        let signal_second_ready = tokio::spawn(async move {
            let mut seen = std::collections::HashSet::new();
            let deadline = Instant::now() + Duration::from_secs(3);
            loop {
                for session_id in relay.test_ready_waiter_ids() {
                    if seen.insert(session_id.clone()) && seen.len() == 2 {
                        assert!(relay.test_signal_ready(&session_id));
                        return;
                    }
                }
                if Instant::now() >= deadline {
                    panic!("timed out waiting for second relay-open attempt");
                }
                sleep(Duration::from_millis(20)).await;
            }
        });

        let (rx, target_node, _session_id) = pick_and_dispatch(
            &state,
            &model,
            &serde_json::to_value(req_with("hi", Some(16))).unwrap(),
            &[],
            None,
            &[],
        )
        .await
        .expect("dispatch should retry on relay-open failure");
        drop(rx);

        signal_second_ready
            .await
            .expect("ready waiter task should finish");

        assert_eq!(target_node, "node-b");
        let eligible = state.registry.eligible_devices(&model.id);
        let eligible_ids: Vec<_> = eligible.iter().map(|d| d.node_id.as_str()).collect();
        assert_eq!(eligible_ids, vec!["node-b"]);
        assert_eq!(state.registry.in_flight("node-a"), 0);
        assert_eq!(state.registry.in_flight("node-b"), 1);
    }

    #[tokio::test]
    async fn pick_and_dispatch_prefers_requested_linked_node() {
        let model = free_like();
        let state = dispatch_test_state(dispatch_test_config(2), &model);
        state.registry.upsert_device(
            "node-a".into(),
            "Node A".into(),
            dispatch_caps(&[&model.id], &[]),
        );
        state.registry.upsert_device(
            "node-b".into(),
            "Node B".into(),
            dispatch_caps(&[&model.id], &[]),
        );

        let relay = state.relay.clone();
        let signal_ready = tokio::spawn(async move {
            let deadline = Instant::now() + Duration::from_secs(3);
            loop {
                if let Some(session_id) = relay.test_ready_waiter_ids().into_iter().next() {
                    assert!(relay.test_signal_ready(&session_id));
                    return;
                }
                if Instant::now() >= deadline {
                    panic!("timed out waiting for relay-open attempt");
                }
                sleep(Duration::from_millis(20)).await;
            }
        });

        let (rx, target_node, _session_id) = pick_and_dispatch(
            &state,
            &model,
            &serde_json::to_value(req_with("hi", Some(16))).unwrap(),
            &[],
            None,
            &["node-b".to_string()],
        )
        .await
        .expect("dispatch should choose preferred node");
        drop(rx);

        signal_ready.await.expect("ready waiter task should finish");
        assert_eq!(target_node, "node-b");
        assert_eq!(state.registry.in_flight("node-b"), 1);
    }

    #[tokio::test]
    async fn pick_and_dispatch_single_large_supplier_retries_same_node_before_quarantine() {
        let model = kimi_like();
        let state = dispatch_test_state(dispatch_test_config(10), &model);
        state.registry.upsert_device(
            "node-a".into(),
            "Node A".into(),
            dispatch_caps(&[&model.id], &[]),
        );

        let relay = state.relay.clone();
        let signal_second_ready = tokio::spawn(async move {
            let mut seen = std::collections::HashSet::new();
            let deadline = Instant::now() + Duration::from_secs(8);
            loop {
                for session_id in relay.test_ready_waiter_ids() {
                    if seen.insert(session_id.clone()) && seen.len() == 2 {
                        assert!(relay.test_signal_ready(&session_id));
                        return;
                    }
                }
                if Instant::now() >= deadline {
                    panic!("timed out waiting for second relay-open attempt");
                }
                sleep(Duration::from_millis(20)).await;
            }
        });

        let (rx, target_node, _session_id) = pick_and_dispatch(
            &state,
            &model,
            &serde_json::to_value(req_with("hi", Some(16))).unwrap(),
            &[],
            None,
            &[],
        )
        .await
        .expect("dispatch should retry same node during cold-start grace");
        drop(rx);

        signal_second_ready
            .await
            .expect("ready waiter task should finish");

        assert_eq!(target_node, "node-a");
        let eligible = state.registry.eligible_devices(&model.id);
        let eligible_ids: Vec<_> = eligible.iter().map(|d| d.node_id.as_str()).collect();
        assert_eq!(eligible_ids, vec!["node-a"]);
        assert_eq!(state.registry.in_flight("node-a"), 1);
    }
}
