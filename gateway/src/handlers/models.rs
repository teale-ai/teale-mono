use axum::{
    extract::State,
    http::{header, HeaderMap, HeaderValue},
    response::{IntoResponse, Response},
    Json,
};
use std::cmp::Reverse;
use std::collections::HashMap;
use teale_protocol::openai::ModelsResponse;

use crate::catalog::{is_large, synthesize_live_model};
use crate::registry::normalize_model_id;
use crate::state::AppState;

const CATALOG_HTML: &str = include_str!("models.html");
const HIDDEN_MODEL_IDS: &[&str] = &["moonshotai/kimi-k2"];

pub async fn list_models(State(state): State<AppState>, headers: HeaderMap) -> Response {
    // Content negotiation: browsers (Accept: text/html) get the styled catalog
    // page; curl/SDKs (Accept: */* or application/json) keep the raw JSON.
    let wants_html = headers
        .get(header::ACCEPT)
        .and_then(|v| v.to_str().ok())
        .map(|s| s.contains("text/html"))
        .unwrap_or(false);

    if wants_html {
        let mut h = HeaderMap::new();
        h.insert(
            header::CONTENT_TYPE,
            HeaderValue::from_static("text/html; charset=utf-8"),
        );
        h.insert(
            header::CACHE_CONTROL,
            HeaderValue::from_static("public, max-age=60"),
        );
        // Without `Vary: Accept`, the browser caches the HTML response under
        // `/v1/models` and reuses it for the page's `Accept: application/json`
        // fetch, which then hits `res.json()` and throws
        // `Unexpected token '<', "<!doctype "... is not valid JSON`.
        h.insert(header::VARY, HeaderValue::from_static("Accept"));
        h.insert(
            header::CONTENT_SECURITY_POLICY,
            HeaderValue::from_static(
                "default-src 'self'; style-src 'self' 'unsafe-inline'; \
                 script-src 'self' 'unsafe-inline'; img-src 'self' data:",
            ),
        );
        return (h, CATALOG_HTML).into_response();
    }

    let floor = &state.config.scheduler.per_model_floor;
    let connected_device_count = state.registry.device_count() as u32;
    let devices = state.registry.snapshot_devices();
    let total_ram_gb: f64 = devices
        .iter()
        .map(|dev| dev.capabilities.hardware.total_ram_gb)
        .sum();
    let supplying_device_count = state.registry.supplying_device_count();
    let catalog_models: Vec<_> = state
        .catalog
        .iter()
        .filter(|m| !HIDDEN_MODEL_IDS.contains(&m.id.as_str()))
        .collect();
    let mut entries: Vec<_> = state
        .catalog
        .iter()
        .enumerate()
        .filter(|(_, m)| !HIDDEN_MODEL_IDS.contains(&m.id.as_str()))
        .filter(|(_, m)| {
            // Virtual meta-models (e.g. teale/auto) are always advertised;
            // resolution happens at request time against concrete supply.
            if m.is_virtual {
                return true;
            }
            // Enforce per-model fleet floor: hide models we can't serve healthily.
            let min = if is_large(m.params_b) {
                floor.large
            } else {
                floor.small
            };
            state.registry.loaded_count(&m.id) >= min
        })
        .map(|(idx, m)| {
            let loaded_device_count = if m.is_virtual {
                supplying_device_count
            } else {
                state.registry.loaded_count(&m.id)
            };
            (
                idx,
                loaded_device_count,
                m.to_entry_with_live_state(
                    state.model_metrics.snapshot(&m.id),
                    loaded_device_count,
                ),
            )
        })
        .collect();

    let mut live_models: HashMap<String, (String, u32, Option<u32>)> = HashMap::new();
    for device in devices.iter().filter(|dev| {
        !dev.is_quarantined()
            && dev.capabilities.is_available
            && !dev.heartbeat_is_stale(state.config.reliability.heartbeat_stale_seconds)
    }) {
        for model_id in &device.capabilities.loaded_models {
            if HIDDEN_MODEL_IDS.contains(&model_id.as_str()) {
                continue;
            }
            if catalog_models.iter().any(|m| m.matches(model_id)) {
                continue;
            }
            let key = normalize_model_id(model_id);
            let entry = live_models
                .entry(key)
                .or_insert_with(|| (model_id.clone(), 0, None));
            if model_id.contains('/') && !entry.0.contains('/') {
                entry.0 = model_id.clone();
            }
            entry.1 += 1;
            if let Some(context) = device.capabilities.effective_context {
                entry.2 = Some(entry.2.unwrap_or(0).max(context));
            }
        }
    }
    let synthetic_index_base = state.catalog.len();
    for (offset, (_norm_id, (model_id, loaded_device_count, effective_context))) in
        live_models.into_iter().enumerate()
    {
        let synthetic = synthesize_live_model(&model_id, effective_context);
        entries.push((
            synthetic_index_base + offset,
            loaded_device_count,
            synthetic.to_entry_with_live_state(
                state.model_metrics.snapshot(&synthetic.id),
                loaded_device_count,
            ),
        ));
    }

    entries.sort_by_key(|(idx, loaded_device_count, _)| (Reverse(*loaded_device_count), *idx));
    let entries = entries.into_iter().map(|(_, _, entry)| entry).collect();

    let mut h = HeaderMap::new();
    h.insert(header::VARY, HeaderValue::from_static("Accept"));
    (
        h,
        Json(ModelsResponse {
            object: "list".to_string(),
            connected_device_count: Some(connected_device_count),
            total_ram_gb: Some(total_ram_gb),
            data: entries,
        }),
    )
        .into_response()
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Arc;

    use axum::body::to_bytes;
    use teale_protocol::{HardwareCapability, NodeCapabilities};
    use tokio::sync::broadcast;

    use crate::auth::TokenTable;
    use crate::config::{Config, PerModelFloor, RelayConfig, ReliabilityConfig, SchedulerConfig};
    use crate::model_metrics::ModelMetricsTracker;
    use crate::registry::Registry;
    use crate::scheduler::Scheduler;
    use crate::state::{AppState, ShareKeyIssuers};

    fn test_config() -> Config {
        Config {
            bind: "127.0.0.1:0".into(),
            display_name: "test-gateway".into(),
            relay: RelayConfig {
                url: "ws://127.0.0.1:0/ws".into(),
            },
            identity_path: "/tmp/test-gateway-identity.key".into(),
            models_yaml: "models.yaml".into(),
            scheduler: SchedulerConfig {
                max_queue_depth: 8,
                swap_penalty: 0.3,
                tps_weight: 1.0,
                per_model_floor: PerModelFloor { large: 1, small: 1 },
            },
            reliability: ReliabilityConfig {
                request_timeout_seconds: 60,
                ttft_deadline_seconds: 15,
                small_ttft_deadline_seconds: 15,
                max_retries: 1,
                heartbeat_stale_seconds: 3600,
                quarantine_seconds: 30,
                discover_interval_seconds: 10,
            },
            synthetic_probes: Default::default(),
        }
    }

    fn test_caps(loaded: &[&str]) -> NodeCapabilities {
        NodeCapabilities {
            hardware: HardwareCapability {
                chip_family: "m4Max".into(),
                chip_name: "m4Max".into(),
                total_ram_gb: 64.0,
                gpu_core_count: 40,
                memory_bandwidth_gbs: 546.0,
                tier: 1,
                gpu_backend: Some("metal".into()),
                platform: Some("macOS".into()),
                gpu_vram_gb: None,
            },
            loaded_models: loaded.iter().map(|s| s.to_string()).collect(),
            max_model_size_gb: 48.0,
            is_available: true,
            ptn_ids: None,
            swappable_models: vec![],
            max_concurrent_requests: Some(4),
            effective_context: Some(65_536),
            on_ac_power: Some(true),
        }
    }

    fn test_state() -> AppState {
        let config = test_config();
        let registry = Registry::new(config.reliability.clone());
        let scheduler = Arc::new(Scheduler::new(config.scheduler.clone()));
        let relay = crate::relay_client::RelayHandle::test_handle();
        let (group_tx, _group_rx) = broadcast::channel(16);
        AppState {
            config,
            tokens: TokenTable::default(),
            registry,
            scheduler,
            relay,
            catalog: Arc::new(vec![]),
            db: None,
            group_tx,
            model_metrics: Arc::new(ModelMetricsTracker::new()),
            share_key_issuers: ShareKeyIssuers::default(),
            providers: crate::providers::ProvidersHandle::empty_for_test(),
        }
    }

    #[tokio::test]
    async fn lists_live_uncataloged_models() {
        let state = test_state();
        state.registry.upsert_device(
            "node-live".into(),
            "Tailor 512g1".into(),
            test_caps(&["acme/live-model"]),
        );

        let response = list_models(State(state), HeaderMap::new()).await;
        let (_parts, body) = response.into_parts();
        let bytes = to_bytes(body, 1024 * 1024).await.expect("read body");
        let models: ModelsResponse = serde_json::from_slice(&bytes).expect("parse body");
        let model = models
            .data
            .iter()
            .find(|model| model.id == "acme/live-model")
            .expect("uncataloged live model should be visible");

        assert_eq!(model.loaded_device_count, Some(1));
        assert_eq!(model.context_length, Some(65_536));
        assert_eq!(
            model
                .pricing
                .as_ref()
                .map(|pricing| pricing.prompt.as_str()),
            Some(crate::catalog::LIVE_MODEL_DEFAULT_PROMPT_PRICE)
        );
    }
}
