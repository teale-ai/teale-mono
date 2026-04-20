//! Hardware detection — fills a `teale_protocol::HardwareCapability`
//! for the current machine. Types live in `teale_protocol::hardware`;
//! this file is the node-side detection logic only.

use sysinfo::System;

pub use teale_protocol::{HardwareCapability, NodeCapabilities};

use crate::config::NodeConfig;

pub fn detect_hardware(node_config: &NodeConfig) -> HardwareCapability {
    let mut sys = System::new_all();
    sys.refresh_all();

    let total_ram_gb = sys.total_memory() as f64 / (1024.0 * 1024.0 * 1024.0);
    let cpu_name = sys
        .cpus()
        .first()
        .map(|c| c.brand().to_string())
        .unwrap_or_else(|| "Unknown CPU".to_string());

    let (chip_family, chip_name, gpu_cores, bandwidth) = detect_chip_info(&cpu_name, total_ram_gb);

    let gpu_backend = node_config
        .gpu_backend
        .clone()
        .or_else(|| Some(infer_gpu_backend(&chip_family).to_string()));

    let tier = determine_tier(&chip_family, total_ram_gb);

    HardwareCapability {
        chip_family,
        chip_name,
        total_ram_gb,
        gpu_core_count: gpu_cores,
        memory_bandwidth_gbs: bandwidth,
        tier,
        gpu_backend,
        platform: Some(current_platform().to_string()),
        gpu_vram_gb: node_config.gpu_vram_gb,
    }
}

fn detect_chip_info(cpu_name: &str, _total_ram: f64) -> (String, String, u32, f64) {
    // Environment variable override — escape hatch for unrecognized hardware.
    if let Ok(chip) = std::env::var("TEALE_CHIP_FAMILY") {
        let name = std::env::var("TEALE_CHIP_NAME").unwrap_or_else(|_| cpu_name.to_string());
        let gpu_cores = std::env::var("TEALE_GPU_CORES")
            .ok()
            .and_then(|v| v.parse().ok())
            .unwrap_or(0);
        let bandwidth = std::env::var("TEALE_MEM_BANDWIDTH")
            .ok()
            .and_then(|v| v.parse().ok())
            .unwrap_or(25.0);
        return (chip, name, gpu_cores, bandwidth);
    }

    let lower = cpu_name.to_lowercase();

    if lower.contains("apple m") {
        let family = parse_apple_chip(&lower);
        let bandwidth = apple_bandwidth(&family);
        return (family, cpu_name.to_string(), 10, bandwidth);
    }

    if lower.contains("intel") {
        return ("intelCPU".to_string(), cpu_name.to_string(), 0, 50.0);
    }
    if lower.contains("amd") {
        return ("amdCPU".to_string(), cpu_name.to_string(), 0, 50.0);
    }
    if lower.contains("arm")
        || lower.contains("aarch64")
        || lower.contains("cortex")
        || lower.contains("snapdragon")
    {
        if let Some(soc) = detect_arm_soc() {
            return soc;
        }
        return ("armGeneric".to_string(), cpu_name.to_string(), 0, 25.0);
    }

    ("unknown".to_string(), cpu_name.to_string(), 0, 25.0)
}

fn parse_apple_chip(lower: &str) -> String {
    for (pattern, family) in &[
        ("m4 ultra", "m4Ultra"),
        ("m4 max", "m4Max"),
        ("m4 pro", "m4Pro"),
        ("m4", "m4"),
        ("m3 ultra", "m3Ultra"),
        ("m3 max", "m3Max"),
        ("m3 pro", "m3Pro"),
        ("m3", "m3"),
        ("m2 ultra", "m2Ultra"),
        ("m2 max", "m2Max"),
        ("m2 pro", "m2Pro"),
        ("m2", "m2"),
        ("m1 ultra", "m1Ultra"),
        ("m1 max", "m1Max"),
        ("m1 pro", "m1Pro"),
        ("m1", "m1"),
    ] {
        if lower.contains(pattern) {
            return family.to_string();
        }
    }
    "unknown".to_string()
}

/// Peak unified-memory bandwidth in GB/s by Apple chip family.
/// Source: Apple spec sheets + `.context/mac-fleet-configurations.md`.
fn apple_bandwidth(family: &str) -> f64 {
    match family {
        "m1" => 68.3,
        "m1Pro" => 204.8,
        "m1Max" => 409.6,
        "m1Ultra" => 819.2,
        "m2" => 102.4,
        "m2Pro" => 204.8,
        "m2Max" => 409.6,
        "m2Ultra" => 819.2,
        "m3" => 102.4,
        "m3Pro" => 153.6,
        "m3Max" => 409.6,
        "m3Ultra" => 819.0,
        "m4" => 120.0,
        "m4Pro" => 273.0,
        "m4Max" => 546.0,
        _ => 200.0,
    }
}

