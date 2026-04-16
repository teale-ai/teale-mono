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
    // Environment variable override — escape hatch for unrecognized hardware
    if let Ok(chip) = std::env::var("TEALE_CHIP_FAMILY") {
        let name = std::env::var("TEALE_CHIP_NAME").unwrap_or_else(|_| cpu_name.to_string());
        let gpu_cores = std::env::var("TEALE_GPU_CORES").ok().and_then(|v| v.parse().ok()).unwrap_or(0);
        let bandwidth = std::env::var("TEALE_MEM_BANDWIDTH").ok().and_then(|v| v.parse().ok()).unwrap_or(25.0);
        return (chip, name, gpu_cores, bandwidth);
    }

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
        return ("amdCPU".to_string(), cpu_name.to_string(), 0, 50.0);
    }
    if lower.contains("arm") || lower.contains("aarch64") || lower.contains("cortex") || lower.contains("snapdragon") {
        // Try to identify specific ARM SoC from /proc/cpuinfo
        if let Some(soc) = detect_arm_soc() {
            return soc;
        }
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
        // Apple Silicon (M-series): Metal
        f if f.starts_with('m') && f.chars().nth(1).is_some_and(|c| c.is_ascii_digit()) => "metal",
        // Google Tensor / Qualcomm Snapdragon: Vulkan
        f if f.starts_with("tensor") || f == "snapdragon" => "vulkan",
        // Huawei Kirin / Samsung Exynos / MediaTek: OpenCL (Mali GPUs)
        "kirin" | "exynos" | "mediatek" => "opencl",
        // Generic ARM: Vulkan on Android, CPU elsewhere
        "armGeneric" => {
            if cfg!(target_os = "android") || is_android_environment() { "vulkan" } else { "cpu" }
        }
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
        // High-RAM mobile SoCs (e.g. Tensor G4 16GB, Snapdragon 8 Gen 3 16GB, Kirin 9000s)
        f if is_mobile_soc(f) && total_ram_gb >= 12.0 => 2,
        // Desktop-class
        _ if total_ram_gb >= 16.0 => 2,
        // Mobile SoCs with moderate RAM
        f if is_mobile_soc(f) => 3,
        // Tablet/low-power
        _ if total_ram_gb >= 6.0 => 3,
        // Phone/SBC
        _ => 4,
    }
}

fn is_mobile_soc(chip_family: &str) -> bool {
    chip_family.starts_with("tensor")
        || matches!(chip_family, "snapdragon" | "kirin" | "exynos" | "mediatek")
}

/// Detect if running on Android (covers both NDK builds and Termux on Linux).
fn is_android_environment() -> bool {
    std::env::var("ANDROID_ROOT").is_ok() || std::path::Path::new("/system/build.prop").exists()
}

/// Try to identify ARM SoC from /proc/cpuinfo (works on Android NDK and Termux).
#[cfg(any(target_os = "android", target_os = "linux"))]
fn detect_arm_soc() -> Option<(String, String, u32, f64)> {
    let cpuinfo = std::fs::read_to_string("/proc/cpuinfo").ok()?;

    // Look for "Hardware" line (common on Android kernels)
    let hardware = cpuinfo.lines()
        .find(|l| l.starts_with("Hardware"))
        .and_then(|l| l.split(':').nth(1))
        .map(|s| s.trim().to_lowercase());

    // Also try /sys/devices/soc0/soc_id as fallback
    let soc_id = std::fs::read_to_string("/sys/devices/soc0/soc_id")
        .ok()
        .map(|s| s.trim().to_lowercase());

    let hw = hardware.as_deref().unwrap_or("");
    let soc = soc_id.as_deref().unwrap_or("");

    // Google Tensor
    if hw.contains("tensor") || hw.contains("zuma") || hw.contains("ripcurrent")
        || soc.contains("zuma") {
        if hw.contains("g4") || hw.contains("zuma pro") {
            return Some(("tensorG4".to_string(), "Google Tensor G4".to_string(), 7, 51.0));
        }
        if hw.contains("g3") || hw.contains("zuma") {
            return Some(("tensorG3".to_string(), "Google Tensor G3".to_string(), 7, 51.0));
        }
        return Some(("tensorGeneric".to_string(), "Google Tensor".to_string(), 7, 40.0));
    }

    // Qualcomm Snapdragon
    if hw.contains("snapdragon") || hw.contains("qcom") || hw.contains("sm8")
        || soc.contains("sm8") || soc.contains("qcom") {
        return Some(("snapdragon".to_string(), format!("Qualcomm {}", hw), 0, 44.0));
    }

    // Samsung Exynos
    if hw.contains("exynos") || soc.contains("exynos") {
        return Some(("exynos".to_string(), format!("Samsung Exynos ({})", hw), 0, 35.0));
    }

    // Huawei Kirin (HiSilicon)
    if hw.contains("kirin") || hw.contains("hisilicon") || soc.contains("kirin") {
        return Some(("kirin".to_string(), format!("Huawei Kirin ({})", hw), 0, 35.0));
    }

    // MediaTek Dimensity
    if hw.contains("mediatek") || hw.contains("dimensity") || soc.contains("mt6") {
        return Some(("mediatek".to_string(), format!("MediaTek ({})", hw), 0, 35.0));
    }

    None
}

#[cfg(not(any(target_os = "android", target_os = "linux")))]
fn detect_arm_soc() -> Option<(String, String, u32, f64)> {
    None
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
