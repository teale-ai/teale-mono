use serde::Serialize;
use sysinfo::System;

use crate::config::NodeConfig;

/// Hardware capability — field names must match Swift's Codable JSON encoding exactly.
#[derive(Debug, Clone, Serialize)]
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
    #[serde(rename = "gpuBackend", skip_serializing_if = "Option::is_none")]
    pub gpu_backend: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub platform: Option<String>,
    #[serde(rename = "gpuVRAMGB", skip_serializing_if = "Option::is_none")]
    pub gpu_vram_gb: Option<f64>,
}

/// Node capabilities — field names must match Swift's Codable JSON encoding exactly.
#[derive(Debug, Clone, Serialize)]
pub struct NodeCapabilities {
    pub hardware: HardwareCapability,
    #[serde(rename = "loadedModels")]
    pub loaded_models: Vec<String>,
    #[serde(rename = "maxModelSizeGB")]
    pub max_model_size_gb: f64,
    #[serde(rename = "isAvailable")]
    pub is_available: bool,
    #[serde(rename = "ptnIDs", skip_serializing_if = "Option::is_none")]
    pub ptn_ids: Option<Vec<String>>,
}

pub fn detect_hardware(node_config: &NodeConfig) -> HardwareCapability {
    let mut sys = System::new_all();
    sys.refresh_all();

    let total_ram_gb = sys.total_memory() as f64 / (1024.0 * 1024.0 * 1024.0);
    let cpu_name = sys.cpus().first()
        .map(|c| c.brand().to_string())
        .unwrap_or_else(|| "Unknown CPU".to_string());

    let (chip_family, chip_name, gpu_cores, bandwidth) = detect_chip_info(&cpu_name, total_ram_gb);

    let gpu_backend = node_config.gpu_backend.clone().or_else(|| {
        Some(infer_gpu_backend(&chip_family).to_string())
    });

    let tier = determine_tier(&chip_family, total_ram_gb);

    HardwareCapability {
        chip_family,
        chip_name,
        total_ram_gb: total_ram_gb,
        gpu_core_count: gpu_cores,
        memory_bandwidth_gbs: bandwidth,
        tier,
        gpu_backend,
        platform: Some(current_platform().to_string()),
        gpu_vram_gb: node_config.gpu_vram_gb,
    }
}

fn detect_chip_info(cpu_name: &str, _total_ram: f64) -> (String, String, u32, f64) {
    let lower = cpu_name.to_lowercase();

    // Check for Apple Silicon (teale-node might run on macOS too)
    if lower.contains("apple m") {
        let family = parse_apple_chip(&lower);
        return (family, cpu_name.to_string(), 10, 200.0);
    }

    // NVIDIA GPU detection (check environment or config)
    // In practice, GPU detection happens via config; CPU is what sysinfo reports
    if lower.contains("intel") {
        return ("intelCPU".to_string(), cpu_name.to_string(), 0, 50.0);
    }
    if lower.contains("amd") {
        // Check if it's a Ryzen/EPYC (CPU) vs Radeon (GPU)
        return ("amdCPU".to_string(), cpu_name.to_string(), 0, 50.0);
    }
    if lower.contains("arm") || lower.contains("aarch64") || lower.contains("snapdragon") {
        return ("armGeneric".to_string(), cpu_name.to_string(), 0, 25.0);
    }

    ("unknown".to_string(), cpu_name.to_string(), 0, 25.0)
}

fn parse_apple_chip(lower: &str) -> String {
    // Match most specific first
    for (pattern, family) in &[
        ("m4 ultra", "m4Ultra"), ("m4 max", "m4Max"), ("m4 pro", "m4Pro"), ("m4", "m4"),
        ("m3 ultra", "m3Ultra"), ("m3 max", "m3Max"), ("m3 pro", "m3Pro"), ("m3", "m3"),
        ("m2 ultra", "m2Ultra"), ("m2 max", "m2Max"), ("m2 pro", "m2Pro"), ("m2", "m2"),
        ("m1 ultra", "m1Ultra"), ("m1 max", "m1Max"), ("m1 pro", "m1Pro"), ("m1", "m1"),
    ] {
        if lower.contains(pattern) {
            return family.to_string();
        }
    }
    "unknown".to_string()
}

fn infer_gpu_backend(chip_family: &str) -> &'static str {
    match chip_family {
        f if f.starts_with('m') || f.starts_with('a') => "metal",
        "nvidiaGPU" => "cuda",
        "amdGPU" => "rocm",
        _ => "cpu",
    }
}

fn determine_tier(chip_family: &str, total_ram_gb: f64) -> u32 {
    match chip_family {
        // Apple desktops
        f if f.contains("Ultra") => 1,
        f if f.contains("Max") => 1,
        // High-RAM servers
        _ if total_ram_gb >= 64.0 => 1,
        // Desktop-class
        _ if total_ram_gb >= 16.0 => 2,
        // Tablet/low-power
        _ if total_ram_gb >= 6.0 => 3,
        // Phone/SBC
        _ => 4,
    }
}

fn current_platform() -> &'static str {
    #[cfg(target_os = "macos")]
    { "macOS" }
    #[cfg(target_os = "linux")]
    { "linux" }
    #[cfg(target_os = "windows")]
    { "windows" }
    #[cfg(target_os = "android")]
    { "android" }
    #[cfg(not(any(target_os = "macos", target_os = "linux", target_os = "windows", target_os = "android")))]
    { "unknown" }
}

pub fn build_capabilities(hardware: HardwareCapability, model_id: Option<&str>) -> NodeCapabilities {
    let max_model = hardware.gpu_vram_gb
        .unwrap_or(hardware.total_ram_gb * 0.75);

    NodeCapabilities {
        hardware,
        loaded_models: model_id.map(|m| vec![m.to_string()]).unwrap_or_default(),
        max_model_size_gb: max_model,
        is_available: true,
        ptn_ids: None,
    }
}
