//! In-memory device registry. The gateway maintains this by subscribing
//! to `peerJoined` / `peerLeft` / `discover` responses from the relay.
//!
//! The registry is the source of truth for routing decisions — the scheduler
//! reads from it, the handlers read its `healthy_devices_for_model` to decide
//! whether to list a model as available.

use std::collections::HashSet;
use std::sync::Arc;
use std::time::Instant;

use dashmap::DashMap;
use parking_lot::RwLock;

use teale_protocol::{HeartbeatPayload, NodeCapabilities, ThermalLevel};

use crate::config::ReliabilityConfig;

/// Per-device mutable state tracked by the gateway.
#[derive(Debug, Clone)]
pub struct DeviceState {
    pub node_id: String,
    pub display_name: String,
    pub capabilities: NodeCapabilities,
    /// Last heartbeat received (for staleness check).
    pub last_heartbeat: Instant,
    /// Last good signal (register, heartbeat, hello, discover).
    pub last_seen: Instant,
    /// If quarantined, this is when we can re-add it to the pool.
    pub quarantined_until: Option<Instant>,
    /// Observed tokens-per-second EWMA. Defaults to hardware estimate until
    /// first real measurement arrives.
    pub ewma_tokens_per_second: f64,
    /// Runtime-live heartbeat fields (queue_depth, thermal, throttle).
    pub live: LiveStats,
}

#[derive(Debug, Clone)]
pub struct LiveStats {
    pub queue_depth: u32,
    pub is_generating: bool,
    pub throttle_level: u32,
    pub thermal_level: ThermalLevel,
}

impl LiveStats {
    pub fn fresh() -> Self {
        Self {
            queue_depth: 0,
            is_generating: false,
            throttle_level: 100,
            thermal_level: ThermalLevel::Nominal,
        }
    }
}

impl DeviceState {
    /// Can this device accept a request for `model_id` right now?
    pub fn is_eligible_for(&self, model_id: &str, max_queue: u32) -> Eligibility {
        if self.is_quarantined() {
            return Eligibility::Quarantined;
        }
        if self.live.thermal_level == ThermalLevel::Critical {
            return Eligibility::Throttled;
        }
        if self.live.queue_depth >= max_queue {
            return Eligibility::QueueFull;
        }
        if !self.capabilities.is_available {
            return Eligibility::Unavailable;
        }

        if model_matches_any(model_id, &self.capabilities.loaded_models) {
            Eligibility::Loaded
        } else if model_matches_any(model_id, &self.capabilities.swappable_models) {
            Eligibility::Swappable
        } else {
            Eligibility::Unsupported
        }
    }

    pub fn is_quarantined(&self) -> bool {
        self.quarantined_until
            .map(|t| t > Instant::now())
            .unwrap_or(false)
    }

    pub fn heartbeat_is_stale(&self, stale_after_secs: u64) -> bool {
        self.last_heartbeat.elapsed().as_secs() > stale_after_secs
    }

