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

use crate::auth::AuthPrincipal;
use crate::catalog::{is_large, CatalogModel};
use crate::error::GatewayError;
use crate::ledger;
use crate::metrics;
use crate::relay_client::{PendingSession, SessionEvent};
use crate::state::AppState;

pub async fn chat_completions(
    State(state): State<AppState>,
    Extension(principal): Extension<AuthPrincipal>,
    Json(req): Json<Value>,
) -> Result<Response, GatewayError> {
    // Parse the inbound request loosely so we can copy pass-through fields.
    let parsed: ChatCompletionRequest = serde_json::from_value(req.clone())
        .map_err(|e| GatewayError::BadRequest(format!("invalid request body: {}", e)))?;
    let Some(requested_model) = parsed.model.clone() else {
        return Err(GatewayError::BadRequest("`model` is required".into()));
    };

    // Catalog lookup.
    let catalog_model = state
        .catalog
        .iter()
        .find(|m| m.matches(&requested_model))
        .cloned()
        .ok_or_else(|| GatewayError::ModelNotFound(requested_model.clone()))?;

    // Per-model fleet floor: if we don't have enough healthy devices, 503.
    let floor = &state.config.scheduler.per_model_floor;
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
    let consumer = consumer_principal(&principal);

    // Pre-flight balance check — ledger must never go negative. Reject
    // before dispatching if the paying device (or share-key issuer) can't
    // cover a conservative max-cost reservation. See `reservation_credits`
    // for the reservation shape (rough prompt-tokens estimate plus full
    // max_tokens at the catalog's completion rate).
    if let (Some(consumer_p), Some(pool)) = (consumer.as_ref(), state.db.as_ref()) {
        let required = reservation_credits(&catalog_model, &parsed);
        let paying_device = consumer_p.paying_device_id();
        let balance = ledger::get_balance(pool, paying_device).balance_credits;
        if balance < required {
            return Err(GatewayError::InsufficientCredits { balance, required });
        }
        // For share-keys, the per-key budget is also a hard cap: even if the
        // issuer is rich, a key minted with a small budget must still refuse
        // the request rather than draining the issuer's wallet beyond the
        // bearer's share-key allowance.
        if let ledger::ConsumerPrincipal::Share { key_id, .. } = consumer_p {
            if let Some(remaining) = share_key_remaining(pool, key_id) {
                if remaining < required {
                    return Err(GatewayError::InsufficientCredits {
                        balance: remaining,
                        required,
                    });
                }
            }
        }
    }

    if streaming {
        let stream = run_streaming(state, catalog_model, req, consumer).await?;
        Ok(stream.into_response())
    } else {
        let json = run_buffered(state, catalog_model, req, consumer).await?;
        Ok(json.into_response())
    }
}

