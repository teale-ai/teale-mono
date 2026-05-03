//! Outbound HTTP client for OpenAI-compatible providers.
//!
//! Design notes:
//! - The request body is forwarded **verbatim** with the `model` field
//!   rewritten to whatever slug the provider advertises in `provider_models`.
//!   Tool-calling, JSON mode, and multimodal payloads pass through unchanged.
//! - Streaming flips on `stream: true`; we forward each raw SSE `data:` line
//!   to the caller's mpsc sink so the chat handler doesn't fork its
//!   downstream code path.
//! - Usage tokens are scraped from the final SSE chunk (OpenAI puts a
//!   `usage` field on the last delta when `stream_options.include_usage` is
//!   set) or from the non-stream JSON body's `usage` field.
//! - SSE keep-alive comments (`:keepalive`) are dropped — they keep the
//!   connection alive but aren't model output.

use std::time::Instant;

use serde_json::Value;
use tokio::sync::mpsc;

use super::{ProviderError, UsageReport};

/// Resolves the `auth_secret_ref` (env var name) to the actual secret. Errors
/// out fast if unset, matching the existing `GATEWAY_TOKENS` posture.
fn resolve_secret(auth_secret_ref: &str) -> Result<String, ProviderError> {
    std::env::var(auth_secret_ref).map_err(|_| {
        ProviderError::Invalid(format!(
            "auth_secret_ref `{}` not set in environment",
            auth_secret_ref
        ))
    })
}

fn render_auth_value(header_name: &str, secret: &str) -> String {
    if header_name.eq_ignore_ascii_case("authorization") && !secret.starts_with("Bearer ") {
        format!("Bearer {}", secret)
    } else {
        secret.to_string()
    }
}

/// Buffered (non-streaming) dispatch. Used when `stream: false` or when the
/// caller wants the entire JSON response back at once.
pub async fn dispatch_buffered(
    http: &reqwest::Client,
    base_url: &str,
    auth_header_name: &str,
    auth_secret_ref: &str,
    body: Value,
) -> Result<(Value, UsageReport), ProviderError> {
    let secret = resolve_secret(auth_secret_ref)?;
    let auth_value = render_auth_value(auth_header_name, &secret);

    let url = endpoint(base_url, "/chat/completions");
    let started = Instant::now();
    let resp = http
        .post(&url)
        .header(auth_header_name, auth_value)
        .header("content-type", "application/json")
        .json(&body)
        .send()
        .await
        .map_err(|e| ProviderError::Network(e.to_string()))?;

    let status = resp.status().as_u16();
    if !resp.status().is_success() {
        let body = resp.text().await.unwrap_or_default();
        return Err(ProviderError::Http {
            status,
            message: body,
        });
    }
    let json: Value = resp
        .json()
        .await
        .map_err(|e| ProviderError::Invalid(e.to_string()))?;

    let usage = scrape_usage(&json);
    let total_ms = started.elapsed().as_millis() as u64;

    Ok((
        json,
        UsageReport {
            prompt_tokens: usage.0,
            completion_tokens: usage.1,
            ttft_ms: None,
            total_ms: Some(total_ms),
        },
    ))
}

