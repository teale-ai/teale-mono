//! Centralized 3rd-party provider dispatch path for `/v1/chat/completions`.
//!
//! `try_centralized_dispatch` is invoked by the chat handler **before** the
//! existing local-supply flow. It opts in only when the user explicitly
//! routes through a registered provider (`provider.order` lists a
//! centralized slug, OR the model is centralized-only with no fleet supply).
//! Otherwise it returns `None` and the chat handler falls through to the
//! existing scheduler/relay path, leaving that 1900-line code path
//! untouched.

use std::convert::Infallible;
use std::time::Instant;

use axum::{
    http::{HeaderMap, StatusCode},
    response::{sse::Event, IntoResponse, Response, Sse},
    Json,
};
use futures_util::stream::Stream;
use serde_json::Value;
use tokio::sync::mpsc;
use tracing::{info, warn};
use uuid::Uuid;

use crate::auth::AuthPrincipal;
use crate::error::GatewayError;
use crate::ledger::{self, ConsumerPrincipal};
use crate::providers::{anthropic_compat, openai_compat, ProviderError};
use crate::router::{
    self, parse_slug_shortcut, Candidate, LocalDistributedCandidate, ProviderCandidate, SortPref,
};
use crate::state::AppState;

/// Outcome of the centralized-dispatch try. `None` ⇒ caller falls through to
/// the local relay/scheduler path. `Some(Ok)` / `Some(Err)` ⇒ centralized
/// handled the request (success or failure with `allow_fallbacks=false`).
pub async fn try_centralized_dispatch(
    state: &AppState,
    _headers: &HeaderMap,
    principal: &AuthPrincipal,
    body: &mut Value,
) -> Option<Result<Response, GatewayError>> {
    let raw_model = body.get("model").and_then(|v| v.as_str())?.to_string();
    let (clean_model, slug_sort) = parse_slug_shortcut(&raw_model);
    if clean_model != raw_model {
        if let Some(o) = body.as_object_mut() {
            o.insert("model".into(), Value::String(clean_model.clone()));
        }
    }

    let mut prefs = router::extract_preferences(body);
    if prefs.sort.is_none() {
        if let Some(s) = slug_sort {
            prefs.sort = Some(SortPref::Simple(s));
        }
    }

    let rows = state.providers.registry.lookup_model(&clean_model);
    if rows.is_empty() {
        return None;
    }

    let request_features = features_from_body(body);
    let request_ctx = 0;
    let candidates = router::rank_provider_candidates(
        &clean_model,
        request_ctx,
        &request_features,
        &prefs,
        &state.providers.health,
        rows,
    );

    let local_loaded = state.registry.loaded_count(&clean_model);
    let centralized_first_in_order = prefs
        .order
        .as_ref()
        .and_then(|o| o.first())
        .map(|first| candidates.iter().any(|c| c.slug() == first.as_str()))
        .unwrap_or(false);
    let centralized_only_supply = local_loaded == 0 && !candidates.is_empty();

    if !centralized_first_in_order && !centralized_only_supply {
        return None;
    }

    let local_cand = (local_loaded > 0).then(LocalDistributedCandidate::default);
    let ordered = router::order_candidates(candidates, local_cand, &prefs);

    // Walk the ordered list, take centralized candidates only. If the next
    // hop is `LocalDistributed`, that means the user's preferences ranked
    // local above any remaining centralized — fall through.
    let mut tried: Vec<ProviderCandidate> = Vec::new();
    for cand in ordered {
        match cand {
            Candidate::CentralizedProvider(p) => tried.push(*p),
            Candidate::LocalDistributed(_) => {
                // The user's ordering bubbled local up; let the existing flow
                // handle it. Anything below that point is also fall-through
                // territory because the chat handler only gets one shot at
                // dispatch.
                if tried.is_empty() {
                    return None;
                }
                break;
            }
        }
    }
    if tried.is_empty() {
        return None;
    }

    let stream = body
        .get("stream")
        .and_then(|v| v.as_bool())
        .unwrap_or(false);
    let consumer = crate::handlers::chat::consumer_principal(principal);

    let mut last_err: Option<ProviderError> = None;
    for pc in tried {
        let attempt = if stream {
            dispatch_streaming(state, body.clone(), pc.clone(), consumer.clone()).await
        } else {
            dispatch_buffered(state, body.clone(), pc.clone(), consumer.clone()).await
        };
        match attempt {
            Ok(resp) => return Some(Ok(resp)),
            Err(e) => {
                state.providers.health.record_failure(
                    &pc.provider.provider_id,
                    &pc.model.model_id,
                    e.counts_against_uptime(),
                );
                warn!(
                    provider = %pc.slug(),
                    model = %pc.model.model_id,
                    "centralized dispatch failed: {}", e
                );
                last_err = Some(e);
                if !prefs.allow_fallbacks {
                    break;
                }
            }
        }
    }

    let err = last_err
        .map(|e| match e {
            ProviderError::Http { status, message } => {
                GatewayError::Upstream(format!("provider HTTP {}: {}", status, message))
            }
            ProviderError::MidStream(m) => GatewayError::Upstream(format!("mid-stream: {}", m)),
            ProviderError::Network(m) => GatewayError::Upstream(format!("network: {}", m)),
            ProviderError::Invalid(m) => GatewayError::Upstream(format!("invalid: {}", m)),
            ProviderError::Unavailable => {
                GatewayError::Upstream("provider unavailable".to_string())
            }
        })
        .unwrap_or_else(|| {
            GatewayError::Upstream("no centralized provider candidates".to_string())
        });
    Some(Err(err))
}

