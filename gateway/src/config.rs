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
    #[serde(default)]
    pub synthetic_probes: SyntheticProbeConfig,
    #[serde(default)]
    pub solana: SolanaConfig,
    #[serde(default)]
    pub fleet: FleetConfig,
    #[serde(default)]
    pub apmhelp: ApmhelpConfig,
}

/// Fleet membership policy (#263). The relay is a global namespace any
/// client can join, and discover responses feed the gateway's device
/// registry directly: without a membership check, any peer advertising
/// available=true becomes eligible supply and can be dialed for
/// inference, pulling prompts onto unknown hardware. When
/// allowed_node_ids is non-empty, only those node ids may enter the
/// registry; empty preserves the previous accept-all behavior (dev).
#[derive(Debug, Deserialize, Clone, Default)]
pub struct FleetConfig {
    #[serde(default)]
    pub allowed_node_ids: Vec<String>,
}

impl FleetConfig {
    pub fn allows(&self, node_id: &str) -> bool {
        self.allowed_node_ids.is_empty() || self.allowed_node_ids.iter().any(|id| id == node_id)
    }
}

/// apmhelp employee-supply lane (#272). Requests from members or staff of
/// the configured PIN may draw on the confirmed-employee supply set,
/// strictly preferred over general fleet supply. Employee machines are
/// admitted to the registry but are NEVER eligible for the default lane -
/// they serve apmhelp-PIN traffic only, as free supply (an apmhelp perk;
/// no supplier fee split per Taylor 2026-09-07). Confirmation is manual
/// per machine: relay registration is unauthenticated (#252), so display
/// names prove nothing; an id enters employee_node_ids only on Taylor's
/// word (TICO 1766594... confirmed 2026-09-07, advertises no models yet).
/// Empty pin_id disables the lane (supply set stays inert).
#[derive(Debug, Deserialize, Clone, Default)]
pub struct ApmhelpConfig {
    #[serde(default)]
    pub pin_id: String,
    #[serde(default)]
    pub employee_node_ids: Vec<String>,
}

impl ApmhelpConfig {
    pub fn is_employee(&self, node_id: &str) -> bool {
        self.employee_node_ids.iter().any(|id| id == node_id)
    }

    pub fn lane_enabled(&self) -> bool {
        !self.pin_id.is_empty()
    }
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
    #[serde(default = "default_small_ttft_deadline")]
    pub small_ttft_deadline_seconds: u64,
    #[serde(default = "default_max_retries")]
    pub max_retries: u32,
    #[serde(default = "default_heartbeat_stale")]
    pub heartbeat_stale_seconds: u64,
    #[serde(default = "default_quarantine")]
    pub quarantine_seconds: u64,
    #[serde(default = "default_discover_interval")]
    pub discover_interval_seconds: u64,
    /// How long a departed (peerLeft) device's models stay listed before
    /// the registry removes it for real. Absorbs transient relay flaps.
    #[serde(default = "default_departed_grace")]
    pub departed_grace_seconds: u64,
    /// Post-start warmup: nodes re-announce on their own refresh cadence
    /// (up to ~40s), so a freshly restarted gateway briefly sees an empty
    /// registry. During this window an unresolved model is treated as a
    /// not-yet-re-announced supplier (retriable 503) instead of a hard 404.
    #[serde(default = "default_registry_warmup")]
    pub registry_warmup_seconds: u64,
    /// Heavy-hold admission (#247): refuse to co-schedule two heavy
    /// requests on one node (retriable 503) instead of letting them
    /// starve each other's decode into the stream cap.
    #[serde(default = "default_heavy_hold")]
    pub heavy_hold: bool,
    /// A request is heavy when its estimated prompt is at least this
    /// many tokens OR its requested max_tokens is at least
    /// heavy_hold_max_tokens.
    #[serde(default = "default_heavy_hold_prompt_tokens")]
    pub heavy_hold_prompt_tokens: u32,
    #[serde(default = "default_heavy_hold_max_tokens")]
    pub heavy_hold_max_tokens: u32,
    /// Extra first-token allowance for a LIGHT request admitted beside
    /// an in-flight heavy: its prefill waits on the heavy's decode, so
    /// a slow first token is contention on a live device, not device
    /// failure. Applied on top of the (capped) prompt-scaled deadline
    /// and signals the caller to skip quarantine for that attempt.
    #[serde(default = "default_heavy_co_resident_ttft_bonus")]
    pub heavy_co_resident_ttft_bonus_seconds: u64,
    /// Per-conversation supplier stickiness: follow-up turns prefer the
    /// node that served the conversation before, so llama.cpp slot KV is
    /// reused instead of re-prefilling the whole context. Seconds an
    /// affinity stays valid; 0 disables.
    #[serde(default = "default_convo_stickiness_ttl")]
    pub convo_stickiness_ttl_seconds: u64,
    /// A heavy hold older than this is stale by definition: the stream cap
    /// ends every heavy session well within it, so a hold past the TTL is
    /// one whose close path never ran (a leaked hold wedged 512g8 for ~75
    /// min on 2026-09-08 - slots idle, every heavy refused). admit()
    /// expires it lazily, counts the expiry, and lets the new heavy in.
    #[serde(default = "default_heavy_hold_ttl")]
    pub heavy_hold_ttl_seconds: u64,
}

