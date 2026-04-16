use serde::Deserialize;

#[derive(Debug, Deserialize)]
pub struct Config {
    pub relay: RelayConfig,
    /// Inference backend: "llama" (default) or "mnn"
    #[serde(default = "default_backend")]
    pub backend: String,
    /// llama-server config (required when backend = "llama")
    pub llama: Option<LlamaConfig>,
    /// MNN-LLM config (required when backend = "mnn")
    pub mnn: Option<MnnConfig>,
    /// LiteRT-LM config (required when backend = "litert")
    pub litert: Option<LiteRtConfig>,
    pub node: NodeConfig,
}

#[derive(Debug, Deserialize)]
pub struct RelayConfig {
    #[serde(default = "default_relay_url")]
    pub url: String,
}

#[derive(Debug, Deserialize)]
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

#[derive(Debug, Deserialize)]
pub struct MnnConfig {
    pub binary: String,
    /// Path to MNN model directory (converted model, not GGUF)
    pub model_dir: String,
    /// Model identifier reported to the network (defaults to model_dir basename)
    #[serde(default)]
    pub model_id: Option<String>,
    /// GPU backend: "opencl", "vulkan", "metal", "cpu" (auto-detected if omitted)
    #[serde(default)]
    pub backend_type: Option<String>,
    #[serde(default = "default_mnn_context_size")]
    pub context_size: u32,
    #[serde(default = "default_mnn_port")]
    pub port: u16,
    #[serde(default)]
    pub extra_args: Vec<String>,
}

#[derive(Debug, Deserialize)]
pub struct LiteRtConfig {
    /// Path to litert_lm_main binary (defaults to searching PATH)
    #[serde(default)]
    pub binary: Option<String>,
    /// Path to .litertlm model file
    pub model: String,
    /// Model identifier reported to the network (defaults to model filename)
    #[serde(default)]
    pub model_id: Option<String>,
    /// Compute backend: "cpu", "gpu", "npu" (default "cpu")
    #[serde(default)]
    pub backend_type: Option<String>,
    /// Maximum context size in tokens
    #[serde(default = "default_litert_context_size")]
    pub context_size: u32,
    /// Cache directory for compiled model artifacts
    #[serde(default)]
    pub cache_dir: Option<String>,
}

#[derive(Debug, Deserialize)]
pub struct NodeConfig {
    pub display_name: String,
    #[serde(default)]
    pub gpu_backend: Option<String>,
    #[serde(default)]
    pub gpu_vram_gb: Option<f64>,
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

impl Config {
    pub fn load(path: &str) -> anyhow::Result<Self> {
        let content = std::fs::read_to_string(path)
            .map_err(|e| anyhow::anyhow!("Failed to read config file '{}': {}", path, e))?;
        let config: Config = toml::from_str(&content)?;

        // Validate that the selected backend has a config section
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
