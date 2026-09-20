//! Prometheus metrics for the gateway.
//!
//! Exposed at GET /metrics in the standard text format.

use once_cell::sync::Lazy;
use prometheus::{
    register_counter_vec, register_gauge_vec, register_histogram_vec, register_int_counter_vec,
    register_int_gauge, CounterVec, GaugeVec, HistogramVec, IntCounterVec, IntGauge, IntGaugeVec,
};

pub static REQUESTS_TOTAL: Lazy<IntCounterVec> = Lazy::new(|| {
    register_int_counter_vec!(
        "gateway_requests_total",
        "Total inference requests grouped by model and outcome",
        &["model", "status"]
    )
    .expect("metric init")
});

pub static DEVICE_CHALLENGES_TOTAL: Lazy<IntCounterVec> = Lazy::new(|| {
    register_int_counter_vec!(
        "gateway_device_challenges_total",
        "Device-auth challenge requests grouped by limiter decision",
        &["decision"]
    )
    .expect("metric init")
});

pub static DEVICE_CHALLENGES_BY_DEVICE_TOTAL: Lazy<IntCounterVec> = Lazy::new(|| {
    register_int_counter_vec!(
        "gateway_device_challenges_by_device_total",
        "Valid device-auth challenge requests grouped by 16-hex device id prefix and limiter decision",
        &["device_prefix", "decision"]
    )
    .expect("metric init")
});

pub static DEVICE_CHALLENGE_DENIED_TOTAL: Lazy<IntCounterVec> = Lazy::new(|| {
    register_int_counter_vec!(
        "gateway_device_challenge_denied_total",
        "Device-auth challenge denials grouped by reason",
        &["reason"]
    )
    .expect("metric init")
});

pub static RETRIES_TOTAL: Lazy<IntCounterVec> = Lazy::new(|| {
    register_int_counter_vec!(
        "gateway_retries_total",
        "Retries attempted by reason",
        &["reason"]
    )
    .expect("metric init")
});

pub static CONVO_STICKINESS: Lazy<IntCounterVec> = Lazy::new(|| {
    register_int_counter_vec!(
        "gateway_convo_stickiness_total",
        "Conversation supplier-affinity lookups by result: hit (sticky node eligible and used), miss (no fresh entry or node not a candidate)",
        &["result"]
    )
    .expect("metric init")
});

pub static HEAVY_HOLD_REFUSED: Lazy<prometheus::IntCounter> = Lazy::new(|| {
    prometheus::register_int_counter!(
        "gateway_heavy_hold_refused_total",
        "Heavy requests refused admission because every eligible device already carries a heavy (#247)"
    )
    .expect("metric init")
});

pub static HEAVY_HOLD_EXPIRED: Lazy<prometheus::IntCounter> = Lazy::new(|| {
    prometheus::register_int_counter!(
        "gateway_heavy_hold_expired_total",
        "Heavy holds lazily expired after exceeding heavy_hold_ttl_seconds: the close path never ran, and the hold was stale by definition (#247 follow-up)"
    )
    .expect("metric init")
});

pub static HEAVY_HOLD_SHARED: Lazy<prometheus::IntCounter> = Lazy::new(|| {
    prometheus::register_int_counter!(
        "gateway_heavy_hold_shared_total",
        "Heavy requests admitted beside the same consumer's own in-flight heavy (slot-capped co-residency, #247 follow-up)"
    )
    .expect("metric init")
});

pub static HEAVY_HOLDS: Lazy<IntGaugeVec> = Lazy::new(|| {
    prometheus::register_int_gauge_vec!(
        "gateway_heavy_holds",
        "Current heavy in-flight holds per node (#247) - the hold registry made observable",
        &["node_id"]
    )
    .expect("metric init")
});

pub static TTFT_SECONDS: Lazy<HistogramVec> = Lazy::new(|| {
    register_histogram_vec!(
        "gateway_ttft_seconds",
        "Time to first token, by model and traffic kind (traffic = real requests, probe = synthetic probes)",
        &["model", "kind"],
        vec![0.1, 0.25, 0.5, 1.0, 2.0, 3.0, 5.0, 10.0, 20.0, 30.0]
    )
    .expect("metric init")
});

pub static TTFT_CONTEXT_SECONDS: Lazy<HistogramVec> = Lazy::new(|| {
    register_histogram_vec!(
        "gateway_ttft_context_seconds",
        "Traffic TTFT stratified by bounded prompt-size and dispatch occupancy buckets. Separates prompt/prefill sensitivity from co-resident queueing without device or request-id cardinality.",
        &["model", "prompt_bucket", "in_flight_bucket"],
        vec![0.1, 0.25, 0.5, 1.0, 2.0, 3.0, 5.0, 10.0, 20.0, 30.0]
    )
    .expect("metric init")
});

