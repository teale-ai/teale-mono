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
    /// Set when the relay reported peerLeft. The device stays in the
    /// registry (and its models stay listed) for the departed grace
    /// window - a transient flap must not vanish a model for every
    /// consumer (#220). The sweep removes it for real once the grace
    /// expires; any liveness signal clears it.
    pub departed_at: Option<Instant>,
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

    pub fn is_departed(&self) -> bool {
        self.departed_at.is_some()
    }

    /// Should this device's models stay in the catalog (live-model
    /// resolution and /v1/models listing)? Quarantine gates DISPATCH, never
    /// catalog presence: a quarantined device's models stay listed and
    /// resolvable so sole-supplier backoff surfaces as a retriable 503
    /// (no eligible device) instead of a fatal-looking 404 "model not
    /// found" for every consumer (#239; supersedes the #220 departed-grace
    /// exception, which existed only to paper over quarantine hiding).
    pub fn catalog_visible(&self, stale_after_secs: u64) -> bool {
        self.capabilities.is_available && !self.heartbeat_is_stale(stale_after_secs)
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
        self.departed_at = None;
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

/// Fleet-wide availability tier for a given model. Ordered ready > warm > cold.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ModelAvailability {
    /// Loaded in RAM on ≥1 healthy device — instant.
    Ready,
    /// Weights cached on disk on ≥1 device — seconds to swap in.
    Warm,
    /// No device has it, but ≥1 device can fit the estimated size — minutes.
    Cold,
    /// No healthy device can fit the model.
    Unavailable,
}

impl ModelAvailability {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Ready => "ready",
            Self::Warm => "warm",
            Self::Cold => "cold",
            Self::Unavailable => "unavailable",
        }
    }
}

pub struct Registry {
    /// Every known device (even quarantined).
    devices: DashMap<String, DeviceState>,
    /// Reverse index: model_id (normalized) → set of node_ids.
    /// Maintained in sync with device.capabilities.loaded_models /
    /// swappable_models. `RwLock` inner for batch updates during
    /// discover responses.
    model_to_devices: RwLock<dashmap::DashMap<String, HashSet<String>>>,
    /// Live in-flight request count per node, split by weight. The total
    /// is the scheduler's real picture of load — heartbeat-reported
    /// queue_depth is ≥10s stale and caused the "hot-spot one node"
    /// behaviour under rapid dispatch. The heavy split feeds heavy-hold
    /// admission (#247): two heavy requests on one box starve each
    /// other's decode until both hit the stream cap, so a heavy is only
    /// admitted to a node with no in-flight heavy.
    in_flight: DashMap<String, InFlight>,
    reliability: ReliabilityConfig,
}

/// Per-node live load, split by request weight (#247).
#[derive(Default)]
struct InFlight {
    total: std::sync::atomic::AtomicU32,
    heavy: std::sync::atomic::AtomicU32,
}

impl Registry {
    pub fn new(reliability: ReliabilityConfig) -> Arc<Self> {
        Arc::new(Self {
            devices: DashMap::new(),
            model_to_devices: RwLock::new(DashMap::new()),
            in_flight: DashMap::new(),
            reliability,
        })
    }

    pub fn device_count(&self) -> usize {
        self.devices.len()
    }

    pub fn snapshot_devices(&self) -> Vec<DeviceState> {
        self.devices.iter().map(|r| r.value().clone()).collect()
    }

    /// Atomically admit one dispatched request (#247 heavy-hold). A HEAVY
    /// request is refused when the node already carries an in-flight
    /// heavy: two heavies on one box share decode and starve each other
    /// until both die at the stream cap (Citadel measured five 900s
    /// deaths and three 1800s deaths, all heavy-beside-heavy). Light
    /// requests always admit. The entry lock makes the check-and-inc one
    /// atomic step, so two racing heavy dispatches cannot both pass.
    /// Refusal leaves the counters untouched. Pair with `dec_in_flight`
    /// on session close.
    pub fn admit(&self, node_id: &str, heavy: bool) -> bool {
        let e = self
            .in_flight
            .entry(node_id.to_string())
            .or_default();
        if heavy && e.heavy.load(std::sync::atomic::Ordering::SeqCst) > 0 {
            return false;
        }
        e.total.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
        if heavy {
            e.heavy.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
        }
        true
    }