impl Default for ReliabilityConfig {
    fn default() -> Self {
        Self {
            request_timeout_seconds: default_request_timeout(),
            ttft_deadline_seconds: default_ttft_deadline(),
            small_ttft_deadline_seconds: default_small_ttft_deadline(),
            max_retries: default_max_retries(),
            heartbeat_stale_seconds: default_heartbeat_stale(),
            quarantine_seconds: default_quarantine(),
            discover_interval_seconds: default_discover_interval(),
            departed_grace_seconds: default_departed_grace(),
            registry_warmup_seconds: default_registry_warmup(),
            heavy_hold: default_heavy_hold(),
            heavy_hold_prompt_tokens: default_heavy_hold_prompt_tokens(),
            heavy_hold_max_tokens: default_heavy_hold_max_tokens(),
            heavy_co_resident_ttft_bonus_seconds: default_heavy_co_resident_ttft_bonus(),
            convo_stickiness_ttl_seconds: default_convo_stickiness_ttl(),
            heavy_hold_ttl_seconds: default_heavy_hold_ttl(),
        }
    }
}

#[derive(Debug, Deserialize, Clone)]
pub struct SyntheticProbeConfig {
    #[serde(default = "default_synthetic_probe_enabled")]
    pub enabled: bool,
    #[serde(default = "default_synthetic_probe_interval")]
    pub interval_seconds: u64,
    #[serde(default = "default_synthetic_probe_max_tokens")]
    pub max_tokens: u32,
}

impl Default for SyntheticProbeConfig {
    fn default() -> Self {
        Self {
            enabled: default_synthetic_probe_enabled(),
            interval_seconds: default_synthetic_probe_interval(),
            max_tokens: default_synthetic_probe_max_tokens(),
        }
    }
}

#[derive(Debug, Deserialize, Clone)]
pub struct SolanaConfig {
    #[serde(default = "default_solana_rpc_url")]
    pub rpc_url: String,
    #[serde(default = "default_solana_usdc_mint")]
    pub usdc_mint: String,
    #[serde(default = "default_solana_commitment")]
    pub commitment: String,
    #[serde(default = "default_solana_request_timeout_seconds")]
    pub request_timeout_seconds: u64,
    #[serde(default = "default_solana_max_supported_transaction_version")]
    pub max_supported_transaction_version: u8,
    #[serde(default = "default_solana_treasury_address")]
    pub treasury_address: String,
    #[serde(default = "default_solana_withdrawal_fee_bps")]
    pub withdrawal_fee_bps: u16,
    /// Wallet allowed to publish ledger-anchor memos. Empty disables anchor
    /// finalization (prepare still works, so ops can inspect the memo first).
    #[serde(default = "default_solana_anchor_authority")]
    pub anchor_authority_address: String,
}

impl Default for SolanaConfig {
    fn default() -> Self {
        Self {
            rpc_url: default_solana_rpc_url(),
            usdc_mint: default_solana_usdc_mint(),
            commitment: default_solana_commitment(),
            request_timeout_seconds: default_solana_request_timeout_seconds(),
            max_supported_transaction_version: default_solana_max_supported_transaction_version(),
            treasury_address: default_solana_treasury_address(),
            withdrawal_fee_bps: default_solana_withdrawal_fee_bps(),
            anchor_authority_address: default_solana_anchor_authority(),
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
fn default_small_ttft_deadline() -> u64 {
    8
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
    60
}
fn default_departed_grace() -> u64 {
    180
}
fn default_registry_warmup() -> u64 {
    60
}

fn default_heavy_hold() -> bool {
    true
}

fn default_heavy_hold_ttl() -> u64 {
    // above the 1800s stream cap: a live heavy always finishes (or dies at
    // the cap) before its hold can look stale
    1900
}

/// 30k prompt tokens: CCC heavy steps run 36-100k; ordinary chat and
/// small agent prompts sit well below. Cache-warm prompts still count -
/// their decode is what starves.
fn default_heavy_hold_prompt_tokens() -> u32 {
    30_000
}

/// 4k requested output tokens: every observed cap death asked for (and
/// partially produced) 6k+; short answers finish even beside a heavy.
fn default_heavy_hold_max_tokens() -> u32 {
    4096
}

/// 180s on top of the normal TTFT deadline: Citadel's contention samples
/// show co-resident first tokens of 123-216s on 512g8 behind a heavy's
/// cold prefill, over the 120s base deadline.
fn default_convo_stickiness_ttl() -> u64 {
    1800
}

fn default_heavy_co_resident_ttft_bonus() -> u64 {
    180
}
fn default_synthetic_probe_enabled() -> bool {
    false
}
fn default_synthetic_probe_interval() -> u64 {
    1800
}
fn default_synthetic_probe_max_tokens() -> u32 {
    16
}
fn default_solana_rpc_url() -> String {
    "https://api.mainnet-beta.solana.com".to_string()
}
fn default_solana_usdc_mint() -> String {
    "EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v".to_string()
}
fn default_solana_commitment() -> String {
    "finalized".to_string()
}
fn default_solana_request_timeout_seconds() -> u64 {
    15
}
fn default_solana_max_supported_transaction_version() -> u8 {
    0
}
fn default_solana_treasury_address() -> String {
    "HwGY6RJKzAxoRjeqWYvmnZGu4AC8oyEzqFrpGgqAKzhA".to_string()
}
fn default_solana_anchor_authority() -> String {
    String::new()
}
fn default_solana_withdrawal_fee_bps() -> u16 {
    180
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
            relay: RelayConfig {
                url: default_relay_url(),
            },
            identity_path: default_identity_path(),
            models_yaml: default_models_yaml(),
            scheduler: SchedulerConfig::default(),
            reliability: ReliabilityConfig::default(),
            synthetic_probes: SyntheticProbeConfig::default(),
            solana: SolanaConfig::default(),
            fleet: FleetConfig::default(),
            apmhelp: ApmhelpConfig::default(),
        }
    }
}
