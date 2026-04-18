//! Device selection.
//!
//! Score function:
//!   score = ewma_tps
//!         × (1 − queue_depth / max_queue)
//!         × (throttle_level / 100)
//!         × thermal_weight
//!         × (1.0 if loaded else swap_penalty)

use crate::config::SchedulerConfig;
use crate::registry::{DeviceState, Eligibility};

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
    ) -> Option<&'a DeviceState> {
        let mut best: Option<(f64, &DeviceState)> = None;

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
            let score = self.score(d, loaded);
            if score <= 0.0 {
                continue;
            }
            match best {
                Some((b, _)) if b >= score => {}
                _ => best = Some((score, d)),
            }
        }

        best.map(|(_, d)| d)
    }

    fn score(&self, d: &DeviceState, loaded: bool) -> f64 {
        let tps = d.ewma_tokens_per_second.max(1.0);
        let queue_norm = (d.live.queue_depth as f64 / self.cfg.max_queue_depth as f64).min(1.0);
        let headroom = (1.0 - queue_norm).max(0.0);
        let throttle = (d.live.throttle_level as f64 / 100.0).clamp(0.0, 1.0);
        let thermal = d.live.thermal_level.weight();
        let load_factor = if loaded { 1.0 } else { self.cfg.swap_penalty };

        tps.powf(self.cfg.tps_weight) * headroom * throttle * thermal * load_factor
    }
}