    pub fn dec_in_flight(&self, node_id: &str, heavy: bool) -> u32 {
        if let Some(e) = self.in_flight.get(node_id) {
            let prev = e.total.fetch_sub(1, std::sync::atomic::Ordering::SeqCst);
            if prev == 0 {
                // Shouldn't happen — reset to 0 to avoid wrap-around.
                e.total.store(0, std::sync::atomic::Ordering::SeqCst);
            }
            if heavy {
                let hprev = e.heavy.fetch_sub(1, std::sync::atomic::Ordering::SeqCst);
                if hprev == 0 {
                    e.heavy.store(0, std::sync::atomic::Ordering::SeqCst);
                }
            }
            prev.saturating_sub(1)
        } else {
            0
        }
    }

    pub fn in_flight(&self, node_id: &str) -> u32 {
        self.in_flight
            .get(node_id)
            .map(|e| e.total.load(std::sync::atomic::Ordering::Relaxed))
            .unwrap_or(0)
    }

    /// Live heavy in-flight count for a node (see `admit`).
    pub fn heavy_in_flight(&self, node_id: &str) -> u32 {
        self.in_flight
            .get(node_id)
            .map(|e| e.heavy.load(std::sync::atomic::Ordering::Relaxed))
            .unwrap_or(0)
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
                    departed_at: None,
                    ewma_tokens_per_second: hardware_tps_prior(&caps),
                    live: LiveStats::fresh(),
                });
            entry.display_name = display_name;
            entry.capabilities = caps;
            entry.last_seen = now;
            // A discover response from this peer is a rejoin: clear any
            // departed mark instantly rather than waiting out the grace.
            entry.departed_at = None;
            // Treat an inbound discover response (which only arrives because
            // the relay heard from this peer recently) as a liveness signal.
            // Without this, a peer that doesn't actively send heartbeat
            // messages to the gateway is marked stale after a few dozen
            // seconds even though it's perfectly reachable — and the Mac
            // app supply path currently only re-registers via discover,
            // never via explicit heartbeat.
            entry.last_heartbeat = now;
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

    /// Relay said peerLeft. Do NOT remove the device: a transient relay
    /// flap would vanish its models from the catalog for every consumer
    /// (Sep 6: GLM-5.3-flash gone 11 min while 512g8 flapped on a ~40s
    /// cadence). Mark it departed; the sweep removes it for real after
    /// `departed_grace_seconds` with no rejoin (#220).
    ///
    /// The device keeps its last-known availability during grace, so the
    /// catalog stays stable. A dispatch attempted mid-flap fails fast via
    /// the relay's peer_not_found error, which quarantines the node through
    /// the existing path - that is the safety valve, and it self-clears.
    pub fn mark_departed(&self, node_id: &str) {
        if let Some(mut dev) = self.devices.get_mut(node_id) {
            if dev.departed_at.is_none() {
                dev.departed_at = Some(Instant::now());
                tracing::info!(
                    node = node_id,
                    "device departed; {}s grace before catalog removal",
                    self.reliability.departed_grace_seconds
                );
            }
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
            dev.quarantined_until =
                Some(Instant::now() + std::time::Duration::from_secs(duration_secs));
            tracing::warn!(node = node_id, "device quarantined for {}s", duration_secs);
        }
    }

    /// Run a sweep: mark stale devices unavailable, lift expired quarantines,
    /// and update `DEVICES_ELIGIBLE` gauges.
    pub fn sweep(&self) {
        let stale_threshold = self.reliability.heartbeat_stale_seconds;
        // Devices whose departed grace expired are removed for real.
        let grace = std::time::Duration::from_secs(self.reliability.departed_grace_seconds);
        let departed: Vec<String> = self
            .devices
            .iter()
            .filter(|r| r.departed_at.is_some_and(|t| t.elapsed() >= grace))
            .map(|r| r.node_id.clone())
            .collect();
        for node_id in departed {
            tracing::info!(
                node = node_id,
                "departed grace expired; removing device from registry"
            );
            self.remove_device(&node_id);
        }
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
                if st.heartbeat_is_stale(self.reliability.heartbeat_stale_seconds) {
                    return None;
                }
                match st.is_eligible_for(model_id, self.reliability.quarantine_seconds as u32 * 100)
                {
                    Eligibility::Loaded | Eligibility::Swappable => Some(st.clone()),
                    _ => None,
                }
            })
            .collect()
    }

    /// Tier of availability for a model across the fleet:
    ///   Ready — at least one healthy device has it loaded right now
    ///   Warm  — no one has it loaded, but a device has the weights on disk
    ///   Cold  — no device has it, but some device could fit it (≥ size_gb)
    ///   Unavailable — no healthy device can even fit the model
    ///
    /// Skips quarantined, unavailable, and stale-heartbeat devices.
    pub fn model_availability(&self, model_id: &str, size_gb: f64) -> ModelAvailability {
        let mut any_swappable = false;
        let mut any_fits = false;
        for r in self.devices.iter() {
            let st = r.value();
            if st.is_quarantined()
                || !st.capabilities.is_available
                || st.heartbeat_is_stale(self.reliability.heartbeat_stale_seconds)
            {
                continue;
            }
            if model_matches_any(model_id, &st.capabilities.loaded_models) {
                return ModelAvailability::Ready;
            }
            if model_matches_any(model_id, &st.capabilities.swappable_models) {
                any_swappable = true;
            }
            if st.capabilities.max_model_size_gb >= size_gb {
                any_fits = true;
            }
        }
        if any_swappable {
            ModelAvailability::Warm
        } else if any_fits {
            ModelAvailability::Cold
        } else {
            ModelAvailability::Unavailable
        }
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

    /// Count of healthy devices that are actively supplying inference.
    pub fn supplying_device_count(&self) -> u32 {
        self.devices
            .iter()
            .filter(|r| {
                let st = r.value();
                !st.is_quarantined()
                    && st.capabilities.is_available
                    && !st.heartbeat_is_stale(self.reliability.heartbeat_stale_seconds)
                    && !st.capabilities.loaded_models.is_empty()
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
        for m in dev
            .capabilities
            .loaded_models
            .iter()
            .chain(dev.capabilities.swappable_models.iter())
        {
            let key = normalize_model_id(m);
            idx.entry(key).or_default().insert(node_id.to_string());
        }
    }
}

pub fn normalize_model_id(id: &str) -> String {
    id.rsplit('/').next().unwrap_or(id).trim().to_lowercase()
}

pub fn model_matches_any(requested: &str, loaded: &[String]) -> bool {
    let req_norm = normalize_model_id(requested);
    loaded.iter().any(|m| {
        normalize_model_id(m) == req_norm || m.contains(requested) || requested.contains(m)
    })
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

#[cfg(test)]
mod tests {
    use super::*;

    fn caps(loaded_models: Vec<&str>, is_available: bool) -> NodeCapabilities {
        NodeCapabilities {
            hardware: teale_protocol::HardwareCapability {
                chip_family: "m3Ultra".to_string(),
                chip_name: "Apple M3 Ultra".to_string(),
                total_ram_gb: 512.0,
                gpu_core_count: 60,
                memory_bandwidth_gbs: 819.0,
                tier: 1,
                gpu_backend: Some("metal".to_string()),
                platform: Some("macOS".to_string()),
                gpu_vram_gb: None,
            },
            loaded_models: loaded_models.into_iter().map(str::to_string).collect(),
            max_model_size_gb: 1024.0,
            is_available,
            ptn_ids: None,
            swappable_models: Vec::new(),
            max_concurrent_requests: Some(4),
            effective_context: Some(131072),
            on_ac_power: None,
        }
    }

    #[test]
    fn supplying_device_count_only_includes_healthy_active_suppliers() {
        let registry = Registry::new(ReliabilityConfig::default());
        registry.upsert_device(
            "node-a".to_string(),
            "A".to_string(),
            caps(vec!["teale/auto"], true),
        );
        registry.upsert_device(
            "node-b".to_string(),
            "B".to_string(),
            caps(vec!["moonshotai/kimi-k2.6"], true),
        );
        registry.upsert_device(
            "node-c".to_string(),
            "C".to_string(),
            caps(Vec::new(), true),
        );
        registry.upsert_device(
            "node-d".to_string(),
            "D".to_string(),
            caps(vec!["nousresearch/hermes-3-llama-3.1-8b"], false),
        );
        registry.quarantine("node-b", 60);

        assert_eq!(registry.supplying_device_count(), 1);
    }

    #[test]
    fn eligible_devices_excludes_stale_heartbeat_nodes() {
        let reliability = ReliabilityConfig {
            heartbeat_stale_seconds: 0,
            ..ReliabilityConfig::default()
        };
        let registry = Registry::new(reliability);
        registry.upsert_device(
            "node-a".to_string(),
            "A".to_string(),
            caps(vec!["teale/auto"], true),
        );
        {
            let mut dev = registry.devices.get_mut("node-a").expect("device present");
            dev.last_heartbeat = Instant::now() - std::time::Duration::from_secs(1);
        }

        assert!(registry.eligible_devices("teale/auto").is_empty());
    }

    #[test]
    fn heavy_hold_admission_refuses_second_heavy_and_balances() {
        let registry = Registry::new(ReliabilityConfig::default());
        registry.upsert_device("node-a".into(), "A".into(), caps(vec!["m"], true));
        registry.upsert_device("node-b".into(), "B".into(), caps(vec!["m"], true));

        assert!(registry.admit("node-a", true));
        // Second heavy on the same device is refused, counters untouched.
        assert!(!registry.admit("node-a", true));
        assert_eq!(registry.in_flight("node-a"), 1);
        assert_eq!(registry.heavy_in_flight("node-a"), 1);
        // ...but the same heavy may still land on another device.
        assert!(registry.admit("node-b", true));
        assert_eq!(registry.heavy_in_flight("node-b"), 1);
        // Light traffic is unaffected by an in-flight heavy.
        assert!(registry.admit("node-a", false));
        assert_eq!(registry.in_flight("node-a"), 2);
        // Decrement tracks the class it was admitted with.
        registry.dec_in_flight("node-a", true);
        assert_eq!(registry.in_flight("node-a"), 1);
        assert_eq!(registry.heavy_in_flight("node-a"), 0);
        registry.dec_in_flight("node-a", false);
        assert_eq!(registry.in_flight("node-a"), 0);
    }

    #[test]
    fn departed_device_survives_grace_then_is_removed() {
        let reliability = ReliabilityConfig {
            departed_grace_seconds: 180,
            ..ReliabilityConfig::default()
        };
        let registry = Registry::new(reliability);
        registry.upsert_device(
            "node-a".into(),
            "A".into(),
            caps(vec!["glm-5.3-flash"], true),
        );

        registry.mark_departed("node-a");
        // Still in the registry; model still listed during grace.
        assert!(registry
            .snapshot_devices()
            .iter()
            .any(|d| d.node_id == "node-a"));
        assert_eq!(registry.loaded_count("glm-5.3-flash"), 1);
        registry.sweep();
        assert!(registry
            .snapshot_devices()
            .iter()
            .any(|d| d.node_id == "node-a"));

        // Simulate grace expiry by backdating the departure.
        {
            let mut dev = registry.devices.get_mut("node-a").unwrap();
            dev.departed_at = Some(Instant::now() - std::time::Duration::from_secs(181));
        }
        registry.sweep();
        assert!(registry
            .snapshot_devices()
            .iter()
            .all(|d| d.node_id != "node-a"));
        assert_eq!(registry.loaded_count("glm-5.3-flash"), 0);
    }

    #[test]
    fn rejoin_during_grace_clears_departed() {
        let registry = Registry::new(ReliabilityConfig::default());
        registry.upsert_device("node-a".into(), "A".into(), caps(vec!["m"], true));
        registry.mark_departed("node-a");
        assert!(registry.devices.get("node-a").unwrap().is_departed());

        // Rejoin via discover upsert restores instantly.
        registry.upsert_device("node-a".into(), "A".into(), caps(vec!["m"], true));
        assert!(!registry.devices.get("node-a").unwrap().is_departed());
        registry.sweep();
        assert!(registry
            .snapshot_devices()
            .iter()
            .any(|d| d.node_id == "node-a"));
    }
}
