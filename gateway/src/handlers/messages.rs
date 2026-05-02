//! Anthropic Messages compatibility for Claude Desktop / Claude Code 3P
//! gateway mode.

use std::collections::BTreeMap;
use std::convert::Infallible;
use std::time::{Duration, Instant};

use axum::{
    extract::State,
    http::HeaderMap,
    response::{sse::Event, IntoResponse, Response, Sse},
    Extension, Json,
};
use futures_util::stream::Stream;
use serde::Deserialize;
use serde_json::{Map, Value};
use tracing::{info, warn};
use uuid::Uuid;

use crate::auth::AuthPrincipal;
use crate::catalog::{is_large, CatalogModel};
use crate::error::GatewayError;
use crate::handlers::chat::{
    error_to_status_label, pick_and_dispatch, prepare_chat_request, PreparedChatRequest,
};
use crate::ledger;
use crate::metrics;
use crate::relay_client::SessionEvent;
use crate::state::AppState;

#[derive(Debug, Clone, Deserialize)]
struct AnthropicMessageRequest {
    model: String,
    #[serde(default)]
    max_tokens: Option<u32>,
    messages: Vec<AnthropicMessageParam>,
    #[serde(default)]
    system: Option<Value>,
    #[serde(default)]
    stop_sequences: Option<Vec<String>>,
    #[serde(default)]
    temperature: Option<f64>,
    #[serde(default)]
    top_p: Option<f64>,
    #[serde(default)]
    stream: Option<bool>,
    #[serde(default)]
    tools: Option<Vec<Value>>,
    #[serde(default)]
    tool_choice: Option<Value>,
}

#[derive(Debug, Clone, Deserialize)]
struct AnthropicMessageParam {
    role: String,
    content: Value,
}

pub async fn messages(
    State(state): State<AppState>,
    headers: HeaderMap,
    Extension(principal): Extension<AuthPrincipal>,
    Json(req): Json<Value>,
) -> Result<Response, GatewayError> {
    let anthropic: AnthropicMessageRequest = serde_json::from_value(req)
        .map_err(|e| GatewayError::BadRequest(format!("invalid Anthropic request body: {e}")))?;
    let input_tokens = estimate_anthropic_tokens(&anthropic);
    let openai_body = anthropic_to_openai(&anthropic)?;
    let prepared = prepare_chat_request(&state, &headers, &principal, openai_body)?;

    if prepared.streaming {
        let stream = run_anthropic_streaming(state, prepared, input_tokens).await?;
        Ok(stream.into_response())
    } else {
        let json = run_anthropic_buffered(state, prepared, input_tokens).await?;
        Ok(json.into_response())
    }
}

pub async fn count_tokens(Json(req): Json<Value>) -> Result<Json<Value>, GatewayError> {
    let anthropic: AnthropicMessageRequest = serde_json::from_value(req)
        .map_err(|e| GatewayError::BadRequest(format!("invalid Anthropic request body: {e}")))?;
    Ok(Json(serde_json::json!({
        "input_tokens": estimate_anthropic_tokens(&anthropic),
    })))
}

fn anthropic_to_openai(req: &AnthropicMessageRequest) -> Result<Value, GatewayError> {
    let max_tokens = req
        .max_tokens
        .ok_or_else(|| GatewayError::BadRequest("`max_tokens` is required".into()))?;
    if req.model.trim().is_empty() {
        return Err(GatewayError::BadRequest("`model` is required".into()));
    }

    let mut messages = Vec::<Value>::new();
    if let Some(system) = req.system.as_ref() {
        if let Some(text) = text_from_system(system)? {
            messages.push(serde_json::json!({
                "role": "system",
                "content": text,
            }));
        }
    }

    for msg in &req.messages {
        match msg.role.as_str() {
            "user" => append_user_message(&mut messages, &msg.content)?,
            "assistant" => append_assistant_message(&mut messages, &msg.content)?,
            other => {
                return Err(GatewayError::BadRequest(format!(
                    "unsupported Anthropic message role `{other}`"
                )));
            }
        }
    }

    let mut body = Map::new();
    body.insert("model".into(), Value::String(req.model.clone()));
    body.insert("messages".into(), Value::Array(messages));
    body.insert(
        "max_tokens".into(),
        Value::Number(serde_json::Number::from(max_tokens)),
    );
    body.insert("stream".into(), Value::Bool(req.stream.unwrap_or(false)));
    if let Some(temperature) = req.temperature {
        body.insert("temperature".into(), number_value(temperature)?);
    }
    if let Some(top_p) = req.top_p {
        body.insert("top_p".into(), number_value(top_p)?);
    }
    if let Some(stop) = req.stop_sequences.as_ref() {
        body.insert(
            "stop".into(),
            serde_json::to_value(stop).unwrap_or(Value::Null),
        );
    }
    if let Some(tools) = convert_tools(req.tools.as_deref())? {
        body.insert("tools".into(), tools);
    }
    if let Some(tool_choice) = convert_tool_choice(req.tool_choice.as_ref())? {
        body.insert("tool_choice".into(), tool_choice);
    }

    Ok(Value::Object(body))
}

