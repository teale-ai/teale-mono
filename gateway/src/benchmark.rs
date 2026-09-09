//! Probation benchmark for stranger supply (stranger_supply.enabled).
//!
//! A probation node never serves client traffic. This loop is what it
//! does instead: a deterministic fingerprint suite run against every
//! catalog model the node claims to have loaded, plus a decode-TPS floor
//! derived from its self-reported hardware. The suite answers two
//! questions before a stranger's box can earn trust:
//!
//!   1. Is a competent model actually back there? (behavioral
//!      fingerprints: exact echoes, arithmetic, structured output,
//!      instruction following - a box proxying random junk or a much
//!      weaker model fails these)
//!   2. Does its observed throughput plausibly match the hardware it
//!      claims? (TPS floor as a fraction of the hardware prior)
//!
//! What this suite deliberately does NOT try to prove: that the weights
//! are bit-identical to a reference. Cross-hardware llama.cpp output is
//! not bit-stable even at temperature 0, so exact-output comparison
//! against a trusted supplier is not sound here. That stronger check is
//! the live shadow-diff phase, which compares concurrent outputs on the
//! same prompt and lands as a follow-up.
//!
//! Failure handling: a failed benchmark quarantines the node through the
//! existing registry path (same primitive probe failures use) and bumps
//! the probation_benchmark_total{result="fail"} counter. Nothing here
//! bans permanently; a node that fixes itself passes the next sweep.

use std::time::{Duration, Instant};

use serde_json::{json, Value};
use tokio::sync::mpsc;
use tracing::{debug, info, warn};
use uuid::Uuid;

use teale_protocol::{
    openai::{ApiMessage, ChatCompletionRequest},
    ClusterMessage, InferenceRequestPayload,
};

use crate::registry::{hardware_tps_prior, DeviceState};
use crate::relay_client::{PendingSession, SessionEvent};
use crate::state::AppState;

/// One fingerprint prompt and the check its (trimmed) output must pass.
struct Fingerprint {
    prompt: &'static str,
    max_tokens: u32,
    check: Check,
}