pub fn prompt_bucket(tokens: u32) -> &'static str {
    match tokens {
        0..=511 => "0_511",
        512..=2047 => "512_2047",
        2048..=8191 => "2048_8191",
        8192..=32767 => "8192_32767",
        _ => "32768_plus",
    }
}

pub fn in_flight_bucket(in_flight: u32) -> &'static str {
    match in_flight {
        0 | 1 => "1",
        2 => "2",
        _ => "3_plus",
    }
}

pub fn observe_ttft_context(model: &str, prompt_tokens: u32, in_flight: u32, seconds: f64) {
    TTFT_CONTEXT_SECONDS
        .with_label_values(&[
            model,
            prompt_bucket(prompt_tokens),
            in_flight_bucket(in_flight),
        ])
        .observe(seconds);
}

pub static TTFT_OCCUPANCY_SOURCE_SECONDS: Lazy<HistogramVec> = Lazy::new(|| {
    register_histogram_vec!(
        "gateway_ttft_occupancy_source_seconds",
        "Traffic TTFT labeled at first token by gateway-visible same/other-model peers and heartbeat-visible occupancy beyond gateway accounting.",
        &["model", "prompt_bucket", "gateway_peer", "external_excess"],
        vec![0.1, 0.25, 0.5, 1.0, 2.0, 3.0, 5.0, 10.0, 20.0, 30.0]
    )
    .expect("metric init")
});

pub fn gateway_peer_bucket(same: u32, other: u32) -> &'static str {
    match (same > 0, other > 0) {
        (false, false) => "none",
        (true, false) => "same_model",
        (false, true) => "other_model",
        (true, true) => "mixed",
    }
}

pub fn external_excess_bucket(
    gateway_total: u32,
    reported_busy: Option<u32>,
) -> &'static str {
    match reported_busy {
        None => "unknown",
        Some(busy) if busy > gateway_total => "yes",
        Some(_) => "no",
    }
}

pub fn observe_ttft_occupancy_source(
    model: &str,
    prompt_tokens: u32,
    gateway_same: u32,
    gateway_other: u32,
    reported_busy: Option<u32>,
    seconds: f64,
) {
    let gateway_total = gateway_same
        .saturating_add(gateway_other)
        .saturating_add(1);
    TTFT_OCCUPANCY_SOURCE_SECONDS
        .with_label_values(&[
            model,
            prompt_bucket(prompt_tokens),
            gateway_peer_bucket(gateway_same, gateway_other),
            external_excess_bucket(gateway_total, reported_busy),
        ])
        .observe(seconds);
}

pub static DISPATCH_SECONDS: Lazy<HistogramVec> = Lazy::new(|| {
    register_histogram_vec!(
        "gateway_dispatch_seconds",
        "Arrival-to-dispatch time (pick + admit + session open), by model and traffic kind. ttft minus this is upstream connect + prefill - the decomposition the Auto-vs-local latency work needs. For probes this is session open only (target preselected).",
        &["model", "kind"],
        vec![0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1.0, 2.0, 5.0, 10.0]
    )
    .expect("metric init")
});

pub static TOTAL_LATENCY_SECONDS: Lazy<HistogramVec> = Lazy::new(|| {
    register_histogram_vec!(
        "gateway_request_latency_seconds",
        "Total request latency (arrival to last chunk)",
        &["model", "status"],
        vec![0.5, 1.0, 2.0, 5.0, 10.0, 20.0, 30.0, 60.0, 120.0]
    )
    .expect("metric init")
});

pub static DEVICES_ELIGIBLE: Lazy<GaugeVec> = Lazy::new(|| {
    register_gauge_vec!(
        "gateway_devices_eligible",
        "Number of healthy devices that can serve each model",
        &["model"]
    )
    .expect("metric init")
});

pub static DEVICE_SLOTS_BUSY: Lazy<GaugeVec> = Lazy::new(|| {
    register_gauge_vec!(
        "gateway_device_backend_slots_busy",
        "Backend (llama.cpp /slots) slots currently processing, per device, self-reported in heartbeats (#288). Absent series = device does not report slot occupancy.",
        &["device"]
    )
    .expect("metric init")
});

pub static DEVICE_SLOTS_TOTAL: Lazy<GaugeVec> = Lazy::new(|| {
    register_gauge_vec!(
        "gateway_device_backend_slots_total",
        "Backend (llama.cpp /slots) slots configured, per device, self-reported in heartbeats (#288). Absent series = device does not report slot occupancy.",
        &["device"]
    )
    .expect("metric init")
});

pub static PROBATION_DEVICES: Lazy<prometheus::Gauge> = Lazy::new(|| {
    prometheus::register_gauge!(
        "gateway_probation_devices",
        "Stranger-supply nodes currently admitted in the probation tier (benchmark only, never client traffic)"
    )
    .expect("metric init")
});

pub static PROBATION_BENCHMARK_TOTAL: Lazy<CounterVec> = Lazy::new(|| {
    register_counter_vec!(
        "gateway_probation_benchmark_total",
        "Probation benchmark sweeps by model and verdict",
        &["model", "result"]
    )
    .expect("metric init")
});

