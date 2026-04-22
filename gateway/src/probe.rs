//! Low-rate synthetic probes that keep model TTFT/TPS stats fresh even when
//! real traffic is sparse.

use std::collections::{HashMap, HashSet};
use std::time::{Duration, Instant};

use serde_json::{json, Value};
use tokio::sync::mpsc;
use tracing::{debug, info, warn};
use uuid::Uuid;

use teale_protocol::{
    openai::{ApiMessage, ChatCompletionRequest},
    ClusterMessage, InferenceRequestPayload,
};

use crate::catalog::CatalogModel;
use crate::relay_client::{PendingSession, SessionEvent};
use crate::state::AppState;

const PROBE_PROMPT: &str = "Reply with exactly one word: pong";

#[derive(Debug, Clone, PartialEq, Eq, Hash)]
struct ProbeTarget {
    node_id: String,
    model_id: String,
}

pub fn spawn_synthetic_probe_loop(state: AppState) {
    let cfg = state.config.synthetic_probes.clone();
    if !cfg.enabled {
        info!("synthetic probe loop disabled");
        return;
    }

    tokio::spawn(async move {
        let freshness_window = Duration::from_secs(cfg.interval_seconds);
        let poll_interval = Duration::from_secs(cfg.interval_seconds.min(60));
        let mut ticker = tokio::time::interval(poll_interval);
        let mut last_probed_at: HashMap<ProbeTarget, Instant> = HashMap::new();
        info!(
            "spawned synthetic probe loop (freshness={}s, poll={}s, max_tokens={})",
            cfg.interval_seconds,
            poll_interval.as_secs(),
            cfg.max_tokens
        );

        loop {
            ticker.tick().await;

            let targets = collect_probe_targets(
                state.catalog.as_ref(),
                state.config.reliability.heartbeat_stale_seconds,
                state.registry.snapshot_devices(),
            );
            if targets.is_empty() {
                debug!("synthetic probe loop found no idle loaded suppliers");
                continue;
            }

            let active_targets: HashSet<_> = targets.iter().cloned().collect();
            last_probed_at.retain(|target, _| active_targets.contains(target));

            for target in targets {
                if last_probed_at
                    .get(&target)
                    .is_some_and(|at| at.elapsed() < freshness_window)
                {
                    continue;
                }

                if let Err(err) = probe_target(&state, &target, cfg.max_tokens).await {
                    last_probed_at.insert(target.clone(), Instant::now());
                    warn!(
                        model = %target.model_id,
                        node = %target.node_id,
                        "synthetic probe failed: {}",
                        err
                    );
                    continue;
                }

                last_probed_at.insert(target, Instant::now());
            }
        }
    });
}

fn collect_probe_targets(
    catalog: &[CatalogModel],
    heartbeat_stale_seconds: u64,
    devices: Vec<crate::registry::DeviceState>,
) -> Vec<ProbeTarget> {
    let mut seen: HashSet<(String, String)> = HashSet::new();
    let mut targets = Vec::new();

    for device in devices {
        if device.is_quarantined()
            || !device.capabilities.is_available
            || device.heartbeat_is_stale(heartbeat_stale_seconds)
            || device.live.is_generating
            || device.live.queue_depth > 0
        {
            continue;
        }

        for loaded_model in &device.capabilities.loaded_models {
            let Some(model) = catalog.iter().find(|m| m.matches(loaded_model)) else {
                continue;
            };
            let key = (device.node_id.clone(), model.id.clone());
            if seen.insert(key.clone()) {
                targets.push(ProbeTarget {
                    node_id: key.0,
                    model_id: key.1,
                });
            }
        }
    }

    targets.sort_by(|a, b| {
        a.model_id
            .cmp(&b.model_id)
            .then_with(|| a.node_id.cmp(&b.node_id))
    });
    targets
}

