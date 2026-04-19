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
    ) -> Option<&'a DeviceState> {
        // Two-stage: primary sort key is live in-flight count (least-loaded
        // wins), tiebreak on the score function below. Without a strict
        // primary on in-flight, TPS priors on an M3 Ultra dwarfed the small
        // headroom penalty from 1-2 outstanding requests and every dispatch
        // went to the same node even at 1 RPS.
        let mut best: Option<(u32, f64, &DeviceState)> = None;

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
            let in_flight = registry.in_flight(&d.node_id);
            if in_flight >= self.cfg.max_queue_depth {
                continue;
            }
            let score = self.score(d, loaded, in_flight);
            if score <= 0.0 {
                continue;
            }
            let beat = match &best {
                None => true,
                Some((b_inflight, b_score, _)) => {
                    in_flight < *b_inflight || (in_flight == *b_inflight && score > *b_score)
                }
            };
            if beat {
                best = Some((in_flight, score, d));
            }
        }

        best.map(|(_, _, d)| d)
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