enum Check {
    /// Trimmed output must equal this exactly (case-sensitive).
    Exact(&'static str),
    /// Lowercased output must contain this lowercase needle.
    ContainsLower(&'static str),
}

const FINGERPRINTS: &[Fingerprint] = &[
    Fingerprint {
        prompt: "Reply with exactly this token and nothing else: TEALE_BENCH_7Q2",
        max_tokens: 16,
        check: Check::Exact("TEALE_BENCH_7Q2"),
    },
    Fingerprint {
        prompt: "What is 17 + 25? Reply with the number only.",
        max_tokens: 8,
        check: Check::ContainsLower("42"),
    },
    Fingerprint {
        prompt: "Reply with only this JSON object, no other text: {\"ok\":true}",
        max_tokens: 16,
        check: Check::ContainsLower("\"ok\":true"),
    },
    Fingerprint {
        prompt:
            "List the first three letters of the alphabet as a comma-separated list. No other text.",
        max_tokens: 16,
        check: Check::ContainsLower("a, b, c"),
    },
    Fingerprint {
        prompt: "What is the capital of Japan? Answer with one word.",
        max_tokens: 8,
        check: Check::ContainsLower("tokyo"),
    },
];

fn check_output(check: &Check, output: &str) -> bool {
    let trimmed = output.trim();
    match check {
        Check::Exact(want) => trimmed == *want,
        Check::ContainsLower(needle) => trimmed.to_lowercase().contains(needle),
    }
}

pub struct SweepOutcome {
    pub node_id: String,
    pub model_id: String,
    pub passed: bool,
    pub failures: Vec<String>,
}

pub fn spawn_probation_benchmark_loop(state: AppState) {
    let cfg = state.config.stranger_supply.clone();
    tokio::spawn(async move {
        if !cfg.enabled {
            info!("probation benchmark loop disabled (stranger_supply.enabled = false)");
            return;
        }
        info!(
            interval_s = cfg.benchmark_interval_seconds,
            tps_floor_ratio = cfg.tps_floor_ratio,
            "spawned probation benchmark loop"
        );
        let mut interval =
            tokio::time::interval(Duration::from_secs(cfg.benchmark_interval_seconds));
        loop {
            interval.tick().await;
            for outcome in run_sweep(&state).await {
                crate::metrics::PROBATION_BENCHMARK_TOTAL
                    .with_label_values(&[
                        &outcome.model_id,
                        if outcome.passed { "pass" } else { "fail" },
                    ])
                    .inc();
                if outcome.passed {
                    info!(
                        node = %outcome.node_id,
                        model = %outcome.model_id,
                        "probation benchmark passed"
                    );
                } else {
                    warn!(
                        node = %outcome.node_id,
                        model = %outcome.model_id,
                        failures = ?outcome.failures,
                        "probation benchmark FAILED - quarantining node"
                    );
                    state.registry.quarantine(
                        &outcome.node_id,
                        state.config.reliability.quarantine_seconds,
                    );
                }
            }
        }
    });
}

/// Benchmark every catalog model claimed by every probation device.
/// One failure on one model quarantines the whole node: probation is a
/// trust tier, and a node lying about any model fails the tier.
async fn run_sweep(state: &AppState) -> Vec<SweepOutcome> {
    let mut outcomes = Vec::new();
    let stale_after = state.config.reliability.heartbeat_stale_seconds;
    let probation: Vec<DeviceState> = state
        .registry
        .snapshot_devices()
        .into_iter()
        .filter(|d| {
            d.probation && !d.heartbeat_is_stale(stale_after) && d.capabilities.is_available
        })
        .collect();
    if probation.is_empty() {
        return outcomes;
    }

    for device in probation {
        let tps_floor =
            hardware_tps_prior(&device.capabilities) * state.config.stranger_supply.tps_floor_ratio;
        for loaded in device.capabilities.loaded_models.clone() {
            let Some(model) = state.catalog.iter().find(|m| m.matches(&loaded)) else {
                debug!(
                    node = %device.node_id,
                    model = %loaded,
                    "probation node claims a non-catalog model - skipped this sweep"
                );
                continue;
            };
            outcomes.push(benchmark_model(state, &device, &model.id, tps_floor).await);
        }
    }
    outcomes
}

async fn benchmark_model(
    state: &AppState,
    device: &DeviceState,
    model_id: &str,
    tps_floor: f64,
) -> SweepOutcome {
    let mut failures: Vec<String> = Vec::new();
    let mut tps_samples: Vec<f64> = Vec::new();

    for (idx, fp) in FINGERPRINTS.iter().enumerate() {
        match run_prompt(state, &device.node_id, model_id, fp).await {
            Ok(run) => {
                if !check_output(&fp.check, &run.text) {
                    failures.push(format!(
                        "fingerprint {} failed: got {:?}",
                        idx,
                        run.text.chars().take(80).collect::<String>()
                    ));
                }
                if let Some(tps) = run.tps {
                    tps_samples.push(tps);
                }
            }
            Err(err) => {
                failures.push(format!("fingerprint {} dispatch error: {}", idx, err));
            }
        }
    }

    if !tps_samples.is_empty() {
        let mean_tps = tps_samples.iter().sum::<f64>() / tps_samples.len() as f64;
        crate::metrics::PROBATION_BENCHMARK_TPS
            .with_label_values(&[model_id])
            .observe(mean_tps);
        if mean_tps < tps_floor {
            failures.push(format!(
                "decode {:.1} tok/s below floor {:.1} (claimed-hardware prior)",
                mean_tps, tps_floor
            ));
        }
    }

    SweepOutcome {
        node_id: device.node_id.clone(),
        model_id: model_id.to_string(),
        passed: failures.is_empty(),
        failures,
    }
}

struct PromptRun {
    text: String,
    tps: Option<f64>,
}

/// Run one fingerprint prompt against a probation node and collect the
/// full output text. Mirrors the probe.rs dispatch path but aggregates
/// chunk content instead of discarding it; duplicated on purpose so the
/// hot freshness-probe path keeps its exact current behavior.
async fn run_prompt(
    state: &AppState,
    node_id: &str,
    model_id: &str,
    fp: &Fingerprint,
) -> anyhow::Result<PromptRun> {
    state.registry.admit(node_id, false, None);

    let open_timeout = Duration::from_secs(8);
    let request_timeout = Duration::from_secs(state.config.reliability.request_timeout_seconds);
    let ttft_deadline = Duration::from_secs(state.config.reliability.ttft_deadline_seconds);

    let session_id = match state.relay.open_session(node_id, open_timeout).await {
        Ok(session_id) => session_id,
        Err(err) => {
            state.registry.dec_in_flight(node_id, false);
            anyhow::bail!("relay open: {}", err);
        }
    };

    let request_id = Uuid::new_v4().to_string();
    let outbound = ChatCompletionRequest {
        model: Some(model_id.to_string()),
        messages: vec![ApiMessage {
            role: "user".to_string(),
            content: Value::String(fp.prompt.to_string()),
            name: None,
            tool_calls: None,
            tool_call_id: None,
        }],
        temperature: Some(0.0),
        top_p: None,
        max_tokens: Some(fp.max_tokens),
        stream: Some(true),
        stream_options: Some(json!({ "include_usage": true })),
        stop: None,
        presence_penalty: None,
        frequency_penalty: None,
        tools: None,
        tool_choice: None,
        response_format: None,
        seed: Some(0),
        user: Some("gateway-probation-benchmark".to_string()),
        extra: Default::default(),
    };

    let (tx, mut rx) = mpsc::channel::<SessionEvent>(64);
    state.relay.register_session(PendingSession {
        request_id: request_id.clone(),
        device_node_id: node_id.to_string(),
        session_id: session_id.clone(),
        chunks_tx: tx,
    });

    let send = state.relay.send_cluster(
        node_id,
        &session_id,
        &ClusterMessage::InferenceRequest(Box::new(InferenceRequestPayload {
            request_id,
            request: outbound,
            streaming: true,
        })),
    );
    if let Err(err) = send {
        state.relay.close_session(node_id, &session_id);
        state.registry.dec_in_flight(node_id, false);
        anyhow::bail!("relay send: {}", err);
    }

    let _started = Instant::now();
    let mut first_token_at: Option<Instant> = None;
    let mut text = String::new();
    let mut chunk_count = 0u64;

    let result = loop {
        let deadline = if first_token_at.is_some() {
            request_timeout
        } else {
            ttft_deadline
        };
        match tokio::time::timeout(deadline, rx.recv()).await {
            Ok(Some(SessionEvent::Chunk(chunk))) => {
                if first_token_at.is_none() {
                    first_token_at = Some(Instant::now());
                }
                chunk_count += 1;
                if let Some(delta) = chunk
                    .get("choices")
                    .and_then(|c| c.get(0))
                    .and_then(|c| c.get("delta"))
                    .and_then(|d| d.get("content"))
                    .and_then(|c| c.as_str())
                {
                    text.push_str(delta);
                }
            }
            Ok(Some(SessionEvent::Complete { tokens_out })) => {
                let Some(first_token_at) = first_token_at else {
                    break Err(anyhow::anyhow!("completed without a first token"));
                };
                let completion_tokens = tokens_out.map(|v| v as u64).unwrap_or(chunk_count).max(1);
                let decode_secs = first_token_at.elapsed().as_secs_f64();
                let tps = if decode_secs > 0.0 {
                    Some(completion_tokens as f64 / decode_secs)
                } else {
                    None
                };
                break Ok(PromptRun { text, tps });
            }
            Ok(Some(SessionEvent::Error { message, .. })) => {
                break Err(anyhow::anyhow!("upstream error: {}", message));
            }
            Ok(Some(SessionEvent::Disconnect(reason))) => {
                break Err(anyhow::anyhow!("disconnect: {}", reason));
            }
            Ok(None) => break Err(anyhow::anyhow!("channel closed")),
            Err(_) => {
                let phase = if first_token_at.is_some() {
                    "timeout mid-stream"
                } else {
                    "ttft timeout"
                };
                break Err(anyhow::anyhow!("{}", phase));
            }
        }
    };

    state.relay.close_session(node_id, &session_id);
    state.registry.dec_in_flight(node_id, false);
    result
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn fingerprint_checks() {
        assert!(check_output(
            &Check::Exact("TEALE_BENCH_7Q2"),
            "  TEALE_BENCH_7Q2\n"
        ));
        assert!(!check_output(
            &Check::Exact("TEALE_BENCH_7Q2"),
            "TEALE_BENCH_7Q2!"
        ));
        assert!(check_output(
            &Check::ContainsLower("42"),
            "The answer is 42."
        ));
        assert!(check_output(
            &Check::ContainsLower("\"ok\":true"),
            "{ \"ok\":true }"
        ));
        assert!(check_output(&Check::ContainsLower("a, b, c"), "A, B, C"));
        assert!(check_output(&Check::ContainsLower("tokyo"), "Tokyo."));
        assert!(!check_output(&Check::ContainsLower("tokyo"), "Osaka"));
    }

    #[test]
    fn suite_is_nontrivial() {
        // Guard against someone gutting the suite to pass a weak node.
        assert!(FINGERPRINTS.len() >= 5);
        assert!(FINGERPRINTS.iter().all(|f| f.max_tokens <= 16));
    }
}