/// Conservative cost upper bound in credits for a request, used by the
/// pre-flight non-negative guard. Uses the catalog's per-token prices and a
/// cheap `bytes / 4` estimate for prompt tokens (the exact count isn't known
/// until upstream tokenizes). Completion side uses the request's `max_tokens`
/// bounded by the catalog's `max_output_tokens`.
fn reservation_credits(model: &CatalogModel, req: &ChatCompletionRequest) -> i64 {
    let prompt_bytes: usize = req
        .messages
        .iter()
        .map(|m| match &m.content {
            Value::String(s) => s.len(),
            other => other.to_string().len(),
        })
        .sum();
    // ~4 bytes/token is a conservative over-estimate for English; keeps the
    // reservation on the generous side of actual usage so settlement rarely
    // hits the shortfall path.
    let prompt_tokens_est = (prompt_bytes as u64).div_ceil(4) + 16;
    let max_out = req
        .max_tokens
        .map(|v| v as u64)
        .unwrap_or(model.max_output_tokens as u64)
        .min(model.max_output_tokens as u64)
        .max(1);
    ledger::cost_credits(
        prompt_tokens_est,
        max_out,
        model.prompt_price_usd(),
        model.completion_price_usd(),
    )
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

/// Build the ledger-facing consumer from an authenticated principal.
/// Static tokens don't settle (they pre-date the credit system), so we
/// return `None` for them.
fn consumer_principal(principal: &AuthPrincipal) -> Option<ledger::ConsumerPrincipal> {
    if let Some((issuer, key_id)) = principal.share_key() {
        return Some(ledger::ConsumerPrincipal::Share {
            issuer_device_id: issuer.to_string(),
            key_id: key_id.to_string(),
        });
    }
    principal
        .device_id()
        .map(|d| ledger::ConsumerPrincipal::Device(d.to_string()))
}

async fn pick_and_dispatch(
    state: &AppState,
    catalog_model: &CatalogModel,
    req_body: &Value,
    exclude: &[String],
) -> Result<(mpsc::Receiver<SessionEvent>, String, String), GatewayError> {
    let candidates = state.registry.eligible_devices(&catalog_model.id);
    let selected = state
        .scheduler
        .pick(&candidates, &catalog_model.id, exclude, &state.registry)
        .ok_or_else(|| GatewayError::NoEligibleDevice(catalog_model.id.clone()))?;

    let target_node = selected.node_id.clone();
    // Bump live in-flight counter so the next pick_and_dispatch sees this
    // node as busier. Use a scope guard so the counter rolls back if
    // any of the dispatch steps below fail before we successfully hand
    // off a Receiver to the caller (otherwise an open/send failure would
    // leave the counter permanently elevated).
    state.registry.inc_in_flight(&target_node);
    let inc_guard = InFlightGuard::new(state.registry.clone(), target_node.clone());

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

    // Open a relay session.
    let open_timeout = Duration::from_secs(state.config.reliability.ttft_deadline_seconds);
    let session_id = state
        .relay
        .open_session(&target_node, open_timeout)
        .await
        .map_err(|e| GatewayError::Upstream(format!("relay open: {}", e)))?;

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
        request: outbound,
        streaming: true,
    }));
    state
        .relay
        .send_cluster(&target_node, &session_id, &ir)
        .map_err(|e| GatewayError::Upstream(format!("relay send: {}", e)))?;

    // Successful hand-off; caller is responsible for dec_in_flight when
    // the session closes. Defuse the guard so we don't decrement here.
    inc_guard.defuse();
    Ok((rx, target_node, session_id))
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
) -> Result<Sse<impl Stream<Item = Result<Event, Infallible>>>, GatewayError> {
    let started = Instant::now();
    let model_id = catalog_model.id.clone();

    let max_retries = state.config.reliability.max_retries;
    let request_timeout = Duration::from_secs(state.config.reliability.request_timeout_seconds);
    let ttft_deadline = Duration::from_secs(state.config.reliability.ttft_deadline_seconds);

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
            let dispatch = pick_and_dispatch(&state, &catalog_model, &req_body, &excluded).await;

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

            if completed {
                served_by = Some(target_node);
                break;
            }
            if !retriable_failure {
                break;
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
                        consumer=%consumer_p.paying_device_id(),
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
            let gen_ms = total_ms.saturating_sub(ttft_ms);
            debug!(
                "request complete: model={} ttft_ms={} total_ms={} tokens_out={}",
                model_id, ttft_ms, total_ms, tokens_out
            );
            // Record a rolling sample for /v1/models percentile reporting.
            // Only record successful streams so bad attempts don't poison the
            // advertised serving speed. Use the supplier-reported token count
            // when available, falling back to the chunk count.
            if final_status == "ok" {
                let completion_tokens = reported_tokens
                    .map(|t| t as u64)
                    .unwrap_or(tokens_out)
                    .max(1);
                state.model_metrics.record(
                    &model_id,
                    ttft_ms as u32,
                    Some(completion_tokens),
                    gen_ms as u64,
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
) -> Result<Json<Value>, GatewayError> {
    let started = Instant::now();
    let model_id = catalog_model.id.clone();

    let max_retries = state.config.reliability.max_retries;
    let request_timeout = Duration::from_secs(state.config.reliability.request_timeout_seconds);
    let ttft_deadline = Duration::from_secs(state.config.reliability.ttft_deadline_seconds);

    let mut excluded: Vec<String> = Vec::new();
    let mut tried = 0u32;
    let mut accumulated_text = String::new();
    let mut last_chunk_obj: Option<serde_json::Map<String, Value>> = None;
    let mut captured_usage: Option<Value> = None;
    let mut tokens_out: u64 = 0;

    loop {
        tried += 1;
        let (mut rx, target_node, session_id) =
            pick_and_dispatch(&state, &catalog_model, &req_body, &excluded).await?;

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
                    got_first = true;
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

        if retriable {
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

fn error_to_status_label(err: &GatewayError) -> &'static str {
    match err {
        GatewayError::NoEligibleDevice(_) => "no_supply",
        GatewayError::ModelNotFound(_) => "model_not_found",
        GatewayError::NotFound(_) => "not_found",
        GatewayError::Forbidden(_) => "forbidden",
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
