//! POST /v1/responses — OpenAI Responses API shim over the chat pipeline.
//!
//! Newer agent tooling (codex-cli >= Feb 2026 removed `wire_api = "chat"`,
//! and the trend line says more will follow) only speaks the Responses API.
//! Our inference path is chat/completions end to end, so this handler
//! translates: Responses request -> ChatCompletionRequest -> the existing
//! `chat_completions` handler (centralized dispatch, scheduler, cascade,
//! ledger, all of it) -> Responses objects/SSE events back out.
//!
//! Scope: the stateless subset agent CLIs actually use - `instructions`,
//! `input` (string or message/function items), `tools` (function type),
//! `max_output_tokens`, `temperature`/`top_p`, streaming + non-streaming.
//! Reasoning items are dropped; image parts are rejected (text-only fleet).

use std::collections::VecDeque;
use std::convert::Infallible;

use axum::{
    extract::State,
    http::HeaderMap,
    response::{sse::Event, IntoResponse, Response, Sse},
    Extension, Json,
};
use futures_util::StreamExt;
use serde_json::{json, Value};
use uuid::Uuid;

use crate::auth::AuthPrincipal;
use crate::error::GatewayError;
use crate::state::AppState;

pub async fn responses(
    State(state): State<AppState>,
    headers: HeaderMap,
    Extension(principal): Extension<AuthPrincipal>,
    Json(req): Json<Value>,
) -> Result<Response, GatewayError> {
    let streaming = req.get("stream").and_then(Value::as_bool).unwrap_or(false);
    let chat_body = translate_request(&req)?;
    let response =
        super::chat::chat_completions(State(state), headers, Extension(principal), Json(chat_body))
            .await?;
    if streaming {
        Ok(translate_stream(response))
    } else {
        translate_buffered(response).await
    }
}

// MARK: - Request translation

fn translate_request(req: &Value) -> Result<Value, GatewayError> {
    let model = req
        .get("model")
        .and_then(Value::as_str)
        .ok_or_else(|| GatewayError::BadRequest("`model` is required".to_string()))?;

    let mut messages: Vec<Value> = Vec::new();
    if let Some(instructions) = req.get("instructions").and_then(Value::as_str) {
        if !instructions.is_empty() {
            messages.push(json!({"role": "system", "content": instructions}));
        }
    }
    match req.get("input") {
        None | Some(Value::Null) => {}
        Some(Value::String(text)) => {
            messages.push(json!({"role": "user", "content": text}));
        }
        Some(Value::Array(items)) => {
            for item in items {
                translate_input_item(item, &mut messages)?;
            }
        }
        Some(_) => {
            return Err(GatewayError::BadRequest(
                "`input` must be a string or an array".to_string(),
            ));
        }
    }
    if messages.is_empty() {
        return Err(GatewayError::BadRequest(
            "`input` (or `instructions`) must produce at least one message".to_string(),
        ));
    }

    let mut chat = json!({
        "model": model,
        "messages": messages,
    });
    let map = chat.as_object_mut().expect("object");
    if let Some(v) = req.get("max_output_tokens").and_then(Value::as_u64) {
        map.insert("max_tokens".to_string(), json!(v as u32));
    }
    for key in ["temperature", "top_p", "stop"] {
        if let Some(v) = req.get(key) {
            map.insert(key.to_string(), v.clone());
        }
    }
    if let Some(stream) = req.get("stream") {
        map.insert("stream".to_string(), stream.clone());
    }
    if let Some(tools) = req.get("tools").and_then(Value::as_array) {
        let translated: Vec<Value> = tools
            .iter()
            .filter(|t| t.get("type").and_then(Value::as_str) == Some("function"))
            .map(|t| {
                json!({
                    "type": "function",
                    "function": {
                        "name": t.get("name"),
                        "description": t.get("description"),
                        "parameters": t.get("parameters"),
                    }
                })
            })
            .collect();
        if !translated.is_empty() {
            map.insert("tools".to_string(), json!(translated));
            if let Some(choice) = req.get("tool_choice") {
                map.insert("tool_choice".to_string(), choice.clone());
            }
        }
    }
    // The usage chunk gives `response.completed` real token counts.
    if req.get("stream").and_then(Value::as_bool).unwrap_or(false) {
        map.insert("stream_options".to_string(), json!({"include_usage": true}));
    }
    Ok(chat)
}

