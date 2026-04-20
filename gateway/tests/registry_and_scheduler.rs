//! Registry + scheduler integration tests. Exercises the routing decisions
//! that determine whether a request lands on the right device, the per-model
//! fleet floor, and thermal / quarantine handling.

use teale_protocol::{HardwareCapability, HeartbeatPayload, NodeCapabilities, ThermalLevel};

use teale_gateway::catalog::{self, CatalogModel};
use teale_gateway::config::{PerModelFloor, ReliabilityConfig, SchedulerConfig};
use teale_gateway::registry::Registry;
use teale_gateway::scheduler::Scheduler;

fn reliability() -> ReliabilityConfig {
    ReliabilityConfig {
        request_timeout_seconds: 60,
        ttft_deadline_seconds: 5,
        max_retries: 1,
        heartbeat_stale_seconds: 30,
        quarantine_seconds: 30,
        discover_interval_seconds: 10,
    }
}

fn scheduler() -> Scheduler {
    Scheduler::new(SchedulerConfig {
        max_queue_depth: 8,
        swap_penalty: 0.3,
        tps_weight: 1.0,
        per_model_floor: PerModelFloor { large: 3, small: 2 },
    })
}

fn caps(loaded: &[&str], swap: &[&str], chip: &str, ram_gb: f64) -> NodeCapabilities {
    NodeCapabilities {
        hardware: HardwareCapability {
            chip_family: chip.into(),
            chip_name: chip.into(),
            total_ram_gb: ram_gb,
            gpu_core_count: 40,
            memory_bandwidth_gbs: match chip {
                "m4Max" => 546.0,
                "m3Ultra" => 819.0,
                "m4Pro" => 273.0,
                _ => 200.0,
            },
            tier: 1,
            gpu_backend: Some("metal".into()),
            platform: Some("macOS".into()),
            gpu_vram_gb: None,
        },
        loaded_models: loaded.iter().map(|s| s.to_string()).collect(),
        max_model_size_gb: ram_gb * 0.75,
        is_available: true,
        ptn_ids: None,
        swappable_models: swap.iter().map(|s| s.to_string()).collect(),
        max_concurrent_requests: Some(4),
        effective_context: Some(32768),
    }
}

#[test]
fn upsert_and_eligible_picks_loaded_device() {
    let r = Registry::new(reliability());
    r.upsert_device(
        "node-a".into(),
        "A".into(),
        caps(&["meta-llama/llama-3.3-70b-instruct"], &[], "m4Max", 64.0),
    );
    r.upsert_device(
        "node-b".into(),
        "B".into(),
        caps(
            &["qwen/qwen3-8b"],
            &["meta-llama/llama-3.3-70b-instruct"],
            "m4Pro",
            64.0,
        ),
    );

    let els = r.eligible_devices("meta-llama/llama-3.3-70b-instruct");
    let ids: Vec<_> = els.iter().map(|d| d.node_id.as_str()).collect();
    assert!(ids.contains(&"node-a"));
    assert!(ids.contains(&"node-b")); // swap-eligible also returned

    let sched = scheduler();
    let picked = sched
        .pick(&els, "meta-llama/llama-3.3-70b-instruct", &[], &r, None)
        .expect("device");
    // node-a is loaded → should win against node-b's swap penalty.
    assert_eq!(picked.node_id, "node-a");
}

#[test]
fn scheduler_excludes_failed_device() {
    let r = Registry::new(reliability());
    r.upsert_device(
        "node-a".into(),
        "A".into(),
        caps(&["meta-llama/llama-3.3-70b-instruct"], &[], "m4Max", 64.0),
    );
    r.upsert_device(
        "node-b".into(),
        "B".into(),
        caps(
            &["meta-llama/llama-3.3-70b-instruct"],
            &[],
            "m3Ultra",
            128.0,
        ),
    );

    let els = r.eligible_devices("meta-llama/llama-3.3-70b-instruct");
    let sched = scheduler();

    let first = sched
        .pick(&els, "meta-llama/llama-3.3-70b-instruct", &[], &r, None)
        .unwrap();
    let retry = sched
        .pick(
            &els,
            "meta-llama/llama-3.3-70b-instruct",
            std::slice::from_ref(&first.node_id),
            &r,
            None,
        )
        .unwrap();
    assert_ne!(
        first.node_id, retry.node_id,
        "retry should pick a different device"
    );
}

#[test]
fn quarantined_device_is_skipped() {
    let r = Registry::new(reliability());
    r.upsert_device(
        "node-a".into(),
        "A".into(),
        caps(&["meta-llama/llama-3.3-70b-instruct"], &[], "m4Max", 64.0),
    );
    r.quarantine("node-a", 30);

    let els = r.eligible_devices("meta-llama/llama-3.3-70b-instruct");
    assert!(els.is_empty(), "quarantined device should not be eligible");
}

