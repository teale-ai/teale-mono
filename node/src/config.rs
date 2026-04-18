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
    pub model: String,
    #[serde(default = "default_gpu_layers")]
    pub gpu_layers: i32,
    #[serde(default = "default_context_size")]
    pub context_size: u32,
    #[serde(default = "default_llama_port")]
    pub port: u16,
    #[serde(default)]
    pub extra_args: Vec<String>,
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
                anyhow::bail!("Unknown backend '{}'. Supported: \"llama\", \"mnn\", \"litert\"", other);
            }
        }

        Ok(config)
    }
}