fn translate_input_item(item: &Value, messages: &mut Vec<Value>) -> Result<(), GatewayError> {
    let item_type = item.get("type").and_then(Value::as_str);
    match item_type {
        Some("message") | None if item.get("role").is_some() => {
            let role = item.get("role").and_then(Value::as_str).unwrap_or("user");
            let content = match item.get("content") {
                Some(Value::String(text)) => text.clone(),
                Some(Value::Array(parts)) => {
                    let mut text = String::new();
                    for part in parts {
                        match part.get("type").and_then(Value::as_str) {
                            Some("input_text") | Some("output_text") => {
                                if let Some(t) = part.get("text").and_then(Value::as_str) {
                                    text.push_str(t);
                                }
                            }
                            Some("input_image") | Some("image_url") => {
                                return Err(GatewayError::BadRequest(
                                    "image inputs are not supported yet".to_string(),
                                ));
                            }
                            _ => {}
                        }
                    }
                    text
                }
                _ => String::new(),
            };
            messages.push(json!({"role": role, "content": content}));
        }
        Some("function_call") => {
            let call_id = item
                .get("call_id")
                .or_else(|| item.get("id"))
                .and_then(Value::as_str)
                .unwrap_or_default();
            messages.push(json!({
                "role": "assistant",
                "content": null,
                "tool_calls": [{
                    "id": call_id,
                    "type": "function",
                    "function": {
                        "name": item.get("name"),
                        "arguments": item.get("arguments").and_then(Value::as_str).unwrap_or(""),
                    }
                }]
            }));
        }
        Some("function_call_output") => {
            let call_id = item
                .get("call_id")
                .and_then(Value::as_str)
                .unwrap_or_default();
            let output = match item.get("output") {
                Some(Value::String(s)) => s.clone(),
                Some(other) => other.to_string(),
                None => String::new(),
            };
            messages.push(json!({
                "role": "tool",
                "tool_call_id": call_id,
                "content": output,
            }));
        }
        Some("reasoning") => { /* provider reasoning is not re-submittable */ }
        _ => { /* unknown item types are ignored, not fatal */ }
    }
    Ok(())
}

// MARK: - Response objects

fn message_item(item_id: &str, status: &str, text: &str) -> Value {
    json!({
        "type": "message",
        "id": item_id,
        "status": status,
        "role": "assistant",
        "content": [{"type": "output_text", "text": text, "annotations": []}],
    })
}

fn response_object(
    resp_id: &str,
    model: &str,
    created_at: u64,
    status: &str,
    output: Vec<Value>,
    usage: Option<&Value>,
) -> Value {
    let mut obj = json!({
        "id": resp_id,
        "object": "response",
        "created_at": created_at,
        "status": status,
        "model": model,
        "output": output,
        "parallel_tool_calls": true,
        "tool_choice": "auto",
        "tools": [],
    });
    if let Some(u) = usage {
        obj["usage"] = json!({
            "input_tokens": u.get("prompt_tokens").and_then(Value::as_u64).unwrap_or(0),
            "output_tokens": u.get("completion_tokens").and_then(Value::as_u64).unwrap_or(0),
            "total_tokens": u.get("total_tokens").and_then(Value::as_u64).unwrap_or(0),
        });
    }
    obj
}

// MARK: - Non-streaming