fn number_value(v: f64) -> Result<Value, GatewayError> {
    serde_json::Number::from_f64(v)
        .map(Value::Number)
        .ok_or_else(|| GatewayError::BadRequest("numeric parameter was not finite".into()))
}

fn text_from_system(system: &Value) -> Result<Option<String>, GatewayError> {
    match system {
        Value::String(s) => Ok((!s.is_empty()).then(|| s.clone())),
        Value::Array(blocks) => {
            let mut parts = Vec::new();
            for block in blocks {
                parts.push(text_from_text_block(block, "system")?);
            }
            let text = parts.join("\n");
            Ok((!text.is_empty()).then_some(text))
        }
        Value::Object(_) => Ok(Some(text_from_text_block(system, "system")?)),
        _ => Err(GatewayError::BadRequest(
            "`system` must be a string or text block array".into(),
        )),
    }
}

fn append_user_message(messages: &mut Vec<Value>, content: &Value) -> Result<(), GatewayError> {
    match content {
        Value::String(text) => {
            messages.push(serde_json::json!({ "role": "user", "content": text }));
            Ok(())
        }
        Value::Array(blocks) => {
            let mut text_parts = Vec::new();
            for block in blocks {
                let block_type = block.get("type").and_then(Value::as_str).ok_or_else(|| {
                    GatewayError::BadRequest("content block missing `type`".into())
                })?;
                match block_type {
                    "text" => text_parts.push(text_from_text_block(block, "message")?),
                    "tool_result" => {
                        if !text_parts.is_empty() {
                            messages.push(serde_json::json!({
                                "role": "user",
                                "content": text_parts.join("\n"),
                            }));
                            text_parts.clear();
                        }
                        let tool_use_id = block
                            .get("tool_use_id")
                            .and_then(Value::as_str)
                            .ok_or_else(|| {
                                GatewayError::BadRequest(
                                    "`tool_result` block missing `tool_use_id`".into(),
                                )
                            })?;
                        let tool_content = block
                            .get("content")
                            .cloned()
                            .unwrap_or_else(|| Value::String(String::new()));
                        messages.push(serde_json::json!({
                            "role": "tool",
                            "tool_call_id": tool_use_id,
                            "content": text_from_tool_result_content(&tool_content)?,
                        }));
                    }
                    other => {
                        return Err(GatewayError::BadRequest(format!(
                            "Anthropic content block `{other}` is not supported"
                        )));
                    }
                }
            }
            if !text_parts.is_empty() {
                messages.push(serde_json::json!({
                    "role": "user",
                    "content": text_parts.join("\n"),
                }));
            }
            Ok(())
        }
        _ => Err(GatewayError::BadRequest(
            "message content must be a string or content block array".into(),
        )),
    }
}

fn append_assistant_message(
    messages: &mut Vec<Value>,
    content: &Value,
) -> Result<(), GatewayError> {
    match content {
        Value::String(text) => {
            messages.push(serde_json::json!({ "role": "assistant", "content": text }));
            Ok(())
        }
        Value::Array(blocks) => {
            let mut text_parts = Vec::new();
            let mut tool_calls = Vec::new();
            for block in blocks {
                let block_type = block.get("type").and_then(Value::as_str).ok_or_else(|| {
                    GatewayError::BadRequest("content block missing `type`".into())
                })?;
                match block_type {
                    "text" => text_parts.push(text_from_text_block(block, "message")?),
                    "tool_use" => {
                        let id = block.get("id").and_then(Value::as_str).ok_or_else(|| {
                            GatewayError::BadRequest("`tool_use` block missing `id`".into())
                        })?;
                        let name = block.get("name").and_then(Value::as_str).ok_or_else(|| {
                            GatewayError::BadRequest("`tool_use` block missing `name`".into())
                        })?;
                        let input = block
                            .get("input")
                            .cloned()
                            .unwrap_or_else(|| serde_json::json!({}));
                        tool_calls.push(serde_json::json!({
                            "id": id,
                            "type": "function",
                            "function": {
                                "name": name,
                                "arguments": serde_json::to_string(&input).unwrap_or_else(|_| "{}".to_string()),
                            }
                        }));
                    }
                    other => {
                        return Err(GatewayError::BadRequest(format!(
                            "Anthropic content block `{other}` is not supported"
                        )));
                    }
                }
            }
            let content = if text_parts.is_empty() {
                Value::Null
            } else {
                Value::String(text_parts.join("\n"))
            };
            let mut msg = serde_json::json!({
                "role": "assistant",
                "content": content,
            });
            if !tool_calls.is_empty() {
                msg["tool_calls"] = Value::Array(tool_calls);
            }
            messages.push(msg);
            Ok(())
        }
        _ => Err(GatewayError::BadRequest(
            "message content must be a string or content block array".into(),
        )),
    }
}

