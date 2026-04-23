//! In-memory per-model TTFT/TPS ring buffers with percentile snapshots.
//!
//! Complements the Prometheus histograms in `metrics.rs` by giving the
//! `/v1/models` JSON handler cheap, exact percentiles over a recent window so
//! clients (and the `/try/:token` landing page) can display "how fast is this
//! model serving right now" without scraping Prometheus.

use std::collections::VecDeque;
use std::sync::Mutex;
use std::time::{Duration, Instant};

use dashmap::DashMap;

use teale_protocol::openai::ModelMetrics;

/// Cap on per-model ring capacity. Bounded memory even if one model gets
/// every request — ~500 samples × ~24 bytes = ~12 KB per hot model.
const MAX_SAMPLES_PER_MODEL: usize = 500;
/// Samples older than this are excluded from percentile computation.
const SAMPLE_MAX_AGE: Duration = Duration::from_secs(3600);

#[derive(Debug, Clone, Copy)]
struct Sample {
    at: Instant,
    ttft_ms: u32,
    /// Tokens per second during generation (first-token → last-token).
    /// `None` when completion_tokens wasn't reported by the supplier.
    tps: Option<f32>,
}

/// Tracks recent request timings per model.
#[derive(Default)]
pub struct ModelMetricsTracker {
    rings: DashMap<String, Mutex<VecDeque<Sample>>>,
}

impl ModelMetricsTracker {
    pub fn new() -> Self {
        Self::default()
    }

    /// Record one successful completion.
    /// `gen_duration_ms` is the elapsed time from first token to last token;
    /// pass 0 (or completion_tokens=None) to skip the TPS side of the sample.
    pub fn record(
        &self,
        model_id: &str,
        ttft_ms: u32,
        completion_tokens: Option<u64>,
        gen_duration_ms: u64,
    ) {
        let tps = match (completion_tokens, gen_duration_ms) {
            (Some(t), d) if t > 0 && d > 0 => Some((t as f64 * 1000.0 / d as f64) as f32),
            _ => None,
        };
        let sample = Sample {
            at: Instant::now(),
            ttft_ms,
            tps,
        };
        let entry = self
            .rings
            .entry(model_id.to_string())
            .or_insert_with(|| Mutex::new(VecDeque::with_capacity(MAX_SAMPLES_PER_MODEL)));
        let mut ring = entry.value().lock().expect("ring mutex poisoned");
        if ring.len() >= MAX_SAMPLES_PER_MODEL {
            ring.pop_front();
        }
        ring.push_back(sample);
    }

    /// Percentile snapshot for one model; `None` if no fresh samples exist.
    pub fn snapshot(&self, model_id: &str) -> Option<ModelMetrics> {
        let entry = self.rings.get(model_id)?;
        let ring = entry.value().lock().expect("ring mutex poisoned");
        let now = Instant::now();
        let fresh: Vec<&Sample> = ring
            .iter()
            .filter(|s| now.duration_since(s.at) <= SAMPLE_MAX_AGE)
            .collect();
        if fresh.is_empty() {
            return None;
        }

        let mut ttfts: Vec<u32> = fresh.iter().map(|s| s.ttft_ms).collect();
        ttfts.sort_unstable();
        let mut tpss: Vec<f32> = fresh.iter().filter_map(|s| s.tps).collect();
        tpss.sort_unstable_by(|a, b| a.partial_cmp(b).unwrap_or(std::cmp::Ordering::Equal));
        let ttft_ms_avg =
            Some((fresh.iter().map(|s| s.ttft_ms as u64).sum::<u64>() / fresh.len() as u64) as u32);
        let tps_avg = if tpss.is_empty() {
            None
        } else {
            Some(tpss.iter().sum::<f32>() / tpss.len() as f32)
        };

        let last_age = fresh
            .iter()
            .map(|s| now.duration_since(s.at).as_secs() as u32)
            .min();

        Some(ModelMetrics {
            ttft_ms_avg,
            ttft_ms_p50: percentile_u32(&ttfts, 0.5),
            ttft_ms_p95: percentile_u32(&ttfts, 0.95),
            tps_avg,
            tps_p50: percentile_f32(&tpss, 0.5),
            tps_p95: percentile_f32(&tpss, 0.95),
            sample_count: fresh.len() as u32,
            last_sample_age_seconds: last_age,
            window_seconds: SAMPLE_MAX_AGE.as_secs() as u32,
        })
    }
}

fn percentile_u32(sorted: &[u32], q: f64) -> Option<u32> {
    if sorted.is_empty() {
        return None;
    }
    let idx = ((sorted.len() as f64 - 1.0) * q).round() as usize;
    Some(sorted[idx])
}

fn percentile_f32(sorted: &[f32], q: f64) -> Option<f32> {
    if sorted.is_empty() {
        return None;
    }
    let idx = ((sorted.len() as f64 - 1.0) * q).round() as usize;
    Some(sorted[idx])
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn records_and_snapshots() {
        let t = ModelMetricsTracker::new();
        t.record("m", 100, Some(50), 1000); // tps = 50
        t.record("m", 200, Some(100), 1000); // tps = 100
        t.record("m", 300, Some(150), 1000); // tps = 150
        let s = t.snapshot("m").unwrap();
        assert_eq!(s.sample_count, 3);
        assert_eq!(s.ttft_ms_avg, Some(200));
        assert_eq!(s.ttft_ms_p50, Some(200));
        assert_eq!(s.tps_avg, Some(100.0));
        assert_eq!(s.tps_p50, Some(100.0));
    }

    #[test]
    fn snapshot_missing_returns_none() {
        let t = ModelMetricsTracker::new();
        assert!(t.snapshot("unknown").is_none());
    }

    #[test]
    fn tps_optional_does_not_corrupt_ttft_percentiles() {
        let t = ModelMetricsTracker::new();
        t.record("m", 100, None, 0);
        t.record("m", 200, Some(50), 1000);
        let s = t.snapshot("m").unwrap();
        assert_eq!(s.sample_count, 2); // both contribute to ttft
        assert_eq!(s.ttft_ms_avg, Some(150));
        assert_eq!(s.tps_avg, Some(50.0)); // only the one with tokens contributes to tps
        assert_eq!(s.tps_p50, Some(50.0)); // only the one with tokens contributes to tps
    }

    #[test]
    fn ring_is_bounded() {
        let t = ModelMetricsTracker::new();
        for i in 0..(MAX_SAMPLES_PER_MODEL as u32 + 10) {
            t.record("m", i + 1, Some(10), 1000);
        }
        let s = t.snapshot("m").unwrap();
        assert_eq!(s.sample_count as usize, MAX_SAMPLES_PER_MODEL);
        // Oldest sample (ttft=1) was evicted; min TTFT should be 11+
        assert!(s.ttft_ms_p50.unwrap() >= 11);
    }

    #[test]
    fn zero_duration_skips_tps_only() {
        let t = ModelMetricsTracker::new();
        t.record("m", 50, Some(10), 0);
        let s = t.snapshot("m").unwrap();
        assert_eq!(s.ttft_ms_p50, Some(50));
        assert!(s.tps_p50.is_none());
    }
}
