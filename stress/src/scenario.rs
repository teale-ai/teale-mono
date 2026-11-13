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
//! user_agent = "OpenClaw/1.0"
//! message_profile = "agentic_coding"
//! tool_profile = "repo_probe"
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
    #[serde(default)]
    pub user_agent: Option<String>,
    #[serde(default)]
    pub message_profile: MessageProfile,
    #[serde(default)]
    pub tool_profile: ToolProfile,
    #[serde(default)]
    pub tool_choice: Option<String>,
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
    /// SIGTERM `llama-server` (or `mnn_llm`) on the target host (SSH).
    KillBackend,
    /// Send SIGKILL to the `teale-node` process on the target.
    KillNode,
    /// Block outbound TCP :443 on the target for `duration_seconds`
    /// (pfctl on macOS, iptables on Linux).
    BlockWs,
    /// SIGSTOP `teale-node` for `duration_seconds`, then SIGCONT.
    PauseHeartbeat,
    /// Placeholder: would return malformed chunk JSON via a fault-injection
    /// proxy, which does not exist yet. Only logs a warning.
    MalformedChunk,
}

#[derive(Debug, Deserialize, Clone, Copy, PartialEq, Eq, Default)]
#[serde(rename_all = "snake_case")]
pub enum MessageProfile {
    #[default]
    Plain,
    AgenticCoding,
    AgenticLongContext,
}

#[derive(Debug, Deserialize, Clone, Copy, PartialEq, Eq, Default)]
#[serde(rename_all = "snake_case")]
pub enum ToolProfile {
    #[default]
    None,
    RepoProbe,
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
        let mut scn = Self::parse(&content)?;
        if let Some(env_name) = scn.token.strip_prefix('$') {
            scn.token = std::env::var(env_name)
                .map_err(|_| anyhow::anyhow!("env var {} not set", env_name))?;
        }
        Ok(scn)
    }

    /// Parse scenario TOML and reject unfilled `REPLACE_WITH_*` fault targets
    /// so a template never fires faults at a bogus host.
    pub fn parse(content: &str) -> anyhow::Result<Self> {
        let scn: Scenario = toml::from_str(content)?;
        for fault in &scn.faults {
            if let Some(target) = &fault.target {
                if target.starts_with("REPLACE_WITH") {
                    anyhow::bail!(
                        "scenario {}: fault target {target} is a placeholder",
                        scn.name
                    );
                }
            }
        }
        Ok(scn)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const BASE: &str = r#"
name = "t"
gateway_url = "http://localhost"
token = "x"
duration_seconds = 1
rps = 1.0

[[requests]]
model = "m"
weight = 1
prompt_tokens_mean = 1
prompt_tokens_stddev = 1
max_tokens = 1
"#;

    fn with_fault(kind: &str, target: &str) -> String {
        format!("{BASE}\n[[faults]]\nkind = \"{kind}\"\nat_seconds = 1\ntarget = \"{target}\"\n")
    }

    #[test]
    fn placeholder_fault_targets_are_rejected() {
        let toml = with_fault("kill_backend", "REPLACE_WITH_HEAD_SSH_HOST");
        let err = Scenario::parse(&toml).unwrap_err().to_string();
        assert!(err.contains("placeholder"), "{err}");
    }

    #[test]
    fn real_fault_targets_are_accepted() {
        let toml = with_fault("kill_node", "ssh-host-1");
        let scn = Scenario::parse(&toml).unwrap();
        assert_eq!(scn.faults.len(), 1);
        assert_eq!(scn.faults[0].kind, FaultKind::KillNode);
    }
}
