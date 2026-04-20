//! Device selection.
//!
//! Score function:
//!   score = ewma_tps
//!         × (1 − effective_queue / max_queue)
//!         × (throttle_level / 100)
//!         × thermal_weight
//!         × (1.0 if loaded else swap_penalty)
//!
//! `effective_queue` = max(heartbeat_queue_depth, in_flight_count).
//! in_flight is tracked live in the registry, bumped on dispatch and
//! decremented on session close. Using it here is what prevents the
//! scheduler from over-selecting the fastest-prior device under rapid
//! dispatch, where the ≥10s-stale heartbeat queue reads 0 for every
//! node regardless of how many requests the gateway just sent.

use crate::config::SchedulerConfig;
use crate::registry::{DeviceState, Eligibility, Registry};

pub struct Scheduler {
    cfg: SchedulerConfig,
}

impl Scheduler {
    pub fn new(cfg: SchedulerConfig) -> Self {
        Self { cfg }
    }

    pub fn pick<'a>(
        &self,
        candidates: &'a [DeviceState],
        model_id: &str,
        exclude: &[String],
        registry: &Registry,
        min_context: Option<u32>,
    ) -> Option<&'a DeviceState> {
        // Two-stage:
        //   1. Filter to eligible, non-excluded, non-overloaded, non-zero-score
        //      candidates, AND any whose advertised effective_context can't
        //      cover the request's min_context requirement (when known).
        //   2. Primary sort on in_flight ASC (least-loaded wins). Collect all
        //      tied-best candidates, then pick one at random. Pure least-
        //      in-flight with a deterministic score tiebreak pinned every
        //      request to the same TPS-best node whenever in_flight = 0
        //      across all candidates (e.g. when requests complete faster
        //      than the next arrives, which is exactly the pattern we
        //      want to handle: 1 RPS with p99 total latency < 4s).
        let mut viable: Vec<(u32, bool, f64, &DeviceState)> = Vec::new();

        for d in candidates {
            if exclude.iter().any(|e| e == &d.node_id) {
                continue;
            }
            let elig = d.is_eligible_for(model_id, self.cfg.max_queue_depth);
            let loaded = match elig {
                Eligibility::Loaded => true,
                Eligibility::Swappable => false,
                _ => continue,
            };
            // Context filter: if the request declared a min context, drop
            // any node whose llama-server was launched with --ctx-size below
            // it. Nodes that omit effective_context are older/legacy — we
            // trust them (absent == unknown, not unfit), since the field is
            // additive.
            if let Some(need) = min_context {
                if let Some(have) = d.capabilities.effective_context {
                    if have < need {
                        continue;
                    }
                }
            }
            let in_flight = registry.in_flight(&d.node_id);
            if in_flight >= self.cfg.max_queue_depth {
                continue;
            }
            let score = self.score(d, loaded, in_flight);
            if score <= 0.0 {
                continue;
            }
            viable.push((in_flight, loaded, score, d));
        }

        if viable.is_empty() {
            return None;
        }

        // Least in-flight wins; score is informational only (we no longer
        // use it to tiebreak, since the TPS-prior delta dominated the small
        // headroom penalty and killed spread at low RPS).
        let min_inflight = viable.iter().map(|(n, _, _, _)| *n).min()?;
        // Among the tied set, prefer loaded over swappable — pulling weights
        // off disk is a multi-second hit, whereas random-picking a swap device
        // when a loaded one is free throws away that headstart. If any loaded
        // devices are tied on in_flight, restrict the tiebreak pool to them.
        let any_loaded = viable
            .iter()
            .any(|(n, loaded, _, _)| *n == min_inflight && *loaded);
        let tied: Vec<_> = viable
            .into_iter()
            .filter(|(n, loaded, _, _)| *n == min_inflight && (!any_loaded || *loaded))
            .map(|(_, _, _, d)| d)
            .collect();

        if tied.len() == 1 {
            return Some(tied[0]);
        }
        // Randomize among equivalent picks so back-to-back requests at
        // steady state fan out across eligible devices.
        use rand::seq::SliceRandom;
        let mut rng = rand::thread_rng();
        tied.choose(&mut rng).copied()
    }

    fn score(&self, d: &DeviceState, loaded: bool, in_flight: u32) -> f64 {
        let tps = d.ewma_tokens_per_second.max(1.0);
        let effective_queue = (d.live.queue_depth).max(in_flight);
        let queue_norm = (effective_queue as f64 / self.cfg.max_queue_depth as f64).min(1.0);
        let headroom = (1.0 - queue_norm).max(0.0);
        let throttle = (d.live.throttle_level as f64 / 100.0).clamp(0.0, 1.0);
        let thermal = d.live.thermal_level.weight();
        let load_factor = if loaded { 1.0 } else { self.cfg.swap_penalty };

        tps.powf(self.cfg.tps_weight) * headroom * throttle * thermal * load_factor
    }
}
