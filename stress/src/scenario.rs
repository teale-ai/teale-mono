//! Declarative scenario files — TOML.
//!
//! Example:
//! ```toml
//! name = "steady_state_30min"
//! duration_seconds = 1800
//! rps = 2.0
//! warmup_seconds = 30
//! gateway_url = "https://gateway.teale.com"
//! token = "$GATEWAY_DEV_TOKEN"   # expanded from env if prefixed with $
//!
//! [[requests]]
//! model = "meta-llama/llama-3.1-8b-instruct"
//! weight = 3
//! prompt_tokens_mean = 256
//! prompt_tokens_stddev = 64
//! max_tokens = 256
//! streaming = true
//!
//! [[requests]]
//! model = "meta-llama/llama-3.3-70b-instruct"
//! weight = 1
//! prompt_tokens_mean = 512
//! prompt_tokens_stddev = 128
//! max_tokens = 512
//! streaming = true
//! ```

use serde::Deserialize;

#[derive(Debug, Deserialize, Clone)]
pub struct Scenario {
    pub name: String,
    pub gateway_url: String,
    pub token: String,
    pub duration_seconds: u64,
    pub rps: f64,
    #[serde(default)]
    pub warmup_seconds: u64,
    #[serde(default = "default_concurrency_cap")]
    pub concurrency_cap: u32,
    pub requests: Vec<RequestMix>,
    #[serde(default)]
    pub faults: Vec<FaultSchedule>,
}

#[derive(Debug, Deserialize, Clone)]
pub struct RequestMix {
    pub model: String,
    #[serde(default = "default_weight")]
    pub weight: u32,
    pub prompt_tokens_mean: u32,
    #[serde(default)]
    pub prompt_tokens_stddev: u32,
    pub max_tokens: u32,
    #[serde(default = "default_streaming")]
    pub streaming: bool,
    #[serde(default)]
    pub system_prompt: Option<String>,
}

#[derive(Debug, Deserialize, Clone)]
pub struct FaultSchedule {
    pub kind: FaultKind,
    pub at_seconds: u64,
    #[serde(default)]
    pub target: Option<String>,
    #[serde(default = "default_duration")]
    pub duration_seconds: u64,
}

#[derive(Debug, Deserialize, Clone, Copy, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum FaultKind {
    /// `pkill llama-server` on the target host (SSH).
    KillBackend,
    /// Send SIGKILL to the `teale-node` process on the target.
    KillNode,
    /// Block outgoing WebSocket on the target for `duration_seconds`.
    BlockWs,
    /// Stop responding to inbound probes for `duration_seconds`.
    PauseHeartbeat,
    /// Return malformed chunk JSON (requires the fault-injection proxy).
    MalformedChunk,
}

fn default_weight() -> u32 {
    1
}
fn default_streaming() -> bool {
    true
}
fn default_concurrency_cap() -> u32 {
    128
}
fn default_duration() -> u64 {
    30
}

impl Scenario {
    pub fn load(path: &str) -> anyhow::Result<Self> {
        let content = std::fs::read_to_string(path)?;
        let mut scn: Scenario = toml::from_str(&content)?;
        if let Some(env_name) = scn.token.strip_prefix('$') {
            scn.token = std::env::var(env_name)
                .map_err(|_| anyhow::anyhow!("env var {} not set", env_name))?;
        }
        Ok(scn)
    }
}
