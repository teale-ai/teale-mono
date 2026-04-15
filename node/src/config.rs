use serde::Deserialize;

#[derive(Debug, Deserialize)]
pub struct Config {
    pub relay: RelayConfig,
    pub llama: LlamaConfig,
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
pub struct NodeConfig {
    pub display_name: String,
    #[serde(default)]
    pub gpu_backend: Option<String>,
    #[serde(default)]
    pub gpu_vram_gb: Option<f64>,
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

fn default_llama_port() -> u16 {
    11436
}

impl Config {
    pub fn load(path: &str) -> anyhow::Result<Self> {
        let content = std::fs::read_to_string(path)
            .map_err(|e| anyhow::anyhow!("Failed to read config file '{}': {}", path, e))?;
        let config: Config = toml::from_str(&content)?;
        Ok(config)
    }
}
