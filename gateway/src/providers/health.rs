//! Rolling-window health tracker for centralized providers.
//!
//! Mirrors OpenRouter's classification: success ÷ total over the window, with
//! tiers ≥95% (normal routing), 80–94% (degraded / lower priority), <80%
//! (fallback-only). Tracks TTFT and TPS percentiles per (provider_id, model_id).
//!
//! Storage is in-memory (DashMap of ring buffers); we don't write per-request
//! samples to SQLite to keep settlement transactions cheap. The
//! `provider_health` table is updated as periodic snapshots by a background
//! flusher (not yet implemented in v1).

use std::collections::VecDeque;
use std::time::{Duration, Instant};

use dashmap::DashMap;
use serde::Serialize;

const WINDOW: Duration = Duration::from_secs(300); // 5 minutes
const MAX_SAMPLES: usize = 2_000;

#[derive(Debug, Clone, Copy)]
struct Sample {
    at: Instant,
    success: bool,
    counts_against_uptime: bool,
    ttft_ms: Option<u64>,
    tps: Option<f64>,
}

#[derive(Default)]
struct Bucket {
    samples: VecDeque<Sample>,
    last_outage: Option<Instant>,
}

impl Bucket {
    fn push(&mut self, s: Sample) {
        self.samples.push_back(s);
        if self.samples.len() > MAX_SAMPLES {
            self.samples.pop_front();
        }
        if !s.success && s.counts_against_uptime {
            self.last_outage = Some(s.at);
        }
        self.evict(s.at);
    }

    fn evict(&mut self, now: Instant) {
        while let Some(front) = self.samples.front() {
            if now.duration_since(front.at) > WINDOW {
                self.samples.pop_front();
            } else {
                break;
            }
        }
    }

    fn snapshot(&mut self, now: Instant) -> HealthSnapshot {
        self.evict(now);
        let mut success = 0u64;
        let mut counted_total = 0u64;
        let mut ttfts: Vec<u64> = Vec::new();
        let mut tpss: Vec<f64> = Vec::new();
        for s in &self.samples {
            if s.counts_against_uptime || s.success {
                counted_total += 1;
                if s.success {
                    success += 1;
                }
            }
            if let Some(t) = s.ttft_ms {
                ttfts.push(t);
            }
            if let Some(t) = s.tps {
                tpss.push(t);
            }
        }
        ttfts.sort_unstable();
        tpss.sort_by(|a, b| a.partial_cmp(b).unwrap_or(std::cmp::Ordering::Equal));
        let success_ratio = if counted_total == 0 {
            1.0
        } else {
            success as f64 / counted_total as f64
        };
        HealthSnapshot {
            success_ratio,
            sample_count: self.samples.len() as u64,
            ttft_p50_ms: percentile_u64(&ttfts, 0.50),
            ttft_p90_ms: percentile_u64(&ttfts, 0.90),
            ttft_p99_ms: percentile_u64(&ttfts, 0.99),
            tps_p50: percentile_f64(&tpss, 0.50),
            tps_p90: percentile_f64(&tpss, 0.90),
            tps_p99: percentile_f64(&tpss, 0.99),
            seconds_since_outage: self.last_outage.map(|at| now.duration_since(at).as_secs()),
        }
    }
}

fn percentile_u64(sorted: &[u64], p: f64) -> Option<u64> {
    if sorted.is_empty() {
        return None;
    }
    let idx = ((sorted.len() as f64 - 1.0) * p).round() as usize;
    sorted.get(idx).copied()
}

fn percentile_f64(sorted: &[f64], p: f64) -> Option<f64> {
    if sorted.is_empty() {
        return None;
    }
    let idx = ((sorted.len() as f64 - 1.0) * p).round() as usize;
    sorted.get(idx).copied()
}

#[derive(Debug, Clone, Default, Serialize)]
pub struct HealthSnapshot {
    #[serde(rename = "successRatio")]
    pub success_ratio: f64,
    #[serde(rename = "sampleCount")]
    pub sample_count: u64,
    #[serde(rename = "ttftP50Ms")]
    pub ttft_p50_ms: Option<u64>,
    #[serde(rename = "ttftP90Ms")]
    pub ttft_p90_ms: Option<u64>,
    #[serde(rename = "ttftP99Ms")]
    pub ttft_p99_ms: Option<u64>,
    #[serde(rename = "tpsP50")]
    pub tps_p50: Option<f64>,
    #[serde(rename = "tpsP90")]
    pub tps_p90: Option<f64>,
    #[serde(rename = "tpsP99")]
    pub tps_p99: Option<f64>,
    #[serde(rename = "secondsSinceOutage", skip_serializing_if = "Option::is_none")]
    pub seconds_since_outage: Option<u64>,
}

/// OpenRouter-style health tier. Used by the router to deprioritize unstable
/// providers without dropping them entirely (matches the `<80% = fallback-only`
/// rule).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum HealthTier {
    Normal,    // ≥95%
    Degraded,  // 80–94%
    Fallback,  // <80%
    Untracked, // <100 requests in window
}

impl HealthSnapshot {
    pub fn tier(&self) -> HealthTier {
        if self.sample_count < 100 {
            return HealthTier::Untracked;
        }
        let pct = self.success_ratio * 100.0;
        if pct >= 95.0 {
            HealthTier::Normal
        } else if pct >= 80.0 {
            HealthTier::Degraded
        } else {
            HealthTier::Fallback
        }
    }

    /// True if the bucket has seen a counted error in the last 30 seconds —
    /// the OpenRouter "recently-unstable" filter applied before default load
    /// balancing.
    pub fn recently_unstable(&self) -> bool {
        self.seconds_since_outage.map_or(false, |s| s < 30)
    }
}

#[derive(Default)]
pub struct HealthTracker {
    buckets: DashMap<(String, String), Bucket>,
}

impl HealthTracker {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn record_success(
        &self,
        provider_id: &str,
        model_id: &str,
        ttft_ms: Option<u64>,
        tps: Option<f64>,
    ) {
        let key = (provider_id.to_string(), model_id.to_string());
        let mut entry = self.buckets.entry(key).or_default();
        entry.push(Sample {
            at: Instant::now(),
            success: true,
            counts_against_uptime: true,
            ttft_ms,
            tps,
        });
    }

    pub fn record_failure(&self, provider_id: &str, model_id: &str, counts_against_uptime: bool) {
        let key = (provider_id.to_string(), model_id.to_string());
        let mut entry = self.buckets.entry(key).or_default();
        entry.push(Sample {
            at: Instant::now(),
            success: false,
            counts_against_uptime,
            ttft_ms: None,
            tps: None,
        });
    }

    pub fn snapshot(&self, provider_id: &str, model_id: &str) -> HealthSnapshot {
        let key = (provider_id.to_string(), model_id.to_string());
        let now = Instant::now();
        if let Some(mut entry) = self.buckets.get_mut(&key) {
            entry.snapshot(now)
        } else {
            HealthSnapshot::default()
        }
    }
}
