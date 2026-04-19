//! GET /v1/network — debug/telemetry view of every device the gateway
//! currently tracks. Powers the network dashboard at scripts/teale-network-viz.py.
//!
//! This is read-only and auth-gated (same as /v1/models). The payload is
//! verbose on purpose — clients can pick the fields they care about.

use axum::{extract::State, Json};
use serde::Serialize;
use serde_json::{json, Value};
use std::collections::HashSet;

use crate::state::AppState;

#[derive(Serialize)]
struct DeviceView {
    #[serde(rename = "nodeID")]
    node_id: String,
    #[serde(rename = "shortID")]
    short_id: String,
    #[serde(rename = "displayName")]
    display_name: String,
    chip: String,
    #[serde(rename = "ramGB")]
    ram_gb: f64,
    #[serde(rename = "memoryBandwidthGBs")]
    memory_bandwidth_gbs: f64,
    #[serde(rename = "gpuCoreCount")]
    gpu_core_count: u32,
    tier: u32,
    platform: Option<String>,
    #[serde(rename = "loadedModels")]
    loaded_models: Vec<String>,
    #[serde(rename = "swappableModels")]
    swappable_models: Vec<String>,
    #[serde(rename = "isAvailable")]
    is_available: bool,
    #[serde(rename = "isQuarantined")]
    is_quarantined: bool,
    #[serde(rename = "isGenerating")]
    is_generating: bool,
    #[serde(rename = "queueDepth")]
    queue_depth: u32,
    #[serde(rename = "throttleLevel")]
    throttle_level: u32,
    #[serde(rename = "thermalLevel")]
    thermal_level: String,
    #[serde(rename = "ewmaTokensPerSecond")]
    ewma_tokens_per_second: f64,
    #[serde(rename = "inFlight")]
    in_flight: u32,
    #[serde(rename = "heartbeatAgeSecs")]
    heartbeat_age_secs: u64,
    #[serde(rename = "heartbeatStale")]
    heartbeat_stale: bool,
    #[serde(rename = "lastSeenAgeSecs")]
    last_seen_age_secs: u64,
    role: &'static str, // "supply" | "idle" | "quarantined"
}

pub async fn network(State(state): State<AppState>) -> Json<Value> {
    let devices = state.registry.snapshot_devices();
    let stale_after = state.config.reliability.heartbeat_stale_seconds;

    let mut views: Vec<DeviceView> = Vec::with_capacity(devices.len());
    let mut supply_count = 0u32;
    let mut idle_count = 0u32;
    let mut quarantined_count = 0u32;
    let mut total_ram: f64 = 0.0;
    let mut total_ewma_tps: f64 = 0.0;
    let mut models_served: HashSet<String> = HashSet::new();

    for dev in devices.iter() {
        let caps = &dev.capabilities;
        let in_flight = state.registry.in_flight(&dev.node_id);
        let is_quarantined = dev.is_quarantined();
        let heartbeat_stale = dev.heartbeat_is_stale(stale_after);
        let loaded_models = caps.loaded_models.clone();

        let role = if is_quarantined {
            quarantined_count += 1;
            "quarantined"
        } else if !loaded_models.is_empty() && caps.is_available && !heartbeat_stale {
            supply_count += 1;
            for m in &loaded_models {
                models_served.insert(m.clone());
            }
            "supply"
        } else {
            idle_count += 1;
            "idle"
        };

        total_ram += caps.hardware.total_ram_gb;
        total_ewma_tps += dev.ewma_tokens_per_second;

        views.push(DeviceView {
            node_id: dev.node_id.clone(),
            short_id: dev.node_id.chars().take(12).collect(),
            display_name: dev.display_name.clone(),
            chip: caps.hardware.chip_name.clone(),
            ram_gb: caps.hardware.total_ram_gb,
            memory_bandwidth_gbs: caps.hardware.memory_bandwidth_gbs,
            gpu_core_count: caps.hardware.gpu_core_count,
            tier: caps.hardware.tier,
            platform: caps.hardware.platform.clone(),
            loaded_models,
            swappable_models: caps.swappable_models.clone(),
            is_available: caps.is_available,
            is_quarantined,
            is_generating: dev.live.is_generating,
            queue_depth: dev.live.queue_depth,
            throttle_level: dev.live.throttle_level,
            thermal_level: format!("{:?}", dev.live.thermal_level),
            ewma_tokens_per_second: dev.ewma_tokens_per_second,
            in_flight,
            heartbeat_age_secs: dev.last_heartbeat.elapsed().as_secs(),
            heartbeat_stale,
            last_seen_age_secs: dev.last_seen.elapsed().as_secs(),
            role,
        });
    }

    // Stable ordering: supply first, then by display_name
    views.sort_by(|a, b| {
        let role_rank = |r: &str| match r {
            "supply" => 0,
            "idle" => 1,
            "quarantined" => 2,
            _ => 3,
        };
        role_rank(a.role)
            .cmp(&role_rank(b.role))
            .then_with(|| a.display_name.cmp(&b.display_name))
    });

    Json(json!({
        "devices": views,
        "summary": {
            "connected": devices.len(),
            "supply": supply_count,
            "idle": idle_count,
            "quarantined": quarantined_count,
            "totalRAMGB": total_ram,
            "totalEwmaTokensPerSecond": total_ewma_tps,
            "uniqueModelsServed": models_served.len(),
            "modelsServed": models_served.into_iter().collect::<Vec<_>>(),
        }
    }))
}