#[test]
fn thermal_critical_weights_to_zero() {
    let r = Registry::new(reliability());
    r.upsert_device(
        "node-a".into(),
        "A".into(),
        caps(&["meta-llama/llama-3.3-70b-instruct"], &[], "m4Max", 64.0),
    );
    let hb = HeartbeatPayload {
        device_id: "node-a".into(),
        timestamp: 0.0,
        thermal_level: ThermalLevel::Critical,
        throttle_level: 100,
        loaded_models: vec!["meta-llama/llama-3.3-70b-instruct".into()],
        is_generating: false,
        queue_depth: 0,
        ewma_tokens_per_second: Some(80.0),
    };
    r.apply_heartbeat("node-a", &hb);

    let els = r.eligible_devices("meta-llama/llama-3.3-70b-instruct");
    assert!(
        els.is_empty(),
        "thermal=Critical device should be ineligible"
    );
}

#[test]
fn loaded_count_respects_staleness_threshold_indirectly() {
    // Note: heartbeat-stale behavior is applied in sweep(); loaded_count
    // already checks `!heartbeat_is_stale`. Fresh-registered devices are
    // eligible.
    let r = Registry::new(reliability());
    r.upsert_device(
        "node-a".into(),
        "A".into(),
        caps(&["qwen/qwen3-8b"], &[], "m4Max", 64.0),
    );
    assert_eq!(r.loaded_count("qwen/qwen3-8b"), 1);
    assert_eq!(r.loaded_count("missing/model"), 0);
}

#[test]
fn fleet_floor_large_threshold() {
    let r = Registry::new(reliability());
    // two devices loaded with a 70B model — below large-floor of 3.
    r.upsert_device(
        "node-a".into(),
        "A".into(),
        caps(&["meta-llama/llama-3.3-70b-instruct"], &[], "m4Max", 64.0),
    );
    r.upsert_device(
        "node-b".into(),
        "B".into(),
        caps(
            &["meta-llama/llama-3.3-70b-instruct"],
            &[],
            "m3Ultra",
            128.0,
        ),
    );
    assert_eq!(r.loaded_count("meta-llama/llama-3.3-70b-instruct"), 2);
    // Caller (handler_models) compares vs floor.large=3 and hides the entry.
}

#[test]
fn catalog_load_from_file() {
    // gateway/models.yaml ships with the workspace.
    let path = env_models_yaml();
    let models = catalog::load(&path).expect("load models.yaml");
    assert!(!models.is_empty());
    // Llama 3.1 8B must always be in the MVP catalog.
    let llama = models
        .iter()
        .find(|m| m.id == "meta-llama/llama-3.1-8b-instruct")
        .expect("llama 3.1 8b present");
    assert_eq!(llama.context_length, 16384);
    // Sanity-check tiers — concrete models need params_b for the floor
    // check; virtual entries (e.g. teale/auto) are exempt since they
    // resolve to a concrete model at request time.
    for m in &models {
        if m.is_virtual {
            continue;
        }
        assert!(
            m.params_b > 0.0,
            "model {} missing params_b for tier lookup",
            m.id
        );
    }
}

fn env_models_yaml() -> String {
    // Tests run with CWD at the crate (gateway/). models.yaml is alongside.
    "models.yaml".to_string()
}

#[test]
fn catalog_aliases_match() {
    let m = CatalogModel {
        id: "meta-llama/llama-3.1-8b-instruct".into(),
        display_name: "Llama 3.1 8B".into(),
        owned_by: "meta-llama".into(),
        context_length: 16384,
        max_output_tokens: 8192,
        params_b: 8.0,
        pricing_prompt: "0.0".into(),
        pricing_completion: "0.0".into(),
        quantization: None,
        supported_parameters: vec![],
        description: None,
        aliases: vec!["llama-3.1-8b-instruct".into(), "llama3.1-8b".into()],
        is_virtual: false,
    };
    assert!(m.matches("meta-llama/llama-3.1-8b-instruct"));
    assert!(m.matches("llama-3.1-8b-instruct"));
    assert!(m.matches("llama3.1-8b"));
    assert!(!m.matches("qwen/qwen3-8b"));
}

#[test]
fn ewma_prior_from_bandwidth() {
    let r = Registry::new(reliability());
    r.upsert_device(
        "ultra".into(),
        "Ultra Studio".into(),
        caps(&["qwen/qwen3-8b"], &[], "m3Ultra", 128.0),
    );
    let d = r
        .eligible_devices("qwen/qwen3-8b")
        .pop()
        .expect("ultra eligible");
    // 819 GB/s / 5 GB model ≈ 164 t/s prior.
    assert!(d.ewma_tokens_per_second > 100.0);
    assert!(d.ewma_tokens_per_second < 200.0);
}
