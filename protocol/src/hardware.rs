//! Hardware capability — the payload a node advertises to the relay
//! at registration and on every heartbeat.
//!
//! Field names must match Swift's Codable encoding exactly (camelCase).

use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct HardwareCapability {
    #[serde(rename = "chipFamily")]
    pub chip_family: String,
    #[serde(rename = "chipName")]
    pub chip_name: String,
    #[serde(rename = "totalRAMGB")]
    pub total_ram_gb: f64,
    #[serde(rename = "gpuCoreCount")]
    pub gpu_core_count: u32,
    #[serde(rename = "memoryBandwidthGBs")]
    pub memory_bandwidth_gbs: f64,
    pub tier: u32,
    #[serde(
        rename = "gpuBackend",
        default,
        skip_serializing_if = "Option::is_none"
    )]
    pub gpu_backend: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub platform: Option<String>,
    #[serde(rename = "gpuVRAMGB", default, skip_serializing_if = "Option::is_none")]
    pub gpu_vram_gb: Option<f64>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct NodeCapabilities {
    pub hardware: HardwareCapability,
    #[serde(rename = "loadedModels")]
    pub loaded_models: Vec<String>,
    #[serde(rename = "maxModelSizeGB")]
    pub max_model_size_gb: f64,
    #[serde(rename = "isAvailable")]
    pub is_available: bool,
    #[serde(rename = "ptnIDs", default, skip_serializing_if = "Option::is_none")]
    pub ptn_ids: Option<Vec<String>>,
    /// Models on disk that can be swapped in via `loadModel` (Ultras only).
    /// Additive field — older relays/nodes ignore it gracefully.
    #[serde(
        rename = "swappableModels",
        default,
        skip_serializing_if = "Vec::is_empty"
    )]
    pub swappable_models: Vec<String>,
    /// Max concurrent inference requests the node will accept.
    #[serde(
        rename = "maxConcurrentRequests",
        default,
        skip_serializing_if = "Option::is_none"
    )]
    pub max_concurrent_requests: Option<u32>,
    /// Effective context size (in tokens) the node's loaded backend was
    /// launched with — i.e. the `--ctx-size` flag to llama-server, or the
    /// equivalent for MNN/LiteRT. Optional for back-compat: older nodes
    /// omit it and the gateway falls back to the catalog's `context_length`.
    #[serde(
        rename = "effectiveContext",
        default,
        skip_serializing_if = "Option::is_none"
    )]
    pub effective_context: Option<u32>,
    /// Laptop supply nodes flag whether they're currently on AC power. We
    /// only supply on AC — pausing on battery is a trust feature for end-
    /// user-laptop contributors who shouldn't see battery drain from Teale.
    /// `None` means "this node doesn't participate in battery gating" (Mac
    /// Studios, desktops, Swift Teale.app, etc.).
    #[serde(rename = "onACPower", default, skip_serializing_if = "Option::is_none")]
    pub on_ac_power: Option<bool>,
}

/// Device capability tier. 1 = backbone (Ultra/Max, 64GB+), 4 = phone/SBC.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[repr(u32)]
pub enum Tier {
    Backbone = 1,
    Desktop = 2,
    Tablet = 3,
    Leaf = 4,
}

impl Tier {
    pub fn from_u32(v: u32) -> Option<Self> {
        match v {
            1 => Some(Tier::Backbone),
            2 => Some(Tier::Desktop),
            3 => Some(Tier::Tablet),
            4 => Some(Tier::Leaf),
            _ => None,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum GpuBackend {
    Metal,
    Cuda,
    Rocm,
    Vulkan,
    Sycl,
    Opencl,
    Cpu,
}
