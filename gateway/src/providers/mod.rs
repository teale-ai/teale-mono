//! Centralized 3rd-party inference provider marketplace.
//!
//! Providers register via the admin API, declare their model menu with
//! USD-string per-token pricing (mirroring OpenRouter's `/v1/models` schema),
//! and expose an OpenAI-compatible inference endpoint. The gateway routes
//! demand to them as a peer of the distributed fleet; settlement pays 95% to
//! the provider's wallet (`provider_wallets`) and 5% to Teale ops.

pub mod anthropic_compat;
pub mod health;
pub mod openai_compat;
pub mod registry;

pub use registry::{
    ProviderModelRow, ProviderRegistry, ProviderRow, ProviderStatus, ProviderWireFormat,
};

use std::sync::Arc;

use serde::{Deserialize, Serialize};

/// Stable identifier for an entry in the candidate list. Mirrors the OpenAI
/// `model` slug exactly; the request body is forwarded verbatim with this as
/// the `model` field, so providers see the same model id Teale advertises.
pub type ModelId = String;

/// The wire-format expected from a centralized provider's inference endpoint.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum WireFormat {
    /// `POST {base_url}/chat/completions` with the OpenAI Chat Completions
    /// schema. Streaming via SSE. The default for the long tail.
    Openai,
    /// `POST {base_url}/v1/messages` with the Anthropic schema. Reuses the
    /// converter that already exists in `handlers/messages.rs`.
    Anthropic,
}

impl WireFormat {
    pub fn as_str(&self) -> &'static str {
        match self {
            WireFormat::Openai => "openai",
            WireFormat::Anthropic => "anthropic",
        }
    }

    pub fn parse(s: &str) -> Option<Self> {
        match s {
            "openai" => Some(WireFormat::Openai),
            "anthropic" => Some(WireFormat::Anthropic),
            _ => None,
        }
    }
}

/// Outcome of a provider dispatch — the fields the ledger needs to settle and
/// the metrics module needs to update health.
#[derive(Debug, Clone, Default)]
pub struct UsageReport {
    pub prompt_tokens: u32,
    pub completion_tokens: u32,
    pub ttft_ms: Option<u64>,
    pub total_ms: Option<u64>,
}

#[derive(Debug, thiserror::Error)]
pub enum ProviderError {
    #[error("provider returned HTTP {status}: {message}")]
    Http { status: u16, message: String },
    #[error("provider request failed mid-stream: {0}")]
    MidStream(String),
    #[error("network error: {0}")]
    Network(String),
    #[error("invalid response from provider: {0}")]
    Invalid(String),
    #[error("provider unavailable")]
    Unavailable,
}

impl ProviderError {
    /// OpenRouter's classification: 401/402/404/500+/mid-stream count against
    /// uptime; 400/413/429/403 don't (those are user/policy errors, not the
    /// provider's fault). Used by the health tracker.
    pub fn counts_against_uptime(&self) -> bool {
        match self {
            ProviderError::Http { status, .. } => {
                matches!(*status, 401 | 402 | 404) || *status >= 500
            }
            ProviderError::MidStream(_) | ProviderError::Network(_) => true,
            ProviderError::Invalid(_) | ProviderError::Unavailable => true,
        }
    }
}

/// Application-side handle to the providers subsystem. Cloned into AppState.
#[derive(Clone)]
pub struct ProvidersHandle {
    pub registry: Arc<ProviderRegistry>,
    pub health: Arc<health::HealthTracker>,
    pub http: reqwest::Client,
}

impl ProvidersHandle {
    pub fn new(registry: Arc<ProviderRegistry>) -> Self {
        let http = reqwest::Client::builder()
            .pool_idle_timeout(std::time::Duration::from_secs(60))
            .build()
            .expect("reqwest client");
        Self {
            registry,
            health: Arc::new(health::HealthTracker::new()),
            http,
        }
    }

    /// Test fixture: builds an empty provider registry backed by an in-memory
    /// SQLite DB. The handle has no providers loaded so the centralized
    /// dispatch path always returns `None` (fall-through to local supply),
    /// preserving the existing test behavior for callers that don't care
    /// about provider routing.
    pub fn empty_for_test() -> Self {
        let pool = crate::db::open_in_memory().expect("in-memory db");
        let registry = ProviderRegistry::load(pool).expect("empty provider registry");
        Self::new(registry)
    }
}