async fn translate_buffered(response: Response) -> Result<Response, GatewayError> {
    let (parts, body) = response.into_parts();
    let bytes = axum::body::to_bytes(body, 16 * 1024 * 1024)
        .await
        .map_err(|e| GatewayError::Upstream(format!("reading chat response body: {e}")))?;
    // Non-JSON or error bodies pass through untouched (status preserved).
    let Ok(chat) = serde_json::from_slice::<Value>(&bytes) else {
        return Ok(Response::from_parts(parts, axum::body::Body::from(bytes)));
    };
    if !parts.status.is_success() || chat.get("error").is_some() {
        return Ok(Response::from_parts(parts, axum::body::Body::from(bytes)));
    }

    let resp_id = format!("resp_{}", Uuid::new_v4().simple());
    let item_id = format!("msg_{}", Uuid::new_v4().simple());
    let created = chat
        .get("created")
        .and_then(Value::as_u64)
        .unwrap_or_else(|| {
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .map(|d| d.as_secs())
                .unwrap_or(0)
        });
    let model = chat
        .get("model")
        .and_then(Value::as_str)
        .unwrap_or_default()
        .to_string();

    let mut output: Vec<Value> = Vec::new();
    let choice = chat
        .get("choices")
        .and_then(Value::as_array)
        .and_then(|c| c.first());
    let message = choice.and_then(|c| c.get("message"));
    let text = message
        .and_then(|m| m.get("content"))
        .and_then(Value::as_str)
        .unwrap_or_default()
        .to_string();
    let tool_calls = message
        .and_then(|m| m.get("tool_calls"))
        .and_then(Value::as_array);
    if !text.is_empty() || tool_calls.is_none() {
        output.push(message_item(&item_id, "completed", &text));
    }
    if let Some(calls) = tool_calls {
        for call in calls {
            output.push(json!({
                "type": "function_call",
                "id": format!("fc_{}", Uuid::new_v4().simple()),
                "call_id": call.get("id").and_then(Value::as_str).unwrap_or_default(),
                "name": call.pointer("/function/name").and_then(Value::as_str).unwrap_or_default(),
                "arguments": call.pointer("/function/arguments").and_then(Value::as_str).unwrap_or_default(),
                "status": "completed",
            }));
        }
    }

    let obj = response_object(
        &resp_id,
        &model,
        created,
        "completed",
        output,
        chat.get("usage"),
    );
    Ok(Json(obj).into_response())
}

// MARK: - Streaming

struct StreamState {
    resp_id: String,
    item_id: String,
    model: String,
    created_at: u64,
    started: bool,
    saw_role: bool,
    text: String,
    usage: Option<Value>,
    finished: bool,
    out: VecDeque<Event>,
}

impl StreamState {
    fn new() -> Self {
        Self {
            resp_id: format!("resp_{}", Uuid::new_v4().simple()),
            item_id: format!("msg_{}", Uuid::new_v4().simple()),
            model: String::new(),
            created_at: std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .map(|d| d.as_secs())
                .unwrap_or(0),
            started: false,
            saw_role: false,
            text: String::new(),
            usage: None,
            finished: false,
            out: VecDeque::new(),
        }
    }

    fn start(&mut self, chunk: &Value) {
        self.started = true;
        if let Some(model) = chunk.get("model").and_then(Value::as_str) {
            self.model = model.to_string();
        }
        if let Some(created) = chunk.get("created").and_then(Value::as_u64) {
            self.created_at = created;
        }
        self.out.push_back(
            Event::default().event("response.created").data(
                json!({
                    "type": "response.created",
                    "response": response_object(&self.resp_id, &self.model, self.created_at, "in_progress", vec![], None),
                })
                .to_string(),
            ),
        );
        self.out.push_back(
            Event::default().event("response.output_item.added").data(
                json!({
                    "type": "response.output_item.added",
                    "output_index": 0,
                    "item": message_item(&self.item_id, "in_progress", ""),
                })
                .to_string(),
            ),
        );
        self.out.push_back(
            Event::default().event("response.content_part.added").data(
                json!({
                    "type": "response.content_part.added",
                    "item_id": self.item_id,
                    "output_index": 0,
                    "content_index": 0,
                    "part": {"type": "output_text", "text": "", "annotations": []},
                })
                .to_string(),
            ),
        );
    }

