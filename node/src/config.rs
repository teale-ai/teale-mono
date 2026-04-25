use serde::Deserialize;

#[derive(Debug, Deserialize, Clone)]
pub struct Config {
    pub relay: RelayConfig,
    /// Inference backend: "llama" (default), "mnn", or "litert"
    #[serde(default = "default_backend")]
    pub backend: String,
    pub llama: Option<LlamaConfig>,
    pub mnn: Option<MnnConfig>,
    pub litert: Option<LiteRtConfig>,
    #[serde(default)]
    pub control: ControlConfig,
    pub node: NodeConfig,
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
fn default_llama_port() -> u16 {
    11436
}
fn default_mnn_port() -> u16 {
    11437
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
            other => {
                anyhow::bail!(
                    "Unknown backend '{}'. Supported: \"llama\", \"mnn\", \"litert\"",
                    other
                );
            }
        }

        Ok(config)
    }
}
