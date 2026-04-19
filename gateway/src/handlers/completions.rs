//! POST /v1/completions — legacy text-completion alias.
//!
//! OpenRouter's provider form asks for both `/completions` and
//! `/chat/completions` URLs. Rather than maintaining a parallel inference
//! pipeline we wrap the legacy body into a single-message chat request,
//! dispatch through the existing chat handler, and transform the response
//! back to the legacy shape (`choices[].text` / `text_completion` object
//! types instead of `message`/`chat.completion`).
//!
//! Accepts both `prompt: string` and `prompt: [strings]`; for the array
//! form we concatenate with a single newline. Passes through all other
//! OpenAI parameters (temperature, top_p, max_tokens, stop, stream, seed,
//! frequency_penalty, presence_penalty). Tool-calling / response_format
//! are not supported on the legacy endpoint — they're chat-only features
//! and we reject them here rather than silently drop them.

use axum::{
    extract::State,
    response::{IntoResponse, Response},
    Extension, Json,
};
use serde_json::Value;

use crate::auth::AuthPrincipal;
use crate::error::GatewayError;
use crate::handlers::chat::chat_completions;
use crate::state::AppState;

pub async fn completions(
    State(state): State<AppState>,
    Extension(principal): Extension<AuthPrincipal>,
    Json(req): Json<Value>,
) -> Result<Response, GatewayError> {
    let obj = req
        .as_object()
        .ok_or_else(|| GatewayError::BadRequest("request body must be a JSON object".into()))?;

    let prompt_value = obj
        .get("prompt")
        .ok_or_else(|| GatewayError::BadRequest("`prompt` is required".into()))?;

    let prompt = match prompt_value {
        Value::String(s) => s.clone(),
        Value::Array(parts) => parts
            .iter()
            .map(|v| v.as_str().unwrap_or_default())
            .collect::<Vec<_>>()
            .join("\n"),
        _ => {
            return Err(GatewayError::BadRequest(
                "`prompt` must be a string or array of strings".into(),
            ))
        }
    };

    // Reject chat-only features to avoid surprising the caller.
    for forbidden in ["tools", "tool_choice", "response_format"] {
        if obj.contains_key(forbidden) {
            return Err(GatewayError::BadRequest(format!(
                "`{}` is not supported on /v1/completions; use /v1/chat/completions instead",
                forbidden
            )));
        }
    }

    // Rewrite to a chat-shape request: single user message carrying the prompt.
    let mut chat_body = req.clone();
    let chat_obj = chat_body.as_object_mut().unwrap();
    chat_obj.remove("prompt");
    chat_obj.insert(
        "messages".into(),
        serde_json::json!([
            { "role": "user", "content": prompt }
        ]),
    );

    // Delegate to the chat handler (which handles auth, catalog lookup,
    // fleet floor, dispatch, retries, and streaming-usage emission).
    let response =
        chat_completions(State(state), Extension(principal), Json(chat_body)).await?;

    // Transform the chat response back to legacy /v1/completions shape.
    // For streaming (SSE) we leave the content mostly as-is — OR's
    // /completions clients generally accept either shape, and rewriting
    // every streamed chunk line-by-line here would duplicate logic. The
    // buffered path gets a proper shape swap below.
    let (parts, body) = response.into_parts();
    let is_sse = parts
        .headers
        .get(axum::http::header::CONTENT_TYPE)
        .and_then(|v| v.to_str().ok())
        .is_some_and(|s| s.starts_with("text/event-stream"));

    if is_sse {
        return Ok(Response::from_parts(parts, body).into_response());
    }

    let bytes = axum::body::to_bytes(body, 1024 * 1024)
        .await
        .map_err(|e| GatewayError::Upstream(format!("read response body: {}", e)))?;
    let mut json: Value = serde_json::from_slice(&bytes)
        .map_err(|e| GatewayError::Upstream(format!("parse upstream body: {}", e)))?;
    if let Some(obj) = json.as_object_mut() {
        obj.insert("object".into(), Value::String("text_completion".into()));
        if let Some(choices) = obj.get_mut("choices").and_then(|v| v.as_array_mut()) {
            for choice in choices.iter_mut() {
                if let Some(ch) = choice.as_object_mut() {
                    let text = ch
                        .remove("message")
                        .and_then(|m| {
                            m.get("content")
                                .and_then(|c| c.as_str().map(|s| s.to_string()))
                        })
                        .unwrap_or_default();
                    ch.insert("text".into(), Value::String(text));
                }
            }
        }
    }
    Ok(Json(json).into_response())
}
