//! Gateway configuration.
//!
//! Loaded from `gateway.toml` (path configurable via `--config`) plus env
//! overrides for secrets (GATEWAY_TOKENS). Models catalog loaded from a
//! separate `models.yaml` so operators can edit model metadata without
//! touching runtime settings.

use serde::Deserialize;

#[derive(Debug, Deserialize, Clone)]
pub struct Config {
    #[serde(default = "default_bind")]
    pub bind: String,
    #[serde(default = "default_display_name")]
    pub display_name: String,
    pub relay: RelayConfig,
    #[serde(default = "default_identity_path")]
    pub identity_path: String,
    #[serde(default = "default_models_yaml")]
    pub models_yaml: String,
    #[serde(default)]
    pub scheduler: SchedulerConfig,
    #[serde(default)]
    pub reliability: ReliabilityConfig,
}

#[derive(Debug, Deserialize, Clone)]
pub struct RelayConfig {
    #[serde(default = "default_relay_url")]
    pub url: String,
}

#[derive(Debug, Deserialize, Clone)]
pub struct SchedulerConfig {
    #[serde(default = "default_max_queue_depth")]
    pub max_queue_depth: u32,
    /// Penalty multiplier applied when a model needs swap-loading (0.0-1.0).
    #[serde(default = "default_swap_penalty")]
    pub swap_penalty: f64,
    /// Weight for tokens-per-second in the score (higher = more aggressive).
    #[serde(default = "default_tps_weight")]
    pub tps_weight: f64,
    /// Minimum healthy devices required per model before listing it.
    #[serde(default)]
    pub per_model_floor: PerModelFloor,
}

impl Default for SchedulerConfig {
    fn default() -> Self {
        Self {
            max_queue_depth: default_max_queue_depth(),
            swap_penalty: default_swap_penalty(),
            tps_weight: default_tps_weight(),
            per_model_floor: PerModelFloor::default(),
        }
    }
}

#[derive(Debug, Deserialize, Clone)]
pub struct PerModelFloor {
    /// Minimum devices for models ≥70B params.
    #[serde(default = "default_floor_large")]
    pub large: u32,
    /// Minimum devices for models <70B params.
    #[serde(default = "default_floor_small")]
    pub small: u32,
}

impl Default for PerModelFloor {
    fn default() -> Self {
        Self {
            large: default_floor_large(),
            small: default_floor_small(),
        }
    }
}

#[derive(Debug, Deserialize, Clone)]
pub struct ReliabilityConfig {
    #[serde(default = "default_request_timeout")]
    pub request_timeout_seconds: u64,
    #[serde(default = "default_ttft_deadline")]
    pub ttft_deadline_seconds: u64,
    #[serde(default = "default_max_retries")]
    pub max_retries: u32,
    #[serde(default = "default_heartbeat_stale")]
    pub heartbeat_stale_seconds: u64,
    #[serde(default = "default_quarantine")]
    pub quarantine_seconds: u64,
    #[serde(default = "default_discover_interval")]
    pub discover_interval_seconds: u64,
}

impl Default for ReliabilityConfig {
    fn default() -> Self {
        Self {
            request_timeout_seconds: default_request_timeout(),
            ttft_deadline_seconds: default_ttft_deadline(),
            max_retries: default_max_retries(),
            heartbeat_stale_seconds: default_heartbeat_stale(),
            quarantine_seconds: default_quarantine(),
            discover_interval_seconds: default_discover_interval(),
        }
    }
}

fn default_bind() -> String {
    "0.0.0.0:8080".to_string()
}
fn default_display_name() -> String {
    "teale-gateway".to_string()
}
fn default_relay_url() -> String {
    "wss://relay.teale.com/ws".to_string()
}
fn default_identity_path() -> String {
    "/data/gateway-identity.key".to_string()
}
fn default_models_yaml() -> String {
    "models.yaml".to_string()
}
fn default_max_queue_depth() -> u32 {
    8
}
fn default_swap_penalty() -> f64 {
    0.3
}
fn default_tps_weight() -> f64 {
    1.0
}
fn default_floor_large() -> u32 {
    3
}
fn default_floor_small() -> u32 {
    2
}
fn default_request_timeout() -> u64 {
    300
}
fn default_ttft_deadline() -> u64 {
    10
}
fn default_max_retries() -> u32 {
    1
}
fn default_heartbeat_stale() -> u64 {
    30
}
fn default_quarantine() -> u64 {
    30
}
fn default_discover_interval() -> u64 {
    10
}

impl Config {
    pub fn load(path: &str) -> anyhow::Result<Self> {
        if !std::path::Path::new(path).exists() {
            // Allow running with defaults only (handy for dev).
            return Ok(Self::defaults());
        }
        let content = std::fs::read_to_string(path)?;
        Ok(toml::from_str(&content)?)
    }

    pub fn defaults() -> Self {
        Self {
            bind: default_bind(),
            display_name: default_display_name(),
            relay: RelayConfig { url: default_relay_url() },
            identity_path: default_identity_path(),
            models_yaml: default_models_yaml(),
            scheduler: SchedulerConfig::default(),
            reliability: ReliabilityConfig::default(),
        }
    }
}