    fn handle_chunk(&mut self, chunk: &Value) {
        if !self.started {
            self.start(chunk);
        }
        if let Some(usage) = chunk.get("usage") {
            if !usage.is_null() {
                self.usage = Some(usage.clone());
            }
        }
        let Some(choice) = chunk
            .get("choices")
            .and_then(Value::as_array)
            .and_then(|c| c.first())
        else {
            return;
        };
        if let Some(delta) = choice.get("delta") {
            if delta.get("role").is_some() {
                self.saw_role = true;
            }
            if let Some(content) = delta.get("content").and_then(Value::as_str) {
                if !content.is_empty() {
                    self.text.push_str(content);
                    self.out.push_back(
                        Event::default().event("response.output_text.delta").data(
                            json!({
                                "type": "response.output_text.delta",
                                "item_id": self.item_id,
                                "output_index": 0,
                                "content_index": 0,
                                "delta": content,
                            })
                            .to_string(),
                        ),
                    );
                }
            }
        }
        if choice.get("finish_reason").is_some_and(|f| !f.is_null()) {
            self.finished = true;
        }
    }

    fn finalize(&mut self) {
        if !self.started {
            self.start(&Value::Null);
        }
        let full_text = std::mem::take(&mut self.text);
        self.out.push_back(
            Event::default().event("response.content_part.done").data(
                json!({
                    "type": "response.content_part.done",
                    "item_id": self.item_id,
                    "output_index": 0,
                    "content_index": 0,
                    "part": {"type": "output_text", "text": full_text, "annotations": []},
                })
                .to_string(),
            ),
        );
        self.out.push_back(
            Event::default().event("response.output_item.done").data(
                json!({
                    "type": "response.output_item.done",
                    "output_index": 0,
                    "item": message_item(&self.item_id, "completed", &full_text),
                })
                .to_string(),
            ),
        );
        let status = if self.finished {
            "completed"
        } else {
            "incomplete"
        };
        self.out.push_back(
            Event::default().event("response.completed").data(
                json!({
                    "type": "response.completed",
                    "response": response_object(
                        &self.resp_id,
                        &self.model,
                        self.created_at,
                        status,
                        vec![message_item(&self.item_id, "completed", &full_text)],
                        self.usage.as_ref(),
                    ),
                })
                .to_string(),
            ),
        );
    }
}

fn translate_stream(response: Response) -> Response {
    let byte_stream = response.into_body().into_data_stream();
    let stream = futures_util::stream::unfold(
        (byte_stream, Vec::<u8>::new(), StreamState::new(), false),
        |(mut bytes_in, mut buf, mut st, mut done)| async move {
            loop {
                if let Some(event) = st.out.pop_front() {
                    return Some((Ok::<Event, Infallible>(event), (bytes_in, buf, st, done)));
                }
                if done {
                    return None;
                }
                // Pull the next upstream chunk; on clean end, finalize.
                match bytes_in.next().await {
                    Some(Ok(data)) => {
                        buf.extend_from_slice(&data);
                    }
                    Some(Err(_)) | None => {
                        st.finalize();
                        done = true;
                        continue;
                    }
                }
                // Process every complete SSE frame in the buffer.
                while let Some(pos) = find_subslice(&buf, b"\n\n") {
                    let frame: Vec<u8> = buf.drain(..pos + 2).collect();
                    for line in frame.split(|&b| b == b'\n') {
                        let line = strip_cr(line);
                        let Some(payload) = line.strip_prefix(b"data:") else {
                            continue;
                        };
                        let payload = trim_left(payload);
                        if payload == b"[DONE]" {
                            st.finalize();
                            done = true;
                            break;
                        }
                        if let Ok(chunk) = serde_json::from_slice::<Value>(payload) {
                            if chunk.get("error").is_some() {
                                st.out.push_back(
                                    Event::default()
                                        .event("error")
                                        .data(String::from_utf8_lossy(payload)),
                                );
                            } else {
                                st.handle_chunk(&chunk);
                            }
                        }
                    }
                }
            }
        },
    );
    Sse::new(stream).into_response()
}