fn features_from_body(body: &Value) -> Vec<String> {
    let mut features = Vec::new();
    if body.get("tools").map(|v| !v.is_null()).unwrap_or(false)
        || body.get("functions").map(|v| !v.is_null()).unwrap_or(false)
    {
        features.push("tools".to_string());
    }
    if let Some(rf) = body.get("response_format") {
        if rf.get("type").and_then(|v| v.as_str()) == Some("json_object") {
            features.push("json_mode".to_string());
        }
        if rf.get("type").and_then(|v| v.as_str()) == Some("json_schema") {
            features.push("structured_outputs".to_string());
        }
    }
    features
}

async fn dispatch_buffered(
    state: &AppState,
    mut body: Value,
    pc: ProviderCandidate,
    consumer: Option<ConsumerPrincipal>,
) -> Result<Response, ProviderError> {
    if let Some(o) = body.as_object_mut() {
        o.insert("model".into(), Value::String(pc.model.model_id.clone()));
    }
    let request_id = Uuid::new_v4().to_string();
    let started = Instant::now();
    let result = match pc.provider.wire_format {
        crate::providers::ProviderWireFormat::Openai => {
            openai_compat::dispatch_buffered(
                &state.providers.http,
                &pc.provider.base_url,
                &pc.provider.auth_header_name,
                &pc.provider.auth_secret_ref,
                body,
            )
            .await
        }
        crate::providers::ProviderWireFormat::Anthropic => {
            anthropic_compat::dispatch_buffered(
                &state.providers.http,
                &pc.provider.base_url,
                &pc.provider.auth_header_name,
                &pc.provider.auth_secret_ref,
                body,
            )
            .await
        }
    };
    let (json, usage) = result?;

    let total_ms = started.elapsed().as_millis() as u64;
    state.providers.health.record_success(
        &pc.provider.provider_id,
        &pc.model.model_id,
        usage.ttft_ms,
        usage
            .completion_tokens
            .checked_div(((total_ms as u32).max(1) / 1000).max(1))
            .map(|tps| tps as f64),
    );

    if let (Some(consumer), Some(pool)) = (consumer.as_ref(), state.db.as_ref()) {
        let cost = ledger::cost_credits(
            usage.prompt_tokens as u64,
            usage.completion_tokens as u64,
            pc.effective_prompt_price_usd,
            pc.effective_completion_price_usd,
        );
        if let Err(e) = ledger::settle_provider_request(
            pool,
            consumer,
            &pc.provider.provider_id,
            cost,
            &request_id,
            &pc.model.model_id,
        ) {
            warn!(
                provider = %pc.slug(),
                "settle_provider_request failed: {}",
                e
            );
        }
    }

    info!(
        provider = %pc.slug(),
        model = %pc.model.model_id,
        prompt = usage.prompt_tokens,
        completion = usage.completion_tokens,
        ms = total_ms,
        "centralized buffered dispatch completed"
    );
    Ok(Json(json).into_response())
}

