use serde::Deserialize;

#[derive(Debug, Deserialize, Clone)]
pub struct Config {
    pub relay: RelayConfig,
    /// Employee-machine throttling (Windows only today).
    #[serde(default)]
    pub power: PowerConfig,
    /// Inference backend: "llama" (default), "mnn", "litert", or "ds4"
    #[serde(default = "default_backend")]
    pub backend: String,
    pub llama: Option<LlamaConfig>,
    pub mnn: Option<MnnConfig>,
    pub litert: Option<LiteRtConfig>,
    pub ds4: Option<Ds4Config>,
    #[serde(default)]
    pub control: ControlConfig,
    pub node: NodeConfig,
    /// Private Inference Network membership (optional).
    #[serde(default)]
    pub pin: PinConfig,
}

#[derive(Debug, Deserialize, Clone, Default)]
pub struct PinConfig {
    /// Preseeded join code for mass IT deployment: on startup, if this
    /// device is not yet a member of any network, it auto-submits a join
    /// request with this code and waits for admin approval.
    #[serde(default)]
    pub join_code: Option<String>,
    /// Pinned gateway Ed25519 pubkey (hex) for netmap verification.
    /// When omitted the key is pinned on first use (TOFU) and persisted.
    #[serde(default)]
    pub gateway_pubkey: Option<String>,
    /// Data directory override for netmap cache / usage queue.
    #[serde(default)]
    pub data_dir: Option<String>,
    /// UDP port for the PIN data plane. 0 = ephemeral.
    #[serde(default)]
    pub port: u16,
}

#[derive(Debug, Deserialize, Clone)]
pub struct RelayConfig {
    #[serde(default = "default_relay_url")]
    pub url: String,
}

#[derive(Debug, Deserialize, Clone)]
pub struct LlamaConfig {
    pub binary: String,
    /// Path to the GGUF file on disk. Used as the `--model` arg to
    /// llama-server; NEVER advertised to the relay as a model id.
    pub model: String,
    /// Model id to send to the local HTTP backend. Defaults to the
    /// advertised `model_id`, but exo clusters often need a different
    /// local slug than the canonical gateway catalog id.
    #[serde(default)]
    pub backend_model_id: Option<String>,
    /// Canonical model id advertised to the relay (and via it to the
    /// OpenRouter gateway). Must match an entry in
    /// `gateway/models.yaml` — e.g. `"meta-llama/llama-3.1-8b-instruct"`.
    /// Falls back to the GGUF filename stem when omitted, which will
    /// NOT match the gateway catalog and should only be used for dev.
    #[serde(default)]
    pub model_id: Option<String>,
    #[serde(default = "default_gpu_layers")]
    pub gpu_layers: i32,
    #[serde(default = "default_context_size")]
    pub context_size: u32,
    #[serde(default = "default_llama_port")]
    pub port: u16,
    #[serde(default)]
    pub extra_args: Vec<String>,
}

impl LlamaConfig {
    /// Resolve the id to advertise. Prefer the explicit `model_id`;
    /// fall back to the GGUF filename stem with a runtime warning.
    pub fn resolved_model_id(&self) -> String {
        if let Some(id) = self.model_id.as_ref().filter(|s| !s.trim().is_empty()) {
            return id.clone();
        }
        let stem = std::path::Path::new(&self.model)
            .file_stem()
            .map(|s| s.to_string_lossy().to_string())
            .unwrap_or_else(|| self.model.clone());
        tracing::warn!(
            "[llama] model_id not set in config — falling back to GGUF stem '{}'. \
            This will NOT match the OpenRouter gateway catalog; set model_id explicitly.",
            stem
        );
        stem
    }

    pub fn resolved_backend_model_id(&self) -> String {
        self.backend_model_id
            .as_ref()
            .filter(|s| !s.trim().is_empty())
            .cloned()
            .unwrap_or_else(|| self.resolved_model_id())
    }
}

