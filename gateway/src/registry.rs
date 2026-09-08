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
    /// apmhelp confirmed-employee supply (#272): admitted to the registry
    /// but eligible ONLY for requests on the apmhelp PIN lane, never for
    /// the default lane.
    pub employee: bool,
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
    /// Conversation -> supplier affinity: follow-up turns re-prefill the
    /// whole growing context when they land on a different node (the
    /// bimodal 0.4s-vs-0.9s follow-up split in the 2026-09-08 Auto bench),
    /// while the same node reuses the slot's KV. A preference cache only:
    /// eligibility, exclusion, quarantine, heavy-hold and slot occupancy
    /// all still outrank it.
    convo_affinity: DashMap<String, (String, std::time::Instant)>,
    reliability: ReliabilityConfig,
}

/// Per-node live load, split by request weight (#247).
#[derive(Default)]
struct InFlight {
    total: std::sync::atomic::AtomicU32,
    heavy: std::sync::atomic::AtomicU32,
    /// When the current heavy hold was taken. A hold older than
    /// heavy_hold_ttl_seconds is stale by definition (the stream cap ends
    /// every heavy session within it), so admit() expires it lazily - a
    /// close path that never runs can no longer wedge a node forever.
    heavy_since: parking_lot::Mutex<Option<Instant>>,
    /// The consumer/conversation the current heavy hold(s) belong to. One
    /// consumer's own concurrent heavies (an agentic client firing a
    /// parallel build while its first turn decodes) contend only with
    /// themselves, so they share the hold up to the device's slot count.
    /// A different consumer is still refused outright.
    heavy_owner: parking_lot::Mutex<Option<String>>,
}

/// A short, stable tag for a hold owner in logs: enough to tell same from
/// different without logging the key itself (a convo key hashes prompt
/// text; a consumer id is a ledger actor).
pub(crate) fn owner_tag(owner: Option<&str>) -> String {
    match owner {
        Some(o) => {
            use sha2::Digest;
            let mut h = sha2::Sha256::new();
            h.update(o.as_bytes());
            hex::encode(&h.finalize()[..6])
        }
        None => "none".to_string(),
    }
}

impl Registry {
    pub fn new(reliability: ReliabilityConfig) -> Arc<Self> {
        Arc::new(Self {
            devices: DashMap::new(),
            model_to_devices: RwLock::new(DashMap::new()),
            in_flight: DashMap::new(),
            convo_affinity: DashMap::new(),
            reliability,
        })
    }

    const CONVO_AFFINITY_CAP: usize = 4096;

    /// The node this conversation last dispatched to, when the entry is
    /// fresh (convo_stickiness_ttl_seconds; 0 disables). Expired entries
    /// are dropped on read.
    pub fn convo_node(&self, key: &str) -> Option<String> {
        let ttl = self.reliability.convo_stickiness_ttl_seconds;
        if ttl == 0 {
            return None;
        }
        let fresh = self.convo_affinity.get(key).and_then(|e| {
            if e.value().1.elapsed() <= std::time::Duration::from_secs(ttl) {
                Some(e.value().0.clone())
            } else {
                None
            }
        });
        if fresh.is_none() {
            self.convo_affinity.remove(key);
        }
        fresh
    }