async fn dispatch_streaming(
    state: &AppState,
    mut body: Value,
    pc: ProviderCandidate,
    consumer: Option<ConsumerPrincipal>,
) -> Result<Response, ProviderError> {
    if let Some(o) = body.as_object_mut() {
        o.insert("model".into(), Value::String(pc.model.model_id.clone()));
    }

    let (tx, mut rx) = mpsc::channel::<String>(128);
    let request_id = Uuid::new_v4().to_string();
    let state_for_task = state.clone();
    let pc_for_task = pc.clone();
    let consumer_for_task = consumer.clone();
    let req_for_task = request_id.clone();
    let body_for_task = body;

    // Spawn the upstream pump so we can return the SSE stream immediately.
    let dispatch_task = tokio::spawn(async move {
        let started = Instant::now();
        let upstream = match pc_for_task.provider.wire_format {
            crate::providers::ProviderWireFormat::Openai => {
                openai_compat::dispatch_streaming(
                    &state_for_task.providers.http,
                    &pc_for_task.provider.base_url,
                    &pc_for_task.provider.auth_header_name,
                    &pc_for_task.provider.auth_secret_ref,
                    body_for_task,
                    tx,
                )
                .await
            }
            crate::providers::ProviderWireFormat::Anthropic => {
                anthropic_compat::dispatch_streaming(
                    &state_for_task.providers.http,
                    &pc_for_task.provider.base_url,
                    &pc_for_task.provider.auth_header_name,
                    &pc_for_task.provider.auth_secret_ref,
                    body_for_task,
                    tx,
                )
                .await
            }
        };
        match upstream {
            Ok(usage) => {
                let total_ms = started.elapsed().as_millis() as u64;
                let tps = if total_ms > 0 {
                    Some((usage.completion_tokens as f64) / (total_ms as f64 / 1000.0))
                } else {
                    None
                };
                state_for_task.providers.health.record_success(
                    &pc_for_task.provider.provider_id,
                    &pc_for_task.model.model_id,
                    usage.ttft_ms,
                    tps,
                );
                if let (Some(consumer), Some(pool)) =
                    (consumer_for_task.as_ref(), state_for_task.db.as_ref())
                {
                    let cost = ledger::cost_credits(
                        usage.prompt_tokens as u64,
                        usage.completion_tokens as u64,
                        pc_for_task.effective_prompt_price_usd,
                        pc_for_task.effective_completion_price_usd,
                    );
                    if let Err(e) = ledger::settle_provider_request(
                        pool,
                        consumer,
                        &pc_for_task.provider.provider_id,
                        cost,
                        &req_for_task,
                        &pc_for_task.model.model_id,
                    ) {
                        warn!(
                            provider = %pc_for_task.provider.slug,
                            "settle_provider_request failed: {}",
                            e
                        );
                    }
                }
                info!(
                    provider = %pc_for_task.provider.slug,
                    model = %pc_for_task.model.model_id,
                    prompt = usage.prompt_tokens,
                    completion = usage.completion_tokens,
                    ms = total_ms,
                    "centralized streaming dispatch completed"
                );
            }
            Err(e) => {
                state_for_task.providers.health.record_failure(
                    &pc_for_task.provider.provider_id,
                    &pc_for_task.model.model_id,
                    e.counts_against_uptime(),
                );
                warn!(
                    provider = %pc_for_task.provider.slug,
                    "centralized streaming pump failed: {}",
                    e
                );
            }
        }
    });

    // Build the SSE stream from the receiver. We can't propagate
    // ProviderError back up at this point — the response status is already
    // committed — so an upstream-pump failure manifests as a closed stream.
    let stream = async_stream::stream! {
        while let Some(line) = rx.recv().await {
            // `line` is already SSE-formatted ("data: ...\n\n"); strip the
            // SSE prefix/suffix so axum's Sse<Event> can re-encode.
            let payload = line
                .strip_prefix("data: ")
                .unwrap_or(&line)
                .trim_end_matches("\n\n")
                .to_string();
            if payload == "[DONE]" {
                yield Ok::<_, Infallible>(Event::default().data("[DONE]"));
                continue;
            }
            yield Ok(Event::default().data(payload));
        }
        let _ = dispatch_task.await;
    };
    let pinned: std::pin::Pin<Box<dyn Stream<Item = Result<Event, Infallible>> + Send>> =
        Box::pin(stream);
    Ok(Sse::new(pinned).into_response())
}

/// Public entry point for surfacing internal mapping errors as 4xx/5xx so
/// callers don't see a stack trace. Kept here so downstream handlers can
/// treat us as a black box.
pub fn provider_error_response(e: ProviderError) -> Response {
    let status = match &e {
        ProviderError::Http { status, .. } => {
            StatusCode::from_u16(*status).unwrap_or(StatusCode::BAD_GATEWAY)
        }
        _ => StatusCode::BAD_GATEWAY,
    };
    (status, format!("{}", e)).into_response()
}
