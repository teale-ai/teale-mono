//! Live shadow replay for probation supply (stranger_supply.enabled).
//!
//! After a real chat completion succeeds, this module replays the same
//! prompt out of band - once to a fresh TRUSTED fleet device and once to
//! a PROBATION device claiming the same model, both at temperature 0 /
//! seed 0 - and diffs the two outputs. The benchmark suite proves a
//! stranger's box runs a competent model; the shadow diff is the
//! stronger check: same prompt, concurrent comparison, suspicious
//! divergence detected against the fleet's own serving behavior.
//!
//! Cross-hardware llama.cpp output is not bit-identical even at temp 0,
//! so the metric is a soft similarity ratio (normalized edit distance),
//! and quarantine fires only on CONSECUTIVE mismatches under the floor -
//! never on a single divergent generation.
//!
//! Two deliberate properties:
//!   - The client path is untouched: one post-completion hook, all work
//!     out of band in a spawned task. Latency, streaming, retries, and
//!     billing see none of this.
//!   - PRIVACY: replaying sends REAL user prompts to stranger hardware.
//!     That exposure is the reason stranger_supply.enabled stays off
//!     until Taylor explicitly accepts it; it is the same plaintext
//!     posture as the fleet, extended to unvetted machines.

use serde_json::Value;
use tracing::{debug, info, warn};

use teale_protocol::openai::ChatCompletionRequest;

use crate::catalog::CatalogModel;
use crate::collect::collect_completion;
use crate::state::AppState;

/// Track consecutive low-similarity replays per probation node.
fn mismatch_streaks() -> &'static dashmap::DashMap<String, u32> {
    static STREAKS: once_cell::sync::Lazy<dashmap::DashMap<String, u32>> =
        once_cell::sync::Lazy::new(dashmap::DashMap::new);
    &STREAKS
}

/// Post-completion hook from the chat stream path. Cheap, synchronous,
/// and a no-op unless probation supply exists; the replay itself runs in
/// a spawned task.
pub fn maybe_spawn(state: &AppState, catalog_model: &CatalogModel, req_body: &Value) {
    let cfg = &state.config.stranger_supply;
    if !cfg.enabled {
        return;
    }

    let stale_after = state.config.reliability.heartbeat_stale_seconds;
    let probation_targets: Vec<String> = state
        .registry
        .snapshot_devices()
        .into_iter()
        .filter(|d| {
            d.probation
                && !d.heartbeat_is_stale(stale_after)
                && d.capabilities.is_available
                && crate::registry::model_matches_any(
                    &catalog_model.id,
                    &d.capabilities.loaded_models,
                )
        })
        .map(|d| d.node_id)
        .collect();
    if probation_targets.is_empty() {
        return;
    }

    // Rebuild the outbound request with deterministic sampling and a
    // capped max_tokens so the replay cost is bounded. If the body does
    // not parse as a chat request, there is nothing sensible to replay.
    let Ok(mut replay) = serde_json::from_value::<ChatCompletionRequest>(req_body.clone()) else {
        return;
    };
    replay.model = Some(catalog_model.id.clone());
    replay.temperature = Some(0.0);
    replay.seed = Some(0);
    replay.stream = Some(true);
    replay.max_tokens = Some(
        replay
            .max_tokens
            .unwrap_or(cfg.shadow_max_tokens_cap)
            .min(cfg.shadow_max_tokens_cap),
    );
    replay.user = Some("gateway-shadow-replay".to_string());

    // Trusted comparison target: least-loaded eligible fleet device.
    let trusted = state
        .registry
        .eligible_devices(&catalog_model.id)
        .into_iter()
        .min_by_key(|d| state.registry.in_flight(&d.node_id))
        .map(|d| d.node_id);
    let Some(trusted_node) = trusted else {
        return;
    };

    let state = state.clone();
    let model_id = catalog_model.id.clone();
    tokio::spawn(async move {
        run_shadow(&state, &model_id, replay, trusted_node, probation_targets).await;
    });
}