fn find_subslice(haystack: &[u8], needle: &[u8]) -> Option<usize> {
    haystack.windows(needle.len()).position(|w| w == needle)
}

fn strip_cr(line: &[u8]) -> &[u8] {
    line.strip_suffix(b"\r").unwrap_or(line)
}

fn trim_left(mut s: &[u8]) -> &[u8] {
    while s.first() == Some(&b' ') {
        s = &s[1..];
    }
    s
}

// MARK: - Tests

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn translates_simple_string_input() {
        let req = json!({
            "model": "teale/auto",
            "instructions": "Be terse.",
            "input": "hello",
        });
        let chat = translate_request(&req).expect("translates");
        assert_eq!(chat["model"], "teale/auto");
        let messages = chat["messages"].as_array().unwrap();
        assert_eq!(messages.len(), 2);
        assert_eq!(messages[0]["role"], "system");
        assert_eq!(messages[0]["content"], "Be terse.");
        assert_eq!(messages[1]["role"], "user");
        assert_eq!(messages[1]["content"], "hello");
    }

    #[test]
    fn translates_item_array_with_function_output() {
        let req = json!({
            "model": "qwen/qwen3.6-35b-a3b",
            "input": [
                {"type": "message", "role": "user", "content": [{"type": "input_text", "text": "what is 2+2?"}]},
                {"type": "function_call", "call_id": "call_1", "name": "calc", "arguments": "{\"expr\":\"2+2\"}"},
                {"type": "function_call_output", "call_id": "call_1", "output": "4"}
            ],
            "max_output_tokens": 128
        });
        let chat = translate_request(&req).expect("translates");
        let messages = chat["messages"].as_array().unwrap();
        assert_eq!(messages.len(), 3);
        assert_eq!(messages[0]["content"], "what is 2+2?");
        assert_eq!(messages[1]["tool_calls"][0]["id"], "call_1");
        assert_eq!(messages[2]["role"], "tool");
        assert_eq!(messages[2]["tool_call_id"], "call_1");
        assert_eq!(chat["max_tokens"], 128);
    }

    #[test]
    fn translates_function_tools_to_chat_shape() {
        let req = json!({
            "model": "m",
            "input": "hi",
            "tools": [{"type": "function", "name": "f", "description": "d", "parameters": {"type": "object"}}]
        });
        let chat = translate_request(&req).expect("translates");
        assert_eq!(chat["tools"][0]["function"]["name"], "f");
    }

    #[test]
    fn rejects_missing_model_and_empty_input() {
        assert!(translate_request(&json!({"input": "hi"})).is_err());
        assert!(translate_request(&json!({"model": "m"})).is_err());
    }

    #[test]
    fn stream_state_emits_delta_sequence() {
        let mut st = StreamState::new();
        st.handle_chunk(&json!({
            "id": "chatcmpl-1", "model": "qwen", "created": 1,
            "choices": [{"delta": {"role": "assistant", "content": ""}}]
        }));
        st.handle_chunk(&json!({
            "choices": [{"delta": {"content": "Hel"}}]
        }));
        st.handle_chunk(&json!({
            "choices": [{"delta": {"content": "lo"}, "finish_reason": "stop"}],
            "usage": {"prompt_tokens": 3, "completion_tokens": 2, "total_tokens": 5}
        }));
        st.finalize();
        let events: Vec<String> = st.out.iter().map(|e| format!("{e:?}")).collect();
        let joined = events.join("\n");
        assert!(joined.contains("response.created"));
        assert!(joined.contains("response.output_text.delta"));
        assert!(joined.contains("response.completed"));
        assert!(joined.contains("Hello"));
        assert!(joined.contains("input_tokens"));
        assert!(joined.contains(":3"));
    }
}
