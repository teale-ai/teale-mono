//! Outbound dispatch for Anthropic-shaped providers (`POST /v1/messages`).
//!
//! v1 stub: not yet wired. The path lands here when a provider is registered
//! with `wire_format = anthropic`; we return `ProviderError::Unavailable` so
//! the router falls through to the next candidate. Full integration will
//! reuse the OpenAI ↔ Anthropic converter that already lives in
//! `handlers/messages.rs` (PR #88).

use serde_json::Value;
use tokio::sync::mpsc;

use super::{ProviderError, UsageReport};

#[allow(clippy::too_many_arguments)]
pub async fn dispatch_buffered(
    _http: &reqwest::Client,
    _base_url: &str,
    _auth_header_name: &str,
    _auth_secret_ref: &str,
    _body: Value,
) -> Result<(Value, UsageReport), ProviderError> {
    Err(ProviderError::Unavailable)
}

#[allow(clippy::too_many_arguments)]
pub async fn dispatch_streaming(
    _http: &reqwest::Client,
    _base_url: &str,
    _auth_header_name: &str,
    _auth_secret_ref: &str,
    _body: Value,
    _sink: mpsc::Sender<String>,
) -> Result<UsageReport, ProviderError> {
    Err(ProviderError::Unavailable)
}