/// Streaming dispatch. Forwards SSE lines (verbatim, `data: {...}`-prefixed)
/// to the supplied sink; resolves to a `UsageReport` once the upstream
/// stream ends with `data: [DONE]`. The sink may be closed by the caller to
/// abort early — we treat a closed channel as a clean cancellation.
pub async fn dispatch_streaming(
    http: &reqwest::Client,
    base_url: &str,
    auth_header_name: &str,
    auth_secret_ref: &str,
    mut body: Value,
    sink: mpsc::Sender<String>,
) -> Result<UsageReport, ProviderError> {
    let secret = resolve_secret(auth_secret_ref)?;
    let auth_value = render_auth_value(auth_header_name, &secret);

    // Make sure stream=true so the provider actually streams. Some providers
    // return a 400 if both stream=true and stream_options.include_usage are
    // missing, but the safe default is to ask for usage on the last chunk.
    if let Some(obj) = body.as_object_mut() {
        obj.insert("stream".into(), Value::Bool(true));
        let stream_opts = obj
            .entry("stream_options".to_string())
            .or_insert_with(|| Value::Object(serde_json::Map::new()));
        if let Some(opts) = stream_opts.as_object_mut() {
            opts.insert("include_usage".into(), Value::Bool(true));
        }
    }

    let url = endpoint(base_url, "/chat/completions");
    let started = Instant::now();
    let mut first_token_at: Option<Instant> = None;

    let resp = http
        .post(&url)
        .header(auth_header_name, auth_value)
        .header("content-type", "application/json")
        .header("accept", "text/event-stream")
        .json(&body)
        .send()
        .await
        .map_err(|e| ProviderError::Network(e.to_string()))?;

    let status = resp.status().as_u16();
    if !resp.status().is_success() {
        let body = resp.text().await.unwrap_or_default();
        return Err(ProviderError::Http {
            status,
            message: body,
        });
    }

    let mut prompt_tokens: u32 = 0;
    let mut completion_tokens: u32 = 0;
    let mut buffer = String::new();
    let mut byte_stream = resp.bytes_stream();
    use futures_util::StreamExt;
    while let Some(chunk) = byte_stream.next().await {
        let chunk = chunk.map_err(|e| ProviderError::MidStream(e.to_string()))?;
        let s = std::str::from_utf8(&chunk).map_err(|e| ProviderError::Invalid(e.to_string()))?;
        buffer.push_str(s);
        // SSE events are `\n\n`-delimited; process whole events.
        while let Some(idx) = buffer.find("\n\n") {
            let event = buffer[..idx].to_string();
            buffer.drain(..idx + 2);
            for line in event.lines() {
                if line.starts_with(':') {
                    continue; // SSE comment / keep-alive
                }
                if let Some(rest) = line.strip_prefix("data: ") {
                    if rest.trim() == "[DONE]" {
                        // Forward the terminator so the downstream SSE
                        // formatter can close cleanly.
                        let _ = sink.send("data: [DONE]\n\n".to_string()).await;
                        let total_ms = started.elapsed().as_millis() as u64;
                        let ttft_ms = first_token_at.map(|t| (t - started).as_millis() as u64);
                        return Ok(UsageReport {
                            prompt_tokens,
                            completion_tokens,
                            ttft_ms,
                            total_ms: Some(total_ms),
                        });
                    }
                    // Try to scrape usage on the final delta (OpenAI streams
                    // a chunk with `usage` populated when include_usage=true).
                    if let Ok(parsed) = serde_json::from_str::<Value>(rest) {
                        if first_token_at.is_none() && has_content(&parsed) {
                            first_token_at = Some(Instant::now());
                        }
                        let (p, c) = scrape_usage(&parsed);
                        if p > 0 {
                            prompt_tokens = p;
                        }
                        if c > 0 {
                            completion_tokens = c;
                        }
                    }
                    let formatted = format!("data: {}\n\n", rest);
                    if sink.send(formatted).await.is_err() {
                        // Client disconnected; bail cleanly.
                        let total_ms = started.elapsed().as_millis() as u64;
                        return Ok(UsageReport {
                            prompt_tokens,
                            completion_tokens,
                            ttft_ms: first_token_at.map(|t| (t - started).as_millis() as u64),
                            total_ms: Some(total_ms),
                        });
                    }
                }
            }
        }
    }
    // Stream ended without a [DONE] terminator. Treat as mid-stream error.
    Err(ProviderError::MidStream(
        "upstream closed before [DONE]".into(),
    ))
}

fn endpoint(base_url: &str, path: &str) -> String {
    let trimmed = base_url.trim_end_matches('/');
    if trimmed.ends_with("/chat/completions") || trimmed.ends_with("/v1/messages") {
        // Operator already specified the full inference URL. Take it verbatim.
        trimmed.to_string()
    } else {
        format!("{}{}", trimmed, path)
    }
}

fn has_content(parsed: &Value) -> bool {
    parsed
        .get("choices")
        .and_then(|v| v.as_array())
        .map(|arr| {
            arr.iter().any(|c| {
                c.get("delta")
                    .and_then(|d| d.get("content"))
                    .and_then(|s| s.as_str())
                    .map(|s| !s.is_empty())
                    .unwrap_or(false)
            })
        })
        .unwrap_or(false)
}

fn scrape_usage(parsed: &Value) -> (u32, u32) {
    let usage = parsed.get("usage");
    let p = usage
        .and_then(|u| u.get("prompt_tokens"))
        .and_then(|v| v.as_u64())
        .unwrap_or(0) as u32;
    let c = usage
        .and_then(|u| u.get("completion_tokens"))
        .and_then(|v| v.as_u64())
        .unwrap_or(0) as u32;
    (p, c)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn endpoint_appends_when_base_is_root() {
        assert_eq!(
            endpoint("https://api.example.com/v1", "/chat/completions"),
            "https://api.example.com/v1/chat/completions"
        );
    }

    #[test]
    fn endpoint_preserves_full_url() {
        let full = "https://api.example.com/v1/chat/completions";
        assert_eq!(endpoint(full, "/chat/completions"), full);
    }

    #[test]
    fn auth_header_bearer_only_when_authorization() {
        assert_eq!(
            render_auth_value("Authorization", "sk-abc"),
            "Bearer sk-abc"
        );
        assert_eq!(render_auth_value("X-Api-Key", "sk-abc"), "sk-abc");
        // Don't double-prefix if the secret already contains Bearer.
        assert_eq!(
            render_auth_value("Authorization", "Bearer sk-abc"),
            "Bearer sk-abc"
        );
    }

    #[test]
    fn scrape_usage_reads_openai_shape() {
        let v: Value =
            serde_json::from_str(r#"{"usage":{"prompt_tokens":10,"completion_tokens":42}}"#)
                .unwrap();
        assert_eq!(scrape_usage(&v), (10, 42));
    }
}
