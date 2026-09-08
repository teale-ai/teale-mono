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
    let _ = &*RETRIES_TOTAL;
    let _ = &*HEAVY_HOLD_REFUSED;
    let _ = &*HEAVY_HOLD_EXPIRED;
    let _ = &*HEAVY_HOLD_SHARED;
    let _ = &*HEAVY_HOLDS;
    let _ = &*TTFT_SECONDS;
    let _ = &*TOTAL_LATENCY_SECONDS;
    let _ = &*DEVICES_ELIGIBLE;
    let _ = &*DEVICES_CONNECTED;
    let _ = &*DEVICE_SLOTS_BUSY;
    let _ = &*DEVICE_SLOTS_TOTAL;
    let _ = &*WS_RECONNECTS_TOTAL;
    let _ = &*TOKENS_OUT_TOTAL;
}