pub static PROBATION_BENCHMARK_TPS: Lazy<HistogramVec> = Lazy::new(|| {
    register_histogram_vec!(
        "gateway_probation_benchmark_tps",
        "Measured decode tokens/sec on probation nodes during benchmark sweeps",
        &["model"]
    )
    .expect("metric init")
});

pub static SHADOW_REPLAY_TOTAL: Lazy<CounterVec> = Lazy::new(|| {
    register_counter_vec!(
        "gateway_shadow_replay_total",
        "Stranger shadow replays by model, probation node, and outcome (match|mismatch|quarantined|dispatch_error)",
        &["model", "node", "outcome"]
    )
    .expect("metric init")
});

pub static SHADOW_SIMILARITY: Lazy<HistogramVec> = Lazy::new(|| {
    register_histogram_vec!(
        "gateway_shadow_similarity",
        "Similarity ratio (normalized edit distance, 0..1) between probation and trusted-fleet outputs on the same shadowed prompt",
        &["model", "node"]
    )
    .expect("metric init")
});

pub static ELIGIBILITY_DENIED_TOTAL: Lazy<IntCounterVec> = Lazy::new(|| {
    register_int_counter_vec!(
        "gateway_eligibility_denied_total",
        "Eligibility denials (503 no-eligible-device) by model and reason (#311)",
        &["model", "reason"]
    )
    .expect("metric init")
});

pub static DEVICES_CONNECTED: Lazy<IntGauge> = Lazy::new(|| {
    register_int_gauge!(
        "gateway_devices_connected",
        "Total devices connected to relay"
    )
    .expect("metric init")
});

pub static WS_RECONNECTS_TOTAL: Lazy<IntCounterVec> = Lazy::new(|| {
    register_int_counter_vec!(
        "gateway_ws_reconnects_total",
        "Relay-client reconnects by reason",
        &["reason"]
    )
    .expect("metric init")
});

pub static TOKENS_OUT_TOTAL: Lazy<CounterVec> = Lazy::new(|| {
    register_counter_vec!(
        "gateway_tokens_out_total",
        "Output tokens delivered, by model",
        &["model"]
    )
    .expect("metric init")
});

pub fn init() {
    // Force Lazy init so metrics appear in /metrics even before first request.
    let _ = &*REQUESTS_TOTAL;
    let _ = &*DEVICE_CHALLENGES_TOTAL;
    let _ = &*DEVICE_CHALLENGES_BY_DEVICE_TOTAL;
    let _ = &*DEVICE_CHALLENGE_DENIED_TOTAL;
    let _ = &*RETRIES_TOTAL;
    let _ = &*HEAVY_HOLD_REFUSED;
    let _ = &*HEAVY_HOLD_EXPIRED;
    let _ = &*HEAVY_HOLD_SHARED;
    let _ = &*HEAVY_HOLDS;
    let _ = &*TTFT_SECONDS;
    let _ = &*TTFT_CONTEXT_SECONDS;
    let _ = &*TTFT_OCCUPANCY_SOURCE_SECONDS;
    let _ = &*DISPATCH_SECONDS;
    let _ = &*TOTAL_LATENCY_SECONDS;
    let _ = &*DEVICES_ELIGIBLE;
    let _ = &*DEVICES_CONNECTED;
    let _ = &*DEVICE_SLOTS_BUSY;
    let _ = &*DEVICE_SLOTS_TOTAL;
    let _ = &*WS_RECONNECTS_TOTAL;
    let _ = &*TOKENS_OUT_TOTAL;
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ttft_context_buckets_are_bounded_and_stable() {
        assert_eq!(prompt_bucket(0), "0_511");
        assert_eq!(prompt_bucket(511), "0_511");
        assert_eq!(prompt_bucket(512), "512_2047");
        assert_eq!(prompt_bucket(2_048), "2048_8191");
        assert_eq!(prompt_bucket(8_192), "8192_32767");
        assert_eq!(prompt_bucket(32_768), "32768_plus");
        assert_eq!(in_flight_bucket(0), "1");
        assert_eq!(in_flight_bucket(1), "1");
        assert_eq!(in_flight_bucket(2), "2");
        assert_eq!(in_flight_bucket(3), "3_plus");
        assert_eq!(in_flight_bucket(u32::MAX), "3_plus");
        assert_eq!(gateway_peer_bucket(0, 0), "none");
        assert_eq!(gateway_peer_bucket(1, 0), "same_model");
        assert_eq!(gateway_peer_bucket(0, 1), "other_model");
        assert_eq!(gateway_peer_bucket(1, 1), "mixed");
        assert_eq!(external_excess_bucket(2, Some(3)), "yes");
        assert_eq!(external_excess_bucket(2, Some(2)), "no");
        assert_eq!(external_excess_bucket(2, None), "unknown");
    }
}