async fn probe_target(
    state: &AppState,
    target: &ProbeTarget,
    max_tokens: u32,
) -> anyhow::Result<()> {
    state.registry.inc_in_flight(&target.node_id);

    let open_timeout = Duration::from_secs(state.config.reliability.ttft_deadline_seconds);
    let request_timeout = Duration::from_secs(state.config.reliability.request_timeout_seconds);
    let ttft_deadline = Duration::from_secs(state.config.reliability.ttft_deadline_seconds);

    let session_id = match state
        .relay
        .open_session(&target.node_id, open_timeout)
        .await
    {
        Ok(session_id) => session_id,
        Err(err) => {
            state.registry.dec_in_flight(&target.node_id);
            anyhow::bail!("relay open: {}", err);
        }
    };

    let request_id = Uuid::new_v4().to_string();
    let outbound = ChatCompletionRequest {
        model: Some(target.model_id.clone()),
        messages: vec![ApiMessage {
            role: "user".to_string(),
            content: Value::String(PROBE_PROMPT.to_string()),
            name: None,
            tool_calls: None,
            tool_call_id: None,
        }],
        temperature: Some(0.0),
        top_p: None,
        max_tokens: Some(max_tokens),
        stream: Some(true),
        stream_options: Some(json!({ "include_usage": true })),
        stop: None,
        presence_penalty: None,
        frequency_penalty: None,
        tools: None,
        tool_choice: None,
        response_format: None,
        seed: Some(0),
        user: Some("gateway-synthetic-probe".to_string()),
    };

    let (tx, mut rx) = mpsc::channel::<SessionEvent>(64);
    state.relay.register_session(PendingSession {
        request_id: request_id.clone(),
        device_node_id: target.node_id.clone(),
        session_id: session_id.clone(),
        chunks_tx: tx,
    });

    let send = state.relay.send_cluster(
        &target.node_id,
        &session_id,
        &ClusterMessage::InferenceRequest(Box::new(InferenceRequestPayload {
            request_id,
            request: outbound,
            streaming: true,
        })),
    );
    if let Err(err) = send {
        state.relay.close_session(&target.node_id, &session_id);
        state.registry.dec_in_flight(&target.node_id);
        anyhow::bail!("relay send: {}", err);
    }

    let started = Instant::now();
    let mut first_token_at: Option<Instant> = None;
    let mut chunk_count = 0u64;

    let result = loop {
        let deadline = if first_token_at.is_some() {
            request_timeout
        } else {
            ttft_deadline
        };

        match tokio::time::timeout(deadline, rx.recv()).await {
            Ok(Some(SessionEvent::Chunk(_))) => {
                if first_token_at.is_none() {
                    first_token_at = Some(Instant::now());
                }
                chunk_count += 1;
            }
            Ok(Some(SessionEvent::Complete { tokens_out })) => {
                let Some(first_token_at) = first_token_at else {
                    break Err(anyhow::anyhow!("probe completed without a first token"));
                };
                let completion_tokens = tokens_out.map(|v| v as u64).unwrap_or(chunk_count).max(1);
                let ttft_ms = first_token_at.duration_since(started).as_millis() as u32;
                let total_ms = started.elapsed().as_millis() as u64;
                let gen_ms = total_ms.saturating_sub(ttft_ms as u64);
                state.model_metrics.record(
                    &target.model_id,
                    ttft_ms,
                    Some(completion_tokens),
                    gen_ms,
                );
                debug!(
                    model = %target.model_id,
                    node = %target.node_id,
                    ttft_ms,
                    completion_tokens,
                    "synthetic probe recorded sample"
                );
                break Ok(());
            }
            Ok(Some(SessionEvent::Error { message, .. })) => {
                break Err(anyhow::anyhow!("upstream error: {}", message));
            }
            Ok(Some(SessionEvent::Disconnect(reason))) => {
                break Err(anyhow::anyhow!("disconnect: {}", reason));
            }
            Ok(None) => {
                break Err(anyhow::anyhow!("probe channel closed"));
            }
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

    state.relay.close_session(&target.node_id, &session_id);
    state.registry.dec_in_flight(&target.node_id);
    result
}

#[cfg(test)]
mod tests {
    use super::*;

    use teale_protocol::{HardwareCapability, NodeCapabilities, ThermalLevel};

    use crate::catalog::CatalogModel;
    use crate::registry::{DeviceState, LiveStats};

    #[test]
    fn collect_probe_targets_skips_busy_stale_and_unknown_models() {
        let now = Instant::now();
        let catalog = vec![CatalogModel {
            id: "moonshotai/kimi-k2.6".into(),
            display_name: "Kimi".into(),
            owned_by: "moonshotai".into(),
            context_length: 262_144,
            max_output_tokens: 16_384,
            params_b: 1000.0,
            pricing_prompt: "0.00000050".into(),
            pricing_completion: "0.00000100".into(),
            quantization: Some("INT4".into()),
            supported_parameters: vec![],
            description: None,
            aliases: vec!["kimi".into()],
        }];

        let mk_device = |node_id: &str,
                         loaded_models: Vec<&str>,
                         heartbeat_at: Instant,
                         is_generating: bool,
                         queue_depth: u32|
         -> DeviceState {
            DeviceState {
                node_id: node_id.to_string(),
                display_name: node_id.to_string(),
                capabilities: NodeCapabilities {
                    hardware: HardwareCapability {
                        chip_family: "Apple".into(),
                        chip_name: "M3 Ultra".into(),
                        total_ram_gb: 512.0,
                        gpu_core_count: 80,
                        memory_bandwidth_gbs: 819.0,
                        tier: 1,
                        gpu_backend: Some("metal".into()),
                        platform: Some("macOS".into()),
                        gpu_vram_gb: None,
                    },
                    loaded_models: loaded_models.into_iter().map(str::to_string).collect(),
                    max_model_size_gb: 600.0,
                    is_available: true,
                    ptn_ids: None,
                    swappable_models: vec![],
                    max_concurrent_requests: Some(1),
                },
                last_heartbeat: heartbeat_at,
                last_seen: heartbeat_at,
                quarantined_until: None,
                ewma_tokens_per_second: 100.0,
                live: LiveStats {
                    queue_depth,
                    is_generating,
                    throttle_level: 100,
                    thermal_level: ThermalLevel::Nominal,
                },
            }
        };

        let targets = collect_probe_targets(
            &catalog,
            3600,
            vec![
                mk_device("idle-kimi", vec!["kimi"], now, false, 0),
                mk_device("busy-kimi", vec!["moonshotai/kimi-k2.6"], now, true, 0),
                mk_device("queued-kimi", vec!["moonshotai/kimi-k2.6"], now, false, 1),
                mk_device(
                    "stale-kimi",
                    vec!["moonshotai/kimi-k2.6"],
                    now - Duration::from_secs(7200),
                    false,
                    0,
                ),
                mk_device("unknown-model", vec!["unknown/model"], now, false, 0),
            ],
        );

        assert_eq!(
            targets,
            vec![ProbeTarget {
                node_id: "idle-kimi".into(),
                model_id: "moonshotai/kimi-k2.6".into(),
            }]
        );
    }
}
