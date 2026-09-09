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
use tracing::{debug, info, warn};

use teale_protocol::openai::{ApiMessage, ChatCompletionRequest};

use crate::collect::collect_completion;
use crate::registry::{hardware_tps_prior, DeviceState};
use crate::state::AppState;

/// One fingerprint prompt and the check its (trimmed) output must pass.
struct Fingerprint {
    prompt: &'static str,
    max_tokens: u32,
    check: Check,
}

enum Check {
    /// Lowercased output must contain this lowercase needle.
    ContainsLower(&'static str),
    /// Output with ALL whitespace removed, lowercased, must contain this
    /// lowercase needle:
    /// models legitimately differ on spacing ("a,b,c" vs "a, b, c",
    /// {"ok": true} vs {"ok":true}) and spacing is not a competence
    /// signal. Found live in the Sep 10 dry-run: real stranger hermes
    /// nodes answered the letter list without spaces and were falsely
    /// failed.
    ContainsStripped(&'static str),
}

const FINGERPRINTS: &[Fingerprint] = &[
    Fingerprint {
        prompt: "Reply with exactly this token and nothing else: TEALE_BENCH_7Q2",
        max_tokens: 16,
        // Containment, not exact: models that wrap the token in quotes or
        // punctuation are answering correctly.
        check: Check::ContainsLower("teale_bench_7q2"),
    },
    Fingerprint {
        prompt: "What is 17 + 25? Reply with the number only.",
        max_tokens: 8,
        check: Check::ContainsLower("42"),
    },
    Fingerprint {
        prompt: "Reply with only this JSON object, no other text: {\"ok\":true}",
        max_tokens: 16,
        check: Check::ContainsStripped("{\"ok\":true}"),
    },
    Fingerprint {
        prompt:
            "List the first three letters of the alphabet as a comma-separated list. No other text.",
        max_tokens: 16,
        check: Check::ContainsStripped("a,b,c"),
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
        Check::ContainsLower(needle) => trimmed.to_lowercase().contains(needle),
        Check::ContainsStripped(needle) => {
            let stripped: String = trimmed.split_whitespace().collect();
            stripped.to_lowercase().contains(needle)
        }
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
/// output text via the shared out-of-band collect path.
async fn run_prompt(
    state: &AppState,
    node_id: &str,
    model_id: &str,
    fp: &Fingerprint,
) -> anyhow::Result<PromptRun> {
    let request = ChatCompletionRequest {
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
    let started = Instant::now();
    let out = collect_completion(state, node_id, model_id, request).await?;
    let decode_secs = (started.elapsed().as_secs_f64() - out.ttft_ms as f64 / 1000.0).max(0.0);
    let tps = if decode_secs > 0.0 {
        Some(out.completion_tokens as f64 / decode_secs)
    } else {
        None
    };
    Ok(PromptRun {
        text: out.text,
        tps,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn fingerprint_checks() {
        assert!(check_output(
            &Check::ContainsLower("teale_bench_7q2"),
            "  TEALE_BENCH_7Q2\n"
        ));
        assert!(check_output(
            &Check::ContainsLower("teale_bench_7q2"),
            "\"TEALE_BENCH_7Q2\""
        ));
        assert!(!check_output(
            &Check::ContainsLower("teale_bench_7q2"),
            "TEALE_BENCH_WRONG"
        ));
        assert!(check_output(
            &Check::ContainsLower("42"),
            "The answer is 42."
        ));
        assert!(check_output(
            &Check::ContainsStripped("{\"ok\":true}"),
            "{ \"ok\": true }"
        ));
        assert!(check_output(&Check::ContainsStripped("a,b,c"), "A, B, C"));
        assert!(check_output(&Check::ContainsStripped("a,b,c"), "a,b,c"));
        assert!(!check_output(&Check::ContainsStripped("a,b,c"), "a, c, b"));
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