fn text_from_text_block(block: &Value, context: &str) -> Result<String, GatewayError> {
    if block.get("type").and_then(Value::as_str) != Some("text") {
        return Err(GatewayError::BadRequest(format!(
            "{context} block must be a text block"
        )));
    }
    block
        .get("text")
        .and_then(Value::as_str)
        .map(str::to_string)
        .ok_or_else(|| GatewayError::BadRequest("text block missing `text`".into()))
}

fn text_from_tool_result_content(content: &Value) -> Result<String, GatewayError> {
    match content {
        Value::String(text) => Ok(text.clone()),
        Value::Array(blocks) => {
            let mut parts = Vec::new();
            for block in blocks {
                let block_type = block.get("type").and_then(Value::as_str).unwrap_or("");
                match block_type {
                    "text" => parts.push(text_from_text_block(block, "tool_result")?),
                    other => {
                        return Err(GatewayError::BadRequest(format!(
                            "tool_result content block `{other}` is not supported"
                        )));
                    }
                }
            }
            Ok(parts.join("\n"))
        }
        other => Ok(other.to_string()),
    }
}

fn convert_tools(tools: Option<&[Value]>) -> Result<Option<Value>, GatewayError> {
    let Some(tools) = tools else {
        return Ok(None);
    };
    let mut out = Vec::new();
    for tool in tools {
        if let Some(tool_type) = tool.get("type").and_then(Value::as_str) {
            if tool_type != "custom" {
                return Err(GatewayError::BadRequest(format!(
                    "Anthropic server tool `{tool_type}` is not supported"
                )));
            }
        }
        let name = tool
            .get("name")
            .and_then(Value::as_str)
            .ok_or_else(|| GatewayError::BadRequest("tool definition missing `name`".into()))?;
        let description = tool
            .get("description")
            .and_then(Value::as_str)
            .unwrap_or_default();
        let input_schema = tool
            .get("input_schema")
            .cloned()
            .unwrap_or_else(|| serde_json::json!({ "type": "object" }));
        out.push(serde_json::json!({
            "type": "function",
            "function": {
                "name": name,
                "description": description,
                "parameters": input_schema,
            }
        }));
    }
    Ok(Some(Value::Array(out)))
}

fn convert_tool_choice(tool_choice: Option<&Value>) -> Result<Option<Value>, GatewayError> {
    let Some(tool_choice) = tool_choice else {
        return Ok(None);
    };
    let tool_choice_type = tool_choice
        .get("type")
        .and_then(Value::as_str)
        .ok_or_else(|| GatewayError::BadRequest("tool_choice missing `type`".into()))?;
    match tool_choice_type {
        "auto" => Ok(Some(Value::String("auto".into()))),
        "any" => Ok(Some(Value::String("required".into()))),
        "none" => Ok(Some(Value::String("none".into()))),
        "tool" => {
            let name = tool_choice
                .get("name")
                .and_then(Value::as_str)
                .ok_or_else(|| {
                    GatewayError::BadRequest("tool_choice tool missing `name`".into())
                })?;
            Ok(Some(serde_json::json!({
                "type": "function",
                "function": { "name": name },
            })))
        }
        other => Err(GatewayError::BadRequest(format!(
            "unsupported Anthropic tool_choice `{other}`"
        ))),
    }
}