    /// Record the node that served this conversation. Bounded: past the
    /// cap, stale entries are reaped first, and a still-full map is
    /// cleared rather than grown - this is a cache, losing it is a perf
    /// miss, never a correctness issue.
    pub fn note_convo(&self, key: &str, node_id: &str) {
        if self.reliability.convo_stickiness_ttl_seconds == 0 {
            return;
        }
        if self.convo_affinity.len() >= Self::CONVO_AFFINITY_CAP {
            let ttl = std::time::Duration::from_secs(self.reliability.convo_stickiness_ttl_seconds);
            self.convo_affinity.retain(|_, v| v.1.elapsed() <= ttl);
            if self.convo_affinity.len() >= Self::CONVO_AFFINITY_CAP {
                self.convo_affinity.clear();
            }
        }
        self.convo_affinity.insert(
            key.to_string(),
            (node_id.to_string(), std::time::Instant::now()),
        );
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
    /// deaths and three 1800s deaths, all heavy-beside-heavy). It is
    /// also refused when the node's self-reported slot occupancy shows
    /// sessions this gateway did not dispatch (#273 PIN-path gap). Light
    /// requests always admit. The entry lock makes the check-and-inc one
    /// atomic step, so two racing heavy dispatches cannot both pass.
    /// Refusal leaves the counters untouched. A second heavy from the
    /// hold's own consumer shares the hold up to the device's slots.
    /// Pair with `dec_in_flight`
    /// on session close.

    pub fn admit(&self, node_id: &str, heavy: bool, owner: Option<&str>) -> bool {
        let e = self.in_flight.entry(node_id.to_string()).or_default();
        if heavy && e.heavy.load(std::sync::atomic::Ordering::SeqCst) > 0 {
            let stale = {
                let since = e.heavy_since.lock();
                (*since)
                    .map(|t| t.elapsed().as_secs() > self.reliability.heavy_hold_ttl_seconds)
                    .unwrap_or(false)
            };
            if !stale {
                // Same-consumer sharing: the hold's owner may stack its own
                // heavies up to the device's backend slots (its own choice,
                // its own contention). Anyone else is refused.
                let (shared, incumbent_tag) = {
                    let held = e.heavy_owner.lock();
                    (
                        owner.is_some() && held.as_deref() == owner,
                        owner_tag(held.as_deref()),
                    )
                };
                if !shared {
                    tracing::info!(
                        device = %node_id,
                        req_owner = %owner_tag(owner),
                        incumbent_owner = %incumbent_tag,
                        "heavy-hold: refusing co-scheduled heavy (different owner)"
                    );
                    return false;
                }
                let cap = self
                    .devices
                    .get(node_id)
                    .and_then(|d| d.capabilities.backend_slots_total)
                    .unwrap_or(2)
                    .max(1);
                if e.heavy.load(std::sync::atomic::Ordering::SeqCst) >= cap {
                    tracing::info!(
                        device = %node_id,
                        req_owner = %owner_tag(owner),
                        cap = cap,
                        "heavy-hold: owner's own slots genuinely full"
                    );
                    return false;
                }
                crate::metrics::HEAVY_HOLD_SHARED.inc();
            } else {
                // The stream cap ends every heavy session well inside the
                // TTL, so this hold's close path never ran. Expire it:
                // release both counters the leak held, count the expiry,
                // and admit below.
                e.heavy.store(0, std::sync::atomic::Ordering::SeqCst);
                *e.heavy_since.lock() = None;
                *e.heavy_owner.lock() = None;
                let prev = e.total.swap(0, std::sync::atomic::Ordering::SeqCst);
                crate::metrics::HEAVY_HOLD_EXPIRED.inc();
                crate::metrics::HEAVY_HOLDS
                    .with_label_values(&[node_id])
                    .set(0);
                tracing::warn!(
                    device = %node_id,
                    leaked_total = prev,
                    "heavy hold exceeded TTL with no close: expiring the stale hold"
                );
            }
        }
        if heavy {
            // #273: a PIN-path (node-direct) session holds llama.cpp slots
            // with no gateway-visible in-flight entry. When the node's
            // self-reported slot occupancy (#288) exceeds what this gateway
            // can account for, external sessions are resident - refuse the
            // heavy rather than stack heavy-beside-heavy (the 05:03-05:16Z
            // window: two starved requests died at the 300s cap beside
            // invisible 33k-89k PIN heavies). Stale by one heartbeat, so a
            // just-drained heavy may cost one interval's refusal - safe
            // direction. Light admission is unchanged: the light-beside-
            // heavy policy is #270's open question, not this fix.
            if let Some(dev) = self.devices.get(node_id) {
                if let Some(busy) = dev.capabilities.backend_slots_busy {
                    let accounted = e.total.load(std::sync::atomic::Ordering::SeqCst);
                    if busy > accounted {
                        tracing::info!(
                            device = %node_id,
                            req_owner = %owner_tag(owner),
                            busy = busy,
                            accounted = accounted,
                            "heavy-hold: refusing beside unaccounted external sessions"
                        );
                        return false;
                    }
                }
            }
        }
        e.total.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
        if heavy {
            if e.heavy.fetch_add(1, std::sync::atomic::Ordering::SeqCst) == 0 {
                *e.heavy_owner.lock() = owner.map(str::to_string);
                tracing::info!(
                    device = %node_id,
                    owner = %owner_tag(owner),
                    "heavy-hold: acquired"
                );
            } else {
                tracing::info!(
                    device = %node_id,
                    owner = %owner_tag(owner),
                    "heavy-hold: shared with its owner"
                );
            }
            *e.heavy_since.lock() = Some(Instant::now());
            crate::metrics::HEAVY_HOLDS
                .with_label_values(&[node_id])
                .set(e.heavy.load(std::sync::atomic::Ordering::SeqCst) as i64);
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
                if hprev <= 1 {
                    let gone = e.heavy_owner.lock().take();
                    e.heavy.store(0, std::sync::atomic::Ordering::SeqCst);
                    *e.heavy_since.lock() = None;
                    tracing::info!(
                        device = %node_id,
                        owner = %owner_tag(gone.as_deref()),
                        "heavy-hold: released"
                    );
                }
                crate::metrics::HEAVY_HOLDS
                    .with_label_values(&[node_id])
                    .set(e.heavy.load(std::sync::atomic::Ordering::SeqCst) as i64);
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
        self.upsert_device_with_class(node_id, display_name, caps, false);
    }

    /// Upsert with an explicit supply class (#272). The class is
    /// config-driven, so every upsert restates it: a node that leaves the
    /// employee set reverts to fleet on its next discover response.
    pub fn upsert_device_with_class(
        &self,
        node_id: String,
        display_name: String,
        caps: NodeCapabilities,
        employee: bool,
    ) {
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
                    employee: false,
                });
            entry.display_name = display_name;
            entry.capabilities = caps;
            entry.employee = employee;
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

    /// All devices currently eligible to serve `model_id` for the
    /// DEFAULT lane (fleet supply only - employee devices are excluded,
    /// #272).
    pub fn eligible_devices(&self, model_id: &str) -> Vec<DeviceState> {
        self.eligible_supply(model_id, false)
    }

    /// Devices currently eligible to serve `model_id`. With
    /// `include_employee`, apmhelp confirmed-employee supply is included
    /// (the caller owns lane authorization and any priority ordering).
    pub fn eligible_supply(&self, model_id: &str, include_employee: bool) -> Vec<DeviceState> {
        self.devices
            .iter()
            .filter_map(|r| {
                let st = r.value();
                if st.employee && !include_employee {
                    return None;
                }
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
            backend_slots_busy: None,
            backend_slots_total: None,
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
    fn employee_supply_is_lane_scoped_and_restated_on_upsert() {
        let registry = Registry::new(ReliabilityConfig::default());
        registry.upsert_device("fleet-a".into(), "F".into(), caps(vec!["m"], true));
        registry.upsert_device_with_class("emp-b".into(), "E".into(), caps(vec!["m"], true), true);

        // Default lane: fleet only.
        let default_pool = registry.eligible_devices("m");
        assert_eq!(default_pool.len(), 1);
        assert_eq!(default_pool[0].node_id, "fleet-a");
        // Lane pool: both, with the employee tagged.
        let lane_pool = registry.eligible_supply("m", true);
        assert_eq!(lane_pool.len(), 2);
        assert!(lane_pool.iter().any(|d| d.employee && d.node_id == "emp-b"));
        // The class is restated on every upsert: leaving the employee set
        // reverts the node to fleet supply on its next discover.
        registry.upsert_device_with_class("emp-b".into(), "E".into(), caps(vec!["m"], true), false);
        assert_eq!(registry.eligible_devices("m").len(), 2);
    }

    #[test]
    fn heavy_hold_past_ttl_expires_and_readmits() {
        // 2026-09-08, 512g8: a client stream died, the close path never
        // ran, and the leaked hold refused every heavy for ~75 min while
        // the node sat idle. A hold older than the TTL is stale by
        // definition - admit() must expire it and let the new heavy in.
        let registry = Registry::new(ReliabilityConfig {
            heavy_hold_ttl_seconds: 60,
            ..ReliabilityConfig::default()
        });
        assert!(registry.admit("node-a", true, None));
        {
            let e = registry.in_flight.get("node-a").expect("entry");
            *e.heavy_since.lock() = Some(Instant::now() - std::time::Duration::from_secs(120));
        }
        // The stale hold no longer refuses - and the leak's total is released.
        assert!(registry.admit("node-a", true, None));
        assert_eq!(registry.heavy_in_flight("node-a"), 1);
        assert_eq!(registry.in_flight("node-a"), 1);
    }

    #[test]
    fn heavy_hold_within_ttl_still_refuses() {
        let registry = Registry::new(ReliabilityConfig {
            heavy_hold_ttl_seconds: 1900,
            ..ReliabilityConfig::default()
        });
        assert!(registry.admit("node-a", true, None));
        assert!(!registry.admit("node-a", true, None));
        assert_eq!(registry.heavy_in_flight("node-a"), 1);
    }

    #[test]
    fn heavy_hold_released_on_normal_close_clears_timestamp() {
        let registry = Registry::new(ReliabilityConfig::default());
        assert!(registry.admit("node-a", true, None));
        registry.dec_in_flight("node-a", true);
        assert_eq!(registry.heavy_in_flight("node-a"), 0);
        {
            let e = registry.in_flight.get("node-a").expect("entry");
            assert!(e.heavy_since.lock().is_none());
        }
        assert!(registry.admit("node-a", true, None));
    }

    #[test]
    fn same_consumer_heavies_share_the_hold_up_to_slots() {
        // 2026-09-08, qqqs grounded: one opencode session fired a parallel
        // build request while its own heavy held the device, and the hold
        // refused it as if it were a different consumer - four refusals,
        // zero progress. The owner's own heavies co-reside up to slots.
        let registry = Registry::new(ReliabilityConfig::default());
        let mut c = caps(vec!["m"], true);
        c.backend_slots_total = Some(2);
        registry.upsert_device("node-a".into(), "A".into(), c);

        assert!(registry.admit("node-a", true, Some("qqqs")));
        // the owner's second heavy shares the hold
        assert!(registry.admit("node-a", true, Some("qqqs")));
        assert_eq!(registry.heavy_in_flight("node-a"), 2);
        // slots full: even the owner stops there
        assert!(!registry.admit("node-a", true, Some("qqqs")));
        // a different consumer is refused while any heavy is resident
        assert!(!registry.admit("node-a", true, Some("hz4g")));
        // releasing one frees exactly one
        registry.dec_in_flight("node-a", true);
        assert_eq!(registry.heavy_in_flight("node-a"), 1);
        // the last release clears ownership, so the next heavy starts fresh
        registry.dec_in_flight("node-a", true);
        assert!(registry.admit("node-a", true, Some("hz4g")));
    }

    #[test]
    fn anonymous_heavies_never_share() {
        // no owner key on either side: the hold behaves exactly as before
        let registry = Registry::new(ReliabilityConfig::default());
        assert!(registry.admit("node-a", true, None));
        assert!(!registry.admit("node-a", true, None));
    }

    #[test]
    fn heavy_hold_admission_refuses_second_heavy_and_balances() {
        let registry = Registry::new(ReliabilityConfig::default());
        registry.upsert_device("node-a".into(), "A".into(), caps(vec!["m"], true));
        registry.upsert_device("node-b".into(), "B".into(), caps(vec!["m"], true));

        assert!(registry.admit("node-a", true, None));
        // Second heavy on the same device is refused, counters untouched.
        assert!(!registry.admit("node-a", true, None));
        assert_eq!(registry.in_flight("node-a"), 1);
        assert_eq!(registry.heavy_in_flight("node-a"), 1);
        // ...but the same heavy may still land on another device.
        assert!(registry.admit("node-b", true, None));
        assert_eq!(registry.heavy_in_flight("node-b"), 1);
        // Light traffic is unaffected by an in-flight heavy.
        assert!(registry.admit("node-a", false, None));
        assert_eq!(registry.in_flight("node-a"), 2);
        // Decrement tracks the class it was admitted with.
        registry.dec_in_flight("node-a", true);
        assert_eq!(registry.in_flight("node-a"), 1);
        assert_eq!(registry.heavy_in_flight("node-a"), 0);
        registry.dec_in_flight("node-a", false);
        assert_eq!(registry.in_flight("node-a"), 0);
    }

    #[test]
    fn heavy_hold_admission_refuses_when_reported_slots_exceed_accounted() {
        let registry = Registry::new(ReliabilityConfig::default());
        let mut pin_caps = caps(vec!["m"], true);
        pin_caps.backend_slots_busy = Some(1);
        pin_caps.backend_slots_total = Some(4);
        registry.upsert_device("node-a".into(), "A".into(), pin_caps);

        // A PIN-path heavy holds a slot with no gateway-visible in-flight:
        // reported busy (1) exceeds accounted (0) - the heavy is refused.
        assert!(!registry.admit("node-a", true, None));
        assert_eq!(registry.in_flight("node-a"), 0);
        // Light traffic still admits beside reported occupancy.
        assert!(registry.admit("node-a", false, None));
        // Reported busy (1) now equals accounted (1): no external session,
        // so a heavy may land.
        assert!(registry.admit("node-a", true, None));
        registry.dec_in_flight("node-a", true);
        registry.dec_in_flight("node-a", false);

        // A node whose heartbeats carry no occupancy (older build) keeps
        // the old behaviour: gateway-visible heavies only.
        registry.upsert_device("node-b".into(), "B".into(), caps(vec!["m"], true));
        assert!(registry.admit("node-b", true, None));
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

    #[test]
    fn convo_affinity_records_and_looks_up_fresh_entry() {
        let r = Registry::new(ReliabilityConfig::default());
        r.note_convo("conv-key", "node-a");
        assert_eq!(r.convo_node("conv-key").as_deref(), Some("node-a"));
        assert_eq!(r.convo_node("unknown"), None);
    }

    #[test]
    fn convo_affinity_disabled_at_zero_ttl() {
        let mut cfg = ReliabilityConfig::default();
        cfg.convo_stickiness_ttl_seconds = 0;
        let r = Registry::new(cfg);
        r.note_convo("conv-key", "node-a");
        assert_eq!(r.convo_node("conv-key"), None);
    }

    #[tokio::test]
    async fn convo_affinity_expires_after_ttl() {
        let mut cfg = ReliabilityConfig::default();
        cfg.convo_stickiness_ttl_seconds = 1;
        let r = Registry::new(cfg);
        r.note_convo("conv-key", "node-a");
        assert!(r.convo_node("conv-key").is_some());
        tokio::time::sleep(std::time::Duration::from_millis(1100)).await;
        assert_eq!(r.convo_node("conv-key"), None);
    }

    #[test]
    fn convo_affinity_stays_bounded_at_cap() {
        let r = Registry::new(ReliabilityConfig::default());
        for i in 0..(Registry::CONVO_AFFINITY_CAP + 10) {
            r.note_convo(&format!("key-{}", i), "node-a");
        }
        assert!(r.convo_affinity.len() <= Registry::CONVO_AFFINITY_CAP);
    }
}