async fn run_shadow(
    state: &AppState,
    model_id: &str,
    replay: ChatCompletionRequest,
    trusted_node: String,
    probation_targets: Vec<String>,
) {
    let trusted =
        match collect_completion(state, &trusted_node, model_id, clone_request(&replay)).await {
            Ok(out) => out,
            Err(err) => {
                debug!(model = %model_id, "shadow replay: trusted baseline failed: {}", err);
                return;
            }
        };

    for target in probation_targets {
        let probation =
            match collect_completion(state, &target, model_id, clone_request(&replay)).await {
                Ok(out) => out,
                Err(err) => {
                    debug!(
                        model = %model_id,
                        node = %target,
                        "shadow replay: probation dispatch failed: {}",
                        err
                    );
                    crate::metrics::SHADOW_REPLAY_TOTAL
                        .with_label_values(&[model_id, &target, "dispatch_error"])
                        .inc();
                    continue;
                }
            };

        let similarity = similarity_ratio(&trusted.text, &probation.text);
        crate::metrics::SHADOW_SIMILARITY
            .with_label_values(&[model_id, &target])
            .observe(similarity);

        let floor = state.config.stranger_supply.shadow_similarity_floor;
        if similarity < floor {
            let streak = {
                let mut entry = mismatch_streaks().entry(target.clone()).or_insert(0);
                *entry += 1;
                *entry
            };
            crate::metrics::SHADOW_REPLAY_TOTAL
                .with_label_values(&[model_id, &target, "mismatch"])
                .inc();
            warn!(
                model = %model_id,
                node = %target,
                similarity = format!("{:.3}", similarity),
                streak,
                "shadow replay mismatch vs trusted baseline"
            );
            if streak >= state.config.stranger_supply.shadow_quarantine_streak {
                warn!(
                    node = %target,
                    "shadow mismatch streak hit - quarantining probation node"
                );
                state
                    .registry
                    .quarantine(&target, state.config.reliability.quarantine_seconds);
                crate::metrics::SHADOW_REPLAY_TOTAL
                    .with_label_values(&[model_id, &target, "quarantined"])
                    .inc();
                mismatch_streaks().remove(&target);
            }
        } else {
            mismatch_streaks().remove(&target);
            crate::metrics::SHADOW_REPLAY_TOTAL
                .with_label_values(&[model_id, &target, "match"])
                .inc();
            info!(
                model = %model_id,
                node = %target,
                similarity = format!("{:.3}", similarity),
                "shadow replay matched trusted baseline"
            );
        }
    }
}

fn clone_request(req: &ChatCompletionRequest) -> ChatCompletionRequest {
    req.clone()
}

/// Normalized similarity in [0, 1]: 1 - levenshtein(a, b) / max(len).
/// Computed over at most 1024 chars per side - enough to catch proxy /
/// weaker-model divergence without O(n^2) cost on long generations.
pub(crate) fn similarity_ratio(a: &str, b: &str) -> f64 {
    let a: Vec<char> = a.chars().take(1024).collect();
    let b: Vec<char> = b.chars().take(1024).collect();
    if a.is_empty() && b.is_empty() {
        return 1.0;
    }
    let max_len = a.len().max(b.len());
    let dist = levenshtein(&a, &b);
    1.0 - (dist as f64 / max_len as f64)
}

fn levenshtein(a: &[char], b: &[char]) -> usize {
    let mut prev: Vec<usize> = (0..=b.len()).collect();
    let mut cur: Vec<usize> = vec![0; b.len() + 1];
    for (i, &ca) in a.iter().enumerate() {
        cur[0] = i + 1;
        for (j, &cb) in b.iter().enumerate() {
            cur[j + 1] = (prev[j] + usize::from(ca != cb))
                .min(prev[j + 1] + 1)
                .min(cur[j] + 1);
        }
        std::mem::swap(&mut prev, &mut cur);
    }
    prev[b.len()]
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn similarity_basics() {
        assert_eq!(similarity_ratio("", ""), 1.0);
        assert_eq!(similarity_ratio("identical", "identical"), 1.0);
        assert_eq!(similarity_ratio("abc", "xyz"), 0.0);
        let near = similarity_ratio(
            "The capital of Japan is Tokyo.",
            "The capital of Japan is Tokyo!",
        );
        assert!(near > 0.9, "near-identical outputs score high: {}", near);
        let divergent = similarity_ratio(
            "The capital of Japan is Tokyo.",
            "As an AI language model I cannot answer that.",
        );
        assert!(
            divergent < 0.6,
            "divergent outputs score below the default floor: {}",
            divergent
        );
    }

    #[test]
    fn similarity_is_bounded() {
        let long_a = "a".repeat(5000);
        let long_b = "a".repeat(5000);
        assert_eq!(similarity_ratio(&long_a, &long_b), 1.0);
    }
}