async fn run_anthropic_buffered(
    state: AppState,
    prepared: PreparedChatRequest,
    input_tokens_estimate: u64,
) -> Result<Json<Value>, GatewayError> {
    let started = Instant::now();
    let model_id = prepared.catalog_model.id.clone();
    let max_retries = state.config.reliability.max_retries;
    let request_timeout = Duration::from_secs(state.config.reliability.request_timeout_seconds);
    let mut excluded = Vec::new();
    let mut tried = 0u32;
    let mut acc = OpenAiAccumulator::default();
    let mut first_token_at: Option<Instant> = None;

    loop {
        tried += 1;
        let cold_start_grace =
            single_supplier_large_cold_start_grace(&state, &prepared.catalog_model);
        let ttft_deadline = pre_first_token_deadline(&state, &prepared.catalog_model);
        let (mut rx, target_node, session_id) = pick_and_dispatch(
            &state,
            &prepared.catalog_model,
            &prepared.req_body,
            &excluded,
            Some(prepared.required_ctx),
            &prepared.preferred_node_ids,
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
                    acc.observe_chunk(&chunk);
                }
                Ok(Some(SessionEvent::Complete { tokens_out })) => {
                    if let Some(tokens_out) = tokens_out {
                        acc.reported_tokens = Some(tokens_out);
                    }
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

        if !completed && !got_first && !cold_start_grace {
            state
                .registry
                .quarantine(&target_node, state.config.reliability.quarantine_seconds);
        }

        if completed {
            settle_success(
                &state,
                &prepared.catalog_model,
                prepared.consumer.as_ref(),
                Some(target_node.as_str()),
                &acc,
            );
            record_success_metrics(&state, &model_id, started, first_token_at, &acc);
            return Ok(Json(build_anthropic_message(
                &model_id,
                &acc,
                input_tokens_estimate,
            )));
        }

        if retriable {
            if cold_start_grace {
                tokio::time::sleep(Duration::from_secs(2)).await;
                metrics::RETRIES_TOTAL
                    .with_label_values(&["single_supplier_cold_start_retry"])
                    .inc();
                continue;
            }
            state
                .registry
                .quarantine(&target_node, state.config.reliability.quarantine_seconds);
            excluded.push(target_node);
            metrics::RETRIES_TOTAL
                .with_label_values(&["anthropic_buffered_failure"])
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

async fn run_anthropic_streaming(
    state: AppState,
    prepared: PreparedChatRequest,
    input_tokens_estimate: u64,
) -> Result<Sse<impl Stream<Item = Result<Event, Infallible>>>, GatewayError> {
    let started = Instant::now();
    let model_id = prepared.catalog_model.id.clone();
    let stream = async_stream::stream! {
        let max_retries = state.config.reliability.max_retries;
        let request_timeout = Duration::from_secs(state.config.reliability.request_timeout_seconds);
        let mut excluded = Vec::new();
        let mut tried = 0u32;
        let mut acc = OpenAiAccumulator::default();
        let mut first_token_at: Option<Instant> = None;
        let mut served_by: Option<String> = None;
        let mut final_status = "error";
        let message_id = format!("msg_{}", Uuid::new_v4().simple());

        loop {
            tried += 1;
            let cold_start_grace = single_supplier_large_cold_start_grace(&state, &prepared.catalog_model);
            let ttft_deadline = pre_first_token_deadline(&state, &prepared.catalog_model);
            let dispatch = pick_and_dispatch(
                &state,
                &prepared.catalog_model,
                &prepared.req_body,
                &excluded,
                Some(prepared.required_ctx),
                &prepared.preferred_node_ids,
            )
            .await;

            let (mut rx, target_node, session_id) = match dispatch {
                Ok(v) => v,
                Err(e) => {
                    let status = error_to_status_label(&e);
                    metrics::REQUESTS_TOTAL.with_label_values(&[&model_id, status]).inc();
                    yield Ok(anthropic_error_event(&e));
                    return;
                }
            };

            info!(model = %model_id, device = %target_node, attempt = tried, "Anthropic streaming inference dispatched");
            let mut translator = AnthropicStreamTranslator::new(
                message_id.clone(),
                model_id.clone(),
                input_tokens_estimate,
            );
            let mut sent_message_start = false;

            let mut got_first = false;
            let mut retriable_failure = false;
            let mut completed = false;

            loop {
                let deadline = if got_first { request_timeout } else { ttft_deadline };
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
                        if !sent_message_start {
                            yield Ok(translator.message_start_event());
                            sent_message_start = true;
                        }
                        acc.observe_chunk(&chunk);
                        for event in translator.chunk_events(&chunk, &acc) {
                            yield Ok(event);
                        }
                    }
                    Ok(Some(SessionEvent::Complete { tokens_out })) => {
                        if let Some(tokens_out) = tokens_out {
                            acc.reported_tokens = Some(tokens_out);
                        }
                        completed = true;
                        final_status = "ok";
                        break;
                    }
                    Ok(Some(SessionEvent::Error { message, .. })) => {
                        warn!(device = %target_node, "upstream error: {}", message);
                        if !got_first && tried <= max_retries {
                            retriable_failure = true;
                        } else {
                            yield Ok(anthropic_error_event(&GatewayError::Upstream(message)));
                        }
                        break;
                    }
                    Ok(Some(SessionEvent::Disconnect(reason))) => {
                        warn!(device = %target_node, "upstream disconnect: {}", reason);
                        if !got_first && tried <= max_retries {
                            retriable_failure = true;
                        } else {
                            yield Ok(anthropic_error_event(&GatewayError::Upstream(reason)));
                        }
                        break;
                    }
                    Ok(None) => {
                        if !got_first && tried <= max_retries {
                            retriable_failure = true;
                        } else {
                            yield Ok(anthropic_error_event(&GatewayError::Upstream("channel closed before completion".into())));
                        }
                        break;
                    }
                    Err(_) => {
                        if !got_first && tried <= max_retries {
                            retriable_failure = true;
                        } else {
                            yield Ok(anthropic_error_event(&GatewayError::UpstreamTimeout));
                        }
                        break;
                    }
                }
            }

            state.relay.close_session(&target_node, &session_id);
            state.registry.dec_in_flight(&target_node);

            if !completed && !got_first && !cold_start_grace {
                state
                    .registry
                    .quarantine(&target_node, state.config.reliability.quarantine_seconds);
            }

            if completed {
                served_by = Some(target_node);
                if !sent_message_start {
                    yield Ok(translator.message_start_event());
                }
                for event in translator.finish_events(&acc, input_tokens_estimate) {
                    yield Ok(event);
                }
                break;
            }
            if !retriable_failure {
                break;
            }
            if cold_start_grace {
                tokio::time::sleep(Duration::from_secs(2)).await;
                metrics::RETRIES_TOTAL
                    .with_label_values(&["single_supplier_cold_start_retry"])
                    .inc();
                continue;
            }
            state
                .registry
                .quarantine(&target_node, state.config.reliability.quarantine_seconds);
            excluded.push(target_node);
            metrics::RETRIES_TOTAL
                .with_label_values(&["anthropic_stream_failure"])
                .inc();
        }

        if final_status == "ok" {
            settle_success(
                &state,
                &prepared.catalog_model,
                prepared.consumer.as_ref(),
                served_by.as_deref(),
                &acc,
            );
            record_success_metrics(&state, &model_id, started, first_token_at, &acc);
        }
        metrics::REQUESTS_TOTAL
            .with_label_values(&[&model_id, final_status])
            .inc();
        metrics::TOTAL_LATENCY_SECONDS
            .with_label_values(&[&model_id, final_status])
            .observe(started.elapsed().as_secs_f64());
    };

    Ok(Sse::new(stream)
        .keep_alive(axum::response::sse::KeepAlive::new().interval(Duration::from_secs(15))))
}

#[derive(Debug, Default)]
struct OpenAiAccumulator {
    text: String,
    tool_calls: BTreeMap<usize, ToolCallState>,
    finish_reason: Option<String>,
    usage: Option<Value>,
    tokens_out: u64,
    reported_tokens: Option<u32>,
}

impl OpenAiAccumulator {
    fn observe_chunk(&mut self, chunk: &Value) {
        if let Some(usage) = chunk.get("usage").filter(|u| !u.is_null()).cloned() {
            self.usage = Some(usage);
        }
        let Some(choice) = chunk.get("choices").and_then(|c| c.get(0)) else {
            return;
        };
        if let Some(finish_reason) = choice.get("finish_reason").and_then(Value::as_str) {
            self.finish_reason = Some(finish_reason.to_string());
        }
        if let Some(delta) = choice.get("delta") {
            if let Some(text) = delta.get("content").and_then(Value::as_str) {
                self.text.push_str(text);
                if !text.is_empty() {
                    self.tokens_out += 1;
                }
            }
            if let Some(tool_calls) = delta.get("tool_calls").and_then(Value::as_array) {
                self.merge_tool_calls(tool_calls);
            }
        }
        if let Some(message) = choice.get("message") {
            if let Some(text) = message.get("content").and_then(Value::as_str) {
                self.text.push_str(text);
            }
            if let Some(tool_calls) = message.get("tool_calls").and_then(Value::as_array) {
                self.merge_tool_calls(tool_calls);
            }
        }
    }

    fn merge_tool_calls(&mut self, tool_calls: &[Value]) {
        for (fallback_idx, call) in tool_calls.iter().enumerate() {
            let index = call
                .get("index")
                .and_then(Value::as_u64)
                .map(|i| i as usize)
                .unwrap_or(fallback_idx);
            let state = self.tool_calls.entry(index).or_default();
            if let Some(id) = call.get("id").and_then(Value::as_str) {
                state.id = Some(id.to_string());
            }
            if let Some(function) = call.get("function") {
                if let Some(name) = function.get("name").and_then(Value::as_str) {
                    state.name = Some(name.to_string());
                }
                if let Some(arguments) = function.get("arguments").and_then(Value::as_str) {
                    state.arguments.push_str(arguments);
                }
            }
        }
    }

    fn output_tokens(&self) -> u64 {
        self.usage
            .as_ref()
            .and_then(|u| u.get("completion_tokens").and_then(Value::as_u64))
            .or_else(|| self.reported_tokens.map(|t| t as u64))
            .unwrap_or(self.tokens_out)
            .max(1)
    }

    fn prompt_tokens(&self, fallback: u64) -> u64 {
        self.usage
            .as_ref()
            .and_then(|u| u.get("prompt_tokens").and_then(Value::as_u64))
            .unwrap_or(fallback)
    }

    fn has_tool_use(&self) -> bool {
        !self.tool_calls.is_empty()
    }
}

#[derive(Debug, Default)]
struct ToolCallState {
    id: Option<String>,
    name: Option<String>,
    arguments: String,
}

impl ToolCallState {
    fn anthropic_id(&self) -> String {
        self.id
            .clone()
            .unwrap_or_else(|| format!("toolu_{}", Uuid::new_v4().simple()))
    }

    fn anthropic_name(&self) -> String {
        self.name.clone().unwrap_or_else(|| "tool".to_string())
    }

    fn input(&self) -> Value {
        if self.arguments.trim().is_empty() {
            return serde_json::json!({});
        }
        serde_json::from_str(&self.arguments).unwrap_or_else(|_| serde_json::json!({}))
    }
}

struct AnthropicStreamTranslator {
    message_id: String,
    model_id: String,
    input_tokens: u64,
    next_content_index: usize,
    text_block_index: Option<usize>,
    tool_block_indexes: BTreeMap<usize, usize>,
}

impl AnthropicStreamTranslator {
    fn new(message_id: String, model_id: String, input_tokens: u64) -> Self {
        Self {
            message_id,
            model_id,
            input_tokens,
            next_content_index: 0,
            text_block_index: None,
            tool_block_indexes: BTreeMap::new(),
        }
    }

    fn message_start_event(&self) -> Event {
        sse(
            "message_start",
            serde_json::json!({
                "type": "message_start",
                "message": {
                    "id": self.message_id,
                    "type": "message",
                    "role": "assistant",
                    "model": self.model_id,
                    "content": [],
                    "stop_reason": null,
                    "stop_sequence": null,
                    "usage": {
                        "input_tokens": self.input_tokens,
                        "output_tokens": 0,
                    },
                }
            }),
        )
    }

    fn chunk_events(&mut self, chunk: &Value, acc: &OpenAiAccumulator) -> Vec<Event> {
        let mut events = Vec::new();
        let Some(choice) = chunk.get("choices").and_then(|c| c.get(0)) else {
            return events;
        };
        let Some(delta) = choice.get("delta") else {
            return events;
        };

        if let Some(text) = delta.get("content").and_then(Value::as_str) {
            if !text.is_empty() {
                if self.text_block_index.is_none() {
                    let index = self.next_content_index;
                    self.next_content_index += 1;
                    self.text_block_index = Some(index);
                    events.push(sse(
                        "content_block_start",
                        serde_json::json!({
                            "type": "content_block_start",
                            "index": index,
                            "content_block": { "type": "text", "text": "" },
                        }),
                    ));
                }
                events.push(sse(
                    "content_block_delta",
                    serde_json::json!({
                        "type": "content_block_delta",
                        "index": self.text_block_index.unwrap_or(0),
                        "delta": { "type": "text_delta", "text": text },
                    }),
                ));
            }
        }

        if let Some(tool_calls) = delta.get("tool_calls").and_then(Value::as_array) {
            if let Some(text_index) = self.text_block_index.take() {
                events.push(sse(
                    "content_block_stop",
                    serde_json::json!({
                        "type": "content_block_stop",
                        "index": text_index,
                    }),
                ));
            }
            for call in tool_calls {
                let call_index = call
                    .get("index")
                    .and_then(Value::as_u64)
                    .map(|i| i as usize)
                    .unwrap_or(0);
                let Some(state) = acc.tool_calls.get(&call_index) else {
                    continue;
                };
                let mut block_index = self.tool_block_indexes.get(&call_index).copied();
                if block_index.is_none() && state.name.is_some() {
                    let new_index = self.next_content_index;
                    block_index = Some(new_index);
                    self.next_content_index += 1;
                    self.tool_block_indexes.insert(call_index, new_index);
                    events.push(sse(
                        "content_block_start",
                        serde_json::json!({
                            "type": "content_block_start",
                            "index": new_index,
                            "content_block": {
                                "type": "tool_use",
                                "id": state.anthropic_id(),
                                "name": state.anthropic_name(),
                                "input": {},
                            },
                        }),
                    ));
                }
                if let Some(arguments_delta) = call
                    .get("function")
                    .and_then(|f| f.get("arguments"))
                    .and_then(Value::as_str)
                {
                    if !arguments_delta.is_empty() {
                        events.push(sse(
                            "content_block_delta",
                            serde_json::json!({
                                "type": "content_block_delta",
                                "index": block_index.unwrap_or(0),
                                "delta": {
                                    "type": "input_json_delta",
                                    "partial_json": arguments_delta,
                                },
                            }),
                        ));
                    }
                }
            }
        }

        events
    }

    fn finish_events(&mut self, acc: &OpenAiAccumulator, input_tokens_fallback: u64) -> Vec<Event> {
        let mut events = Vec::new();
        if let Some(text_index) = self.text_block_index.take() {
            events.push(sse(
                "content_block_stop",
                serde_json::json!({
                    "type": "content_block_stop",
                    "index": text_index,
                }),
            ));
        }
        for (tool_index, state) in &acc.tool_calls {
            let index = match self.tool_block_indexes.get(tool_index).copied() {
                Some(index) => index,
                None => {
                    let index = self.next_content_index;
                    self.next_content_index += 1;
                    self.tool_block_indexes.insert(*tool_index, index);
                    events.push(sse(
                        "content_block_start",
                        serde_json::json!({
                            "type": "content_block_start",
                            "index": index,
                            "content_block": {
                                "type": "tool_use",
                                "id": state.anthropic_id(),
                                "name": state.anthropic_name(),
                                "input": {},
                            },
                        }),
                    ));
                    if !state.arguments.is_empty() {
                        events.push(sse(
                            "content_block_delta",
                            serde_json::json!({
                                "type": "content_block_delta",
                                "index": index,
                                "delta": {
                                    "type": "input_json_delta",
                                    "partial_json": state.arguments.clone(),
                                },
                            }),
                        ));
                    }
                    index
                }
            };
            events.push(sse(
                "content_block_stop",
                serde_json::json!({
                    "type": "content_block_stop",
                    "index": index,
                }),
            ));
        }
        events.push(sse(
            "message_delta",
            serde_json::json!({
                "type": "message_delta",
                "delta": {
                    "stop_reason": anthropic_stop_reason(acc),
                    "stop_sequence": null,
                },
                "usage": {
                    "input_tokens": acc.prompt_tokens(input_tokens_fallback),
                    "output_tokens": acc.output_tokens(),
                },
            }),
        ));
        events.push(sse(
            "message_stop",
            serde_json::json!({ "type": "message_stop" }),
        ));
        events
    }
}

fn build_anthropic_message(
    model_id: &str,
    acc: &OpenAiAccumulator,
    input_tokens_fallback: u64,
) -> Value {
    let mut content = Vec::new();
    if !acc.text.is_empty() {
        content.push(serde_json::json!({
            "type": "text",
            "text": acc.text.clone(),
        }));
    }
    for tool in acc.tool_calls.values() {
        content.push(serde_json::json!({
            "type": "tool_use",
            "id": tool.anthropic_id(),
            "name": tool.anthropic_name(),
            "input": tool.input(),
        }));
    }

    serde_json::json!({
        "id": format!("msg_{}", Uuid::new_v4().simple()),
        "type": "message",
        "role": "assistant",
        "model": model_id,
        "content": content,
        "stop_reason": anthropic_stop_reason(acc),
        "stop_sequence": null,
        "usage": {
            "input_tokens": acc.prompt_tokens(input_tokens_fallback),
            "output_tokens": acc.output_tokens(),
        },
    })
}

fn anthropic_stop_reason(acc: &OpenAiAccumulator) -> &'static str {
    if acc.has_tool_use() {
        return "tool_use";
    }
    match acc.finish_reason.as_deref() {
        Some("length") => "max_tokens",
        Some("stop_sequence") => "stop_sequence",
        Some("tool_calls") => "tool_use",
        _ => "end_turn",
    }
}

fn settle_success(
    state: &AppState,
    catalog_model: &CatalogModel,
    consumer: Option<&ledger::ConsumerPrincipal>,
    provider: Option<&str>,
    acc: &OpenAiAccumulator,
) {
    let (Some(consumer), Some(provider), Some(pool)) = (consumer, provider, state.db.as_ref())
    else {
        return;
    };
    let cost = ledger::cost_credits(
        acc.prompt_tokens(0),
        acc.output_tokens(),
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
        consumer,
        Some(provider),
        &online,
        cost,
        &request_id,
        &catalog_model.id,
    ) {
        warn!("settle_request failed: {}", e);
    }
}

fn record_success_metrics(
    state: &AppState,
    model_id: &str,
    started: Instant,
    first_token_at: Option<Instant>,
    acc: &OpenAiAccumulator,
) {
    metrics::REQUESTS_TOTAL
        .with_label_values(&[model_id, "ok"])
        .inc();
    metrics::TOTAL_LATENCY_SECONDS
        .with_label_values(&[model_id, "ok"])
        .observe(started.elapsed().as_secs_f64());
    metrics::TOKENS_OUT_TOTAL
        .with_label_values(&[model_id])
        .inc_by(acc.output_tokens() as f64);
    if let Some(first_token_at) = first_token_at {
        let ttft_ms = first_token_at.duration_since(started).as_millis() as u32;
        let total_ms = started.elapsed().as_millis() as u64;
        let gen_ms = total_ms.saturating_sub(ttft_ms as u64);
        state
            .model_metrics
            .record(model_id, ttft_ms, Some(acc.output_tokens()), gen_ms);
    }
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
    let reliability = &state.config.reliability;
    if single_supplier_large_cold_start_grace(state, catalog_model) {
        Duration::from_secs(reliability.request_timeout_seconds)
    } else if is_large(catalog_model.params_b) {
        Duration::from_secs(reliability.ttft_deadline_seconds)
    } else {
        Duration::from_secs(
            reliability
                .small_ttft_deadline_seconds
                .min(reliability.ttft_deadline_seconds),
        )
    }
}

fn anthropic_error_event(err: &GatewayError) -> Event {
    let error_type = match err {
        GatewayError::BadRequest(_) => "invalid_request_error",
        GatewayError::Unauthorized(_) => "authentication_error",
        GatewayError::InsufficientCredits { .. } | GatewayError::BudgetExhausted => "billing_error",
        GatewayError::ModelNotFound(_) => "not_found_error",
        GatewayError::NoEligibleDevice(_) => "overloaded_error",
        _ => "api_error",
    };
    sse(
        "error",
        serde_json::json!({
            "type": "error",
            "error": {
                "type": error_type,
                "message": err.to_string(),
            }
        }),
    )
}

fn sse(event: &'static str, data: Value) -> Event {
    Event::default().event(event).data(data.to_string())
}

fn estimate_anthropic_tokens(req: &AnthropicMessageRequest) -> u64 {
    let mut bytes = req.model.len();
    if let Some(system) = req.system.as_ref() {
        bytes += system.to_string().len();
    }
    for message in &req.messages {
        bytes += message.role.len();
        bytes += message.content.to_string().len();
    }
    if let Some(tools) = req.tools.as_ref() {
        for tool in tools {
            bytes += tool.to_string().len();
        }
    }
    (bytes as u64).div_ceil(4) + 32
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn converts_text_and_system_to_openai_chat() {
        let req: AnthropicMessageRequest = serde_json::from_value(serde_json::json!({
            "model": "teale/auto",
            "max_tokens": 256,
            "system": "You are terse.",
            "messages": [
                { "role": "user", "content": [{ "type": "text", "text": "hi" }] }
            ],
            "stream": true
        }))
        .unwrap();

        let openai = anthropic_to_openai(&req).unwrap();
        assert_eq!(openai["model"], "teale/auto");
        assert_eq!(openai["stream"], true);
        assert_eq!(openai["messages"][0]["role"], "system");
        assert_eq!(openai["messages"][1]["content"], "hi");
    }

    #[test]
    fn converts_tools_and_tool_results() {
        let req: AnthropicMessageRequest = serde_json::from_value(serde_json::json!({
            "model": "moonshotai/kimi-k2.6",
            "max_tokens": 128,
            "tools": [{
                "name": "lookup",
                "description": "Lookup a thing",
                "input_schema": { "type": "object", "properties": { "q": { "type": "string" } } }
            }],
            "tool_choice": { "type": "tool", "name": "lookup" },
            "messages": [
                {
                    "role": "assistant",
                    "content": [{
                        "type": "tool_use",
                        "id": "toolu_1",
                        "name": "lookup",
                        "input": { "q": "teale" }
                    }]
                },
                {
                    "role": "user",
                    "content": [{
                        "type": "tool_result",
                        "tool_use_id": "toolu_1",
                        "content": "done"
                    }]
                }
            ]
        }))
        .unwrap();

        let openai = anthropic_to_openai(&req).unwrap();
        assert_eq!(openai["tools"][0]["type"], "function");
        assert_eq!(
            openai["tool_choice"]["function"]["name"],
            Value::String("lookup".into())
        );
        assert_eq!(openai["messages"][0]["tool_calls"][0]["id"], "toolu_1");
        assert_eq!(openai["messages"][1]["role"], "tool");
        assert_eq!(openai["messages"][1]["tool_call_id"], "toolu_1");
    }

    #[test]
    fn rejects_server_tools_and_images() {
        let req: AnthropicMessageRequest = serde_json::from_value(serde_json::json!({
            "model": "teale/auto",
            "max_tokens": 64,
            "tools": [{ "type": "web_search_20250305", "name": "web_search" }],
            "messages": [{ "role": "user", "content": "hi" }]
        }))
        .unwrap();
        assert!(anthropic_to_openai(&req).is_err());

        let req: AnthropicMessageRequest = serde_json::from_value(serde_json::json!({
            "model": "teale/auto",
            "max_tokens": 64,
            "messages": [{
                "role": "user",
                "content": [{ "type": "image", "source": { "type": "base64", "data": "x" } }]
            }]
        }))
        .unwrap();
        assert!(anthropic_to_openai(&req).is_err());
    }

    #[test]
    fn accumulates_openai_tool_calls_as_anthropic_tool_use() {
        let mut acc = OpenAiAccumulator::default();
        acc.observe_chunk(&serde_json::json!({
            "choices": [{
                "delta": {
                    "tool_calls": [{
                        "index": 0,
                        "id": "call_1",
                        "function": { "name": "lookup", "arguments": "{\"q\":" }
                    }]
                }
            }]
        }));
        acc.observe_chunk(&serde_json::json!({
            "choices": [{
                "delta": {
                    "tool_calls": [{
                        "index": 0,
                        "function": { "arguments": "\"teale\"}" }
                    }]
                },
                "finish_reason": "tool_calls"
            }]
        }));

        let message = build_anthropic_message("teale/auto", &acc, 12);
        assert_eq!(message["stop_reason"], "tool_use");
        assert_eq!(message["content"][0]["type"], "tool_use");
        assert_eq!(message["content"][0]["input"]["q"], "teale");
    }
}
