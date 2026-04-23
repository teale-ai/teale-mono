//! GET /v1/network — debug/telemetry view of every device the gateway
//! currently tracks. Powers the network dashboard at scripts/teale-network-viz.py.
//!
//! This is read-only and auth-gated (same as /v1/models). The payload is
//! verbose on purpose — clients can pick the fields they care about.

use axum::{extract::State, Json};
use serde::Serialize;
use serde_json::{json, Value};
use std::collections::HashSet;

use crate::catalog::is_large;
use crate::ledger;
use crate::state::AppState;

const HIDDEN_MODEL_IDS: &[&str] = &["moonshotai/kimi-k2"];

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

#[derive(Serialize)]
struct NetworkStatsView {
    #[serde(rename = "totalDevices")]
    total_devices: usize,
    #[serde(rename = "totalRamGB")]
    total_ram_gb: f64,
    #[serde(rename = "totalModels")]
    total_models: usize,
    #[serde(rename = "avgTtftMs")]
    avg_ttft_ms: Option<u32>,
    #[serde(rename = "avgTps")]
    avg_tps: Option<f32>,
    #[serde(rename = "totalCreditsEarned")]
    total_credits_earned: i64,
    #[serde(rename = "totalCreditsSpent")]
    total_credits_spent: i64,
    #[serde(rename = "totalUsdcDistributedCents")]
    total_usdc_distributed_cents: i64,
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

pub async fn network_stats(State(state): State<AppState>) -> Json<Value> {
    let totals = state
        .db
        .as_ref()
        .and_then(|pool| ledger::network_ledger_totals(pool).ok())
        .unwrap_or(ledger::NetworkLedgerTotals {
            total_credits_earned: 0,
            total_credits_spent: 0,
            total_usdc_distributed_cents: 0,
        });

    let total_devices = state.registry.device_count();
    let total_ram_gb: f64 = state
        .registry
        .snapshot_devices()
        .iter()
        .map(|dev| dev.capabilities.hardware.total_ram_gb)
        .sum();

    let floor = &state.config.scheduler.per_model_floor;
    let mut total_models = 0usize;
    let mut ttft_weighted_sum = 0u64;
    let mut ttft_samples = 0u64;
    let mut tps_weighted_sum = 0.0f64;
    let mut tps_samples = 0u64;

    for model in state.catalog.iter() {
        if HIDDEN_MODEL_IDS.contains(&model.id.as_str()) || model.is_virtual {
            continue;
        }
        let min = if is_large(model.params_b) {
            floor.large
        } else {
            floor.small
        };
        if state.registry.loaded_count(&model.id) < min {
            continue;
        }
        total_models += 1;
        if let Some(metrics) = state.model_metrics.snapshot(&model.id) {
            let weight = metrics.sample_count.max(1) as u64;
            if let Some(ttft_ms_avg) = metrics.ttft_ms_avg {
                ttft_weighted_sum += ttft_ms_avg as u64 * weight;
                ttft_samples += weight;
            }
            if let Some(tps_avg) = metrics.tps_avg {
                tps_weighted_sum += tps_avg as f64 * weight as f64;
                tps_samples += weight;
            }
        }
    }

    let avg_ttft_ms = if ttft_samples > 0 {
        Some((ttft_weighted_sum / ttft_samples) as u32)
    } else {
        None
    };
    let avg_tps = if tps_samples > 0 {
        Some((tps_weighted_sum / tps_samples as f64) as f32)
    } else {
        None
    };

    Json(json!(NetworkStatsView {
        total_devices,
        total_ram_gb,
        total_models,
        avg_ttft_ms,
        avg_tps,
        total_credits_earned: totals.total_credits_earned,
        total_credits_spent: totals.total_credits_spent,
        total_usdc_distributed_cents: totals.total_usdc_distributed_cents,
    }))
}