fn infer_gpu_backend(chip_family: &str) -> &'static str {
    match chip_family {
        f if f.starts_with('m') && f.chars().nth(1).is_some_and(|c| c.is_ascii_digit()) => "metal",
        f if f.starts_with("tensor") || f == "snapdragon" => "vulkan",
        "kirin" | "exynos" | "mediatek" => "opencl",
        "armGeneric" => {
            if cfg!(target_os = "android") || is_android_environment() {
                "vulkan"
            } else {
                "cpu"
            }
        }
        "nvidiaGPU" => "cuda",
        "amdGPU" => "rocm",
        _ => "cpu",
    }
}

fn determine_tier(chip_family: &str, total_ram_gb: f64) -> u32 {
    match chip_family {
        f if f.contains("Ultra") => 1,
        f if f.contains("Max") => 1,
        _ if total_ram_gb >= 64.0 => 1,
        f if is_mobile_soc(f) && total_ram_gb >= 12.0 => 2,
        _ if total_ram_gb >= 16.0 => 2,
        f if is_mobile_soc(f) => 3,
        _ if total_ram_gb >= 6.0 => 3,
        _ => 4,
    }
}

fn is_mobile_soc(chip_family: &str) -> bool {
    chip_family.starts_with("tensor")
        || matches!(chip_family, "snapdragon" | "kirin" | "exynos" | "mediatek")
}

fn is_android_environment() -> bool {
    std::env::var("ANDROID_ROOT").is_ok() || std::path::Path::new("/system/build.prop").exists()
}

#[cfg(any(target_os = "android", target_os = "linux"))]
fn detect_arm_soc() -> Option<(String, String, u32, f64)> {
    let cpuinfo = std::fs::read_to_string("/proc/cpuinfo").ok()?;

    let hardware = cpuinfo
        .lines()
        .find(|l| l.starts_with("Hardware"))
        .and_then(|l| l.split(':').nth(1))
        .map(|s| s.trim().to_lowercase());

    let soc_id = std::fs::read_to_string("/sys/devices/soc0/soc_id")
        .ok()
        .map(|s| s.trim().to_lowercase());

    let hw = hardware.as_deref().unwrap_or("");
    let soc = soc_id.as_deref().unwrap_or("");

    if hw.contains("tensor")
        || hw.contains("zuma")
        || hw.contains("ripcurrent")
        || soc.contains("zuma")
    {
        if hw.contains("g4") || hw.contains("zuma pro") {
            return Some((
                "tensorG4".to_string(),
                "Google Tensor G4".to_string(),
                7,
                51.0,
            ));
        }
        if hw.contains("g3") || hw.contains("zuma") {
            return Some((
                "tensorG3".to_string(),
                "Google Tensor G3".to_string(),
                7,
                51.0,
            ));
        }
        return Some((
            "tensorGeneric".to_string(),
            "Google Tensor".to_string(),
            7,
            40.0,
        ));
    }

    if hw.contains("snapdragon")
        || hw.contains("qcom")
        || hw.contains("sm8")
        || soc.contains("sm8")
        || soc.contains("qcom")
    {
        return Some((
            "snapdragon".to_string(),
            format!("Qualcomm {}", hw),
            0,
            44.0,
        ));
    }

    if hw.contains("exynos") || soc.contains("exynos") {
        return Some((
            "exynos".to_string(),
            format!("Samsung Exynos ({})", hw),
            0,
            35.0,
        ));
    }

    if hw.contains("kirin") || hw.contains("hisilicon") || soc.contains("kirin") {
        return Some((
            "kirin".to_string(),
            format!("Huawei Kirin ({})", hw),
            0,
            35.0,
        ));
    }

    if hw.contains("mediatek") || hw.contains("dimensity") || soc.contains("mt6") {
        return Some((
            "mediatek".to_string(),
            format!("MediaTek ({})", hw),
            0,
            35.0,
        ));
    }

    None
}

#[cfg(not(any(target_os = "android", target_os = "linux")))]
fn detect_arm_soc() -> Option<(String, String, u32, f64)> {
    None
}

fn current_platform() -> &'static str {
    #[cfg(target_os = "macos")]
    {
        "macOS"
    }
    #[cfg(target_os = "linux")]
    {
        "linux"
    }
    #[cfg(target_os = "windows")]
    {
        "windows"
    }
    #[cfg(target_os = "android")]
    {
        "android"
    }
    #[cfg(not(any(
        target_os = "macos",
        target_os = "linux",
        target_os = "windows",
        target_os = "android"
    )))]
    {
        "unknown"
    }
}

pub fn build_capabilities(
    hardware: HardwareCapability,
    model_id: Option<&str>,
    max_concurrent: u32,
    swappable_models: Vec<String>,
    effective_context: Option<u32>,
) -> NodeCapabilities {
    let max_model = hardware.gpu_vram_gb.unwrap_or(hardware.total_ram_gb * 0.75);

    NodeCapabilities {
        hardware,
        loaded_models: model_id.map(|m| vec![m.to_string()]).unwrap_or_default(),
        max_model_size_gb: max_model,
        is_available: true,
        ptn_ids: None,
        swappable_models,
        max_concurrent_requests: Some(max_concurrent),
        effective_context,
    }
}
