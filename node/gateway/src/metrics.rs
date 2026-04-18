//! Prometheus metrics for the gateway.
//!
//! Exposed at GET /metrics in the standard text format.

use once_cell::sync::Lazy;
use prometheus::{
    register_counter_vec, register_gauge_vec, register_histogram_vec, register_int_counter_vec,
    register_int_gauge, CounterVec, GaugeVec, HistogramVec, IntCounterVec, IntGauge,
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

pub static TTFT_SECONDS: Lazy<HistogramVec> = Lazy::new(|| {
    register_histogram_vec!(
        "gateway_ttft_seconds",
        "Time to first token, by model",
        &["model"],
        vec![0.1, 0.25, 0.5, 1.0, 2.0, 3.0, 5.0, 10.0, 20.0, 30.0]
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

pub static DEVICES_CONNECTED: Lazy<IntGauge> = Lazy::new(|| {
    register_int_gauge!("gateway_devices_connected", "Total devices connected to relay")
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
    let _ = &*TTFT_SECONDS;
    let _ = &*TOTAL_LATENCY_SECONDS;
    let _ = &*DEVICES_ELIGIBLE;
    let _ = &*DEVICES_CONNECTED;
    let _ = &*WS_RECONNECTS_TOTAL;
    let _ = &*TOKENS_OUT_TOTAL;
}