    pub fn apply_heartbeat(&mut self, hb: &HeartbeatPayload) {
        self.last_heartbeat = Instant::now();
        self.last_seen = Instant::now();
        self.live.queue_depth = hb.queue_depth;
        self.live.is_generating = hb.is_generating;
        self.live.throttle_level = hb.throttle_level;
        self.live.thermal_level = hb.thermal_level;
        if !hb.loaded_models.is_empty() {
            self.capabilities.loaded_models = hb.loaded_models.clone();
        }
        if let Some(tps) = hb.ewma_tokens_per_second {
            self.ewma_tokens_per_second = tps;
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Eligibility {
    Loaded,
    Swappable,
    Unsupported,
    QueueFull,
    Quarantined,
    Throttled,
    Unavailable,
}

pub struct Registry {
    /// Every known device (even quarantined).
    devices: DashMap<String, DeviceState>,
    /// Reverse index: model_id (normalized) → set of node_ids.
    /// Maintained in sync with device.capabilities.loaded_models /
    /// swappable_models. `RwLock` inner for batch updates during
    /// discover responses.
    model_to_devices: RwLock<dashmap::DashMap<String, HashSet<String>>>,
    reliability: ReliabilityConfig,
}

impl Registry {
    pub fn new(reliability: ReliabilityConfig) -> Arc<Self> {
        Arc::new(Self {
            devices: DashMap::new(),
            model_to_devices: RwLock::new(DashMap::new()),
            reliability,
        })
    }

    pub fn device_count(&self) -> usize {
        self.devices.len()
    }

    pub fn snapshot_devices(&self) -> Vec<DeviceState> {
        self.devices.iter().map(|r| r.value().clone()).collect()
    }

    /// Insert or update a device from its advertised capabilities.
    pub fn upsert_device(&self, node_id: String, display_name: String, caps: NodeCapabilities) {
        let now = Instant::now();
        // Scope the entry RefMut so it drops before we call rebuild_model_index_for,
        // which would otherwise deadlock trying to re-acquire the same shard.
        {
            let mut entry = self
                .devices
                .entry(node_id.clone())
                .or_insert_with(|| DeviceState {
                    node_id: node_id.clone(),
                    display_name: display_name.clone(),
                    capabilities: caps.clone(),
                    last_heartbeat: now,
                    last_seen: now,
                    quarantined_until: None,
                    ewma_tokens_per_second: hardware_tps_prior(&caps),
                    live: LiveStats::fresh(),
                });
            entry.display_name = display_name;
            entry.capabilities = caps;
            entry.last_seen = now;
        }

        // Rebuild reverse index for this node (safe now that the shard guard is released).
        self.rebuild_model_index_for(&node_id);
    }

    /// Mark an incoming heartbeat (from an existing or new device).
    pub fn apply_heartbeat(&self, node_id: &str, hb: &HeartbeatPayload) {
        if let Some(mut dev) = self.devices.get_mut(node_id) {
            dev.apply_heartbeat(hb);
            // Loaded models may have shifted (e.g. after a swap) — rebuild index.
            drop(dev); // release guard before re-locking in rebuild
            self.rebuild_model_index_for(node_id);
        }
    }

    pub fn remove_device(&self, node_id: &str) {
        self.devices.remove(node_id);
        let idx = self.model_to_devices.read();
        for mut entry in idx.iter_mut() {
            entry.remove(node_id);
        }
    }

    pub fn quarantine(&self, node_id: &str, duration_secs: u64) {
        if let Some(mut dev) = self.devices.get_mut(node_id) {
            dev.quarantined_until = Some(Instant::now() + std::time::Duration::from_secs(duration_secs));
            tracing::warn!(node = node_id, "device quarantined for {}s", duration_secs);
        }
    }

    /// Run a sweep: mark stale devices unavailable, lift expired quarantines,
    /// and update `DEVICES_ELIGIBLE` gauges.
    pub fn sweep(&self) {
        let stale_threshold = self.reliability.heartbeat_stale_seconds;
        let mut stale_nodes = Vec::new();
        for mut dev in self.devices.iter_mut() {
            if dev.heartbeat_is_stale(stale_threshold) {
                stale_nodes.push(dev.node_id.clone());
                dev.capabilities.is_available = false;
            }
            if let Some(t) = dev.quarantined_until {
                if t <= Instant::now() {
                    dev.quarantined_until = None;
                }
            }
        }
        for n in stale_nodes {
            tracing::debug!(node = n, "device heartbeat stale");
        }
    }

    /// All devices currently eligible to serve `model_id`.
    pub fn eligible_devices(&self, model_id: &str) -> Vec<DeviceState> {
        self.devices
            .iter()
            .filter_map(|r| {
                let st = r.value();
                match st.is_eligible_for(model_id, self.reliability.quarantine_seconds as u32 * 100) {
                    Eligibility::Loaded | Eligibility::Swappable => Some(st.clone()),
                    _ => None,
                }
            })
            .collect()
    }

    /// Count of healthy devices that currently have `model_id` loaded.
    pub fn loaded_count(&self, model_id: &str) -> u32 {
        self.devices
            .iter()
            .filter(|r| {
                let st = r.value();
                !st.is_quarantined()
                    && st.capabilities.is_available
                    && !st.heartbeat_is_stale(self.reliability.heartbeat_stale_seconds)
                    && model_matches_any(model_id, &st.capabilities.loaded_models)
            })
            .count() as u32
    }

    fn rebuild_model_index_for(&self, node_id: &str) {
        let idx = self.model_to_devices.read();
        for mut entry in idx.iter_mut() {
            entry.remove(node_id);
        }
        let dev = match self.devices.get(node_id) {
            Some(d) => d.clone(),
            None => return,
        };
        for m in dev.capabilities.loaded_models.iter().chain(dev.capabilities.swappable_models.iter()) {
            let key = normalize_model_id(m);
            idx.entry(key).or_insert_with(HashSet::new).insert(node_id.to_string());
        }
    }
}

pub fn normalize_model_id(id: &str) -> String {
    id.rsplit('/').next().unwrap_or(id).trim().to_lowercase()
}

pub fn model_matches_any(requested: &str, loaded: &[String]) -> bool {
    let req_norm = normalize_model_id(requested);
    loaded
        .iter()
        .any(|m| normalize_model_id(m) == req_norm || m.contains(requested) || requested.contains(m))
}

/// Prior estimate for tokens/sec given a device's hardware (used until a
/// real measurement is observed).
fn hardware_tps_prior(caps: &NodeCapabilities) -> f64 {
    // Rough model: bandwidth / 5 GB (treating a typical ~5GB Q4 8B model as
    // the reference). Gives ~14 t/s at 68GB/s M1 base, ~164 t/s at 819GB/s
    // Ultra. Will be replaced by observed EWMA as requests flow.
    let bw = caps.hardware.memory_bandwidth_gbs.max(25.0);
    (bw / 5.0).max(1.0)
}