#[derive(Debug, Deserialize, Clone)]
pub struct Ds4Config {
    pub binary: String,
    /// Path to the DS4-specific DeepSeek V4 Flash GGUF. This is passed to
    /// ds4-server as --model and is never advertised as the gateway model id.
    pub model: String,
    /// Canonical model id advertised to the relay and gateway.
    #[serde(default)]
    pub model_id: Option<String>,
    /// Model id sent to ds4-server. ds4-server exposes deepseek-v4-flash
    /// locally even when Teale advertises a canonical gateway id.
    #[serde(default)]
    pub backend_model_id: Option<String>,
    #[serde(default = "default_ds4_context_size")]
    pub context_size: u32,
    #[serde(default = "default_ds4_port")]
    pub port: u16,
    #[serde(default)]
    pub kv_disk_dir: Option<String>,
    #[serde(default)]
    pub kv_disk_space_mb: Option<u32>,
    #[serde(default)]
    pub threads: Option<u32>,
    #[serde(default)]
    pub extra_args: Vec<String>,
}

impl Ds4Config {
    pub fn resolved_model_id(&self) -> String {
        self.model_id
            .as_ref()
            .filter(|s| !s.trim().is_empty())
            .cloned()
            .unwrap_or_else(|| "deepseek-ai/deepseek-v4-flash".to_string())
    }

    pub fn resolved_backend_model_id(&self) -> String {
        self.backend_model_id
            .as_ref()
            .filter(|s| !s.trim().is_empty())
            .cloned()
            .unwrap_or_else(|| "deepseek-v4-flash".to_string())
    }
}

#[derive(Debug, Deserialize, Clone)]
pub struct ControlConfig {
    #[serde(default = "default_control_port")]
    pub port: u16,
    #[serde(default = "default_registry_path")]
    pub registry_path: String,
    #[serde(default)]
    pub supabase_url: String,
    #[serde(default)]
    pub supabase_anon_key: String,
    #[serde(default = "default_supabase_redirect_url")]
    pub supabase_redirect_url: String,
}

impl Default for ControlConfig {
    fn default() -> Self {
        Self {
            port: default_control_port(),
            registry_path: default_registry_path(),
            supabase_url: String::new(),
            supabase_anon_key: String::new(),
            supabase_redirect_url: default_supabase_redirect_url(),
        }
    }
}

#[derive(Debug, Deserialize, Clone)]
pub struct MnnConfig {
    pub binary: String,
    pub model_dir: String,
    #[serde(default)]
    pub model_id: Option<String>,
    #[serde(default)]
    pub backend_type: Option<String>,
    #[serde(default = "default_mnn_context_size")]
    pub context_size: u32,
    #[serde(default = "default_mnn_port")]
    pub port: u16,
    #[serde(default)]
    pub extra_args: Vec<String>,
}

#[derive(Debug, Deserialize, Clone)]
pub struct LiteRtConfig {
    #[serde(default)]
    pub binary: Option<String>,
    pub model: String,
    #[serde(default)]
    pub model_id: Option<String>,
    #[serde(default)]
    pub backend_type: Option<String>,
    #[serde(default = "default_litert_context_size")]
    pub context_size: u32,
    #[serde(default)]
    pub cache_dir: Option<String>,
}

#[derive(Debug, Deserialize, Clone)]
pub struct NodeConfig {
    pub display_name: String,
    #[serde(default)]
    pub gpu_backend: Option<String>,
    #[serde(default)]
    pub gpu_vram_gb: Option<f64>,
    /// Max concurrent inference requests the node accepts.
    /// Defaults: 2 for mini/Pro, 4 for Max/Ultra — tune per deployment.
    #[serde(default = "default_max_concurrent")]
    pub max_concurrent_requests: u32,
    /// Advertised but not loaded-at-boot models. Ultra-only; gateway can issue
    /// `loadModel` to swap to any of these. Leave empty on non-Ultra nodes.
    #[serde(default)]
    pub swappable_models: Vec<String>,
    /// Graceful shutdown budget in seconds. SIGTERM handler waits up to this
    /// long for in-flight requests to complete before killing subprocesses.
    #[serde(default = "default_shutdown_timeout")]
    pub shutdown_timeout_seconds: u64,
    /// Heartbeat emission interval in seconds (default 10).
    #[serde(default = "default_heartbeat_interval")]
    pub heartbeat_interval_seconds: u64,
}

fn default_backend() -> String {
    "llama".to_string()
}
fn default_control_port() -> u16 {
    11437
}
fn default_registry_path() -> String {
    "config/model-registry.json".to_string()
}
fn default_supabase_redirect_url() -> String {
    "teale://auth/callback".to_string()
}
fn default_relay_url() -> String {
    "wss://relay.teale.com/ws".to_string()
}
fn default_gpu_layers() -> i32 {
    999
}
fn default_context_size() -> u32 {
    8192
}
fn default_mnn_context_size() -> u32 {
    2048
}
fn default_ds4_context_size() -> u32 {
    100000
}
fn default_llama_port() -> u16 {
    11436
}
fn default_mnn_port() -> u16 {
    11437
}
fn default_ds4_port() -> u16 {
    11438
}
fn default_litert_context_size() -> u32 {
    4096
}
fn default_max_concurrent() -> u32 {
    2
}
fn default_shutdown_timeout() -> u64 {
    30
}
fn default_heartbeat_interval() -> u64 {
    10
}

impl Config {
    pub fn load(path: &str) -> anyhow::Result<Self> {
        let content = std::fs::read_to_string(path)
            .map_err(|e| anyhow::anyhow!("Failed to read config file '{}': {}", path, e))?;
        let config: Config = toml::from_str(&content)?;

        match config.backend.as_str() {
            "llama" => {
                if config.llama.is_none() {
                    anyhow::bail!("[llama] config section is required when backend = \"llama\"");
                }
            }
            "mnn" => {
                if config.mnn.is_none() {
                    anyhow::bail!("[mnn] config section is required when backend = \"mnn\"");
                }
            }
            "litert" => {
                if config.litert.is_none() {
                    anyhow::bail!("[litert] config section is required when backend = \"litert\"");
                }
            }
            "ds4" => {
                if config.ds4.is_none() {
                    anyhow::bail!("[ds4] config section is required when backend = \"ds4\"");
                }
            }
            other => {
                anyhow::bail!(
                    "Unknown backend '{}'. Supported: \"llama\", \"mnn\", \"litert\", \"ds4\"",
                    other
                );
            }
        }

        Ok(config)
    }
}

/// Employee-machine supply throttling. Windows-only today: a poller in
/// `power_win` reads these knobs and drives `NodeRuntimeState.throttle_level`
/// (0 = paused, 100 = full), which the gateway scheduler already multiplies
/// into routing scores - a throttled node simply stops being picked.
#[derive(Debug, Deserialize, Clone)]
pub struct PowerConfig {
    /// Pause supply while average CPU usage over the window exceeds the
    /// threshold. Default on: supply must never degrade the host machine.
    #[serde(default = "default_pause_on_cpu_busy")]
    pub pause_on_cpu_busy: bool,
    #[serde(default = "default_cpu_busy_threshold_pct")]
    pub cpu_busy_threshold_pct: u32,
    #[serde(default = "default_cpu_busy_window_secs")]
    pub cpu_busy_window_secs: u64,
    /// When true, supply only while the user is idle (no keyboard/mouse
    /// input for `idle_after_secs`). Off by default; CPU-busy gating is
    /// the baseline protection.
    #[serde(default)]
    pub idle_only: bool,
    #[serde(default = "default_idle_after_secs")]
    pub idle_after_secs: u64,
}

fn default_pause_on_cpu_busy() -> bool {
    true
}
fn default_cpu_busy_threshold_pct() -> u32 {
    70
}
fn default_cpu_busy_window_secs() -> u64 {
    180
}
fn default_idle_after_secs() -> u64 {
    300
}

impl Default for PowerConfig {
    fn default() -> Self {
        Self {
            pause_on_cpu_busy: default_pause_on_cpu_busy(),
            cpu_busy_threshold_pct: default_cpu_busy_threshold_pct(),
            cpu_busy_window_secs: default_cpu_busy_window_secs(),
            idle_only: false,
            idle_after_secs: default_idle_after_secs(),
        }
    }
}
