//! Wire-format round-trip tests.
//!
//! These guard against serde drift between node and gateway: if a field
//! name changes or a variant encoding shifts, these explode fast instead
//! of at 3 am during a streaming fault.

use serde_json::{json, Value};
use teale_protocol::openai::{ApiMessage, ChatCompletionRequest};
use teale_protocol::{
    now_reference_seconds, ClusterMessage, HardwareCapability, HeartbeatPayload,
    InferenceChunkPayload, InferenceCompletePayload, InferenceErrorCode, InferenceErrorPayload,
    InferenceRequestPayload, LoadModelPayload, ModelLoadErrorPayload, ModelLoadedPayload,
    NodeCapabilities, ThermalLevel,
};

fn sample_capabilities() -> NodeCapabilities {
    NodeCapabilities {
        hardware: HardwareCapability {
            chip_family: "m3Ultra".into(),
            chip_name: "Apple M3 Ultra".into(),
            total_ram_gb: 512.0,
            gpu_core_count: 80,
            memory_bandwidth_gbs: 819.0,
            tier: 1,
            gpu_backend: Some("metal".into()),
            platform: Some("macOS".into()),
            gpu_vram_gb: None,
        },
        loaded_models: vec!["meta-llama/llama-3.3-70b-instruct".into()],
        max_model_size_gb: 400.0,
        is_available: true,
        ptn_ids: None,
        swappable_models: vec!["qwen/qwen3-30b-a3b-instruct-2507".into()],
        max_concurrent_requests: Some(4),
        effective_context: Some(32768),
        on_ac_power: None,
    }
}

fn sample_heartbeat() -> HeartbeatPayload {
    HeartbeatPayload {
        device_id: "dead-beef-1234".into(),
        timestamp: now_reference_seconds(),
        thermal_level: ThermalLevel::Fair,
        throttle_level: 95,
        loaded_models: vec!["meta-llama/llama-3.3-70b-instruct".into()],
        is_generating: true,
        queue_depth: 2,
        ewma_tokens_per_second: Some(18.3),
    }
}

fn sample_request() -> InferenceRequestPayload {
    InferenceRequestPayload {
        request_id: "req-abc".into(),
        request: ChatCompletionRequest {
            model: Some("meta-llama/llama-3.3-70b-instruct".into()),
            messages: vec![ApiMessage {
                role: "user".into(),
                content: json!("hello"),
                name: None,
                tool_calls: None,
                tool_call_id: None,
            }],
            temperature: Some(0.7),
            top_p: Some(0.9),
            max_tokens: Some(256),
            stream: Some(true),
            stream_options: None,
            stop: None,
            presence_penalty: None,
            frequency_penalty: None,
            tools: None,
            tool_choice: None,
            response_format: None,
            seed: Some(42),
            user: None,
        },
        streaming: true,
    }
}

fn assert_round_trip(msg: ClusterMessage) {
    let value = msg.to_value();
    let encoded = serde_json::to_vec(&value).expect("serialize");
    let parsed = ClusterMessage::parse(&encoded).expect("parse");
    let roundtripped_value = parsed.to_value();
    // Compare as Value, not via PartialEq on ClusterMessage (not derived).
    assert_eq!(value, roundtripped_value, "round-trip mismatch");
}

#[test]
fn capabilities_roundtrip() {
    let caps = sample_capabilities();
    let j = serde_json::to_value(&caps).unwrap();
    let back: NodeCapabilities = serde_json::from_value(j.clone()).unwrap();
    assert_eq!(back.hardware.chip_family, caps.hardware.chip_family);
    assert_eq!(back.swappable_models, caps.swappable_models);
    // Field-name check: verify the JSON uses camelCase as wire format.
    assert!(j.get("loadedModels").is_some(), "loadedModels key present");
    assert!(j.get("swappableModels").is_some());
    assert!(j.get("maxConcurrentRequests").is_some());
    assert!(j.get("hardware").unwrap().get("chipFamily").is_some());
}

#[test]
fn heartbeat_roundtrip() {
    assert_round_trip(ClusterMessage::Heartbeat(sample_heartbeat()));
    assert_round_trip(ClusterMessage::HeartbeatAck(sample_heartbeat()));
}

#[test]
fn inference_request_roundtrip() {
    assert_round_trip(ClusterMessage::InferenceRequest(Box::new(sample_request())));
}

#[test]
fn inference_chunk_roundtrip() {
    assert_round_trip(ClusterMessage::InferenceChunk(InferenceChunkPayload {
        request_id: "req-abc".into(),
        chunk: json!({
            "id": "chatcmpl-xxx",
            "object": "chat.completion.chunk",
            "choices": [{ "index": 0, "delta": { "content": "hi" }, "finish_reason": null }]
        }),
    }));
}

#[test]
fn inference_complete_roundtrip() {
    assert_round_trip(ClusterMessage::InferenceComplete(
        InferenceCompletePayload {
            request_id: "req-abc".into(),
            tokens_in: Some(12),
            tokens_out: Some(34),
        },
    ));
}

#[test]
fn inference_error_typed_roundtrip() {
    assert_round_trip(ClusterMessage::InferenceError(InferenceErrorPayload {
        request_id: "req-abc".into(),
        error_message: "queue full".into(),
        code: Some(InferenceErrorCode::QueueFull),
    }));
}

#[test]
fn load_model_flow_roundtrip() {
    assert_round_trip(ClusterMessage::LoadModel(LoadModelPayload {
        request_id: "lm-1".into(),
        model_id: "openai/gpt-oss-120b".into(),
    }));
    assert_round_trip(ClusterMessage::ModelLoaded(ModelLoadedPayload {
        request_id: "lm-1".into(),
        model_id: "openai/gpt-oss-120b".into(),
        load_time_ms: 17_500,
    }));
    assert_round_trip(ClusterMessage::ModelLoadError(ModelLoadErrorPayload {
        request_id: "lm-1".into(),
        model_id: "some/thing".into(),
        reason: "not_swappable".into(),
    }));
}

#[test]
fn thermal_levels_encode_as_lowercase_strings() {
    for (level, expected) in [
        (ThermalLevel::Nominal, "nominal"),
        (ThermalLevel::Fair, "fair"),
        (ThermalLevel::Serious, "serious"),
        (ThermalLevel::Critical, "critical"),
    ] {
        let v = serde_json::to_value(level).unwrap();
        assert_eq!(v, Value::String(expected.to_string()));
    }
}

#[test]
fn unknown_cluster_message_preserved() {
    let raw = json!({ "some_future_message": { "field": 42 } });
    let bytes = serde_json::to_vec(&raw).unwrap();
    let parsed = ClusterMessage::parse(&bytes).expect("parse");
    match parsed {
        ClusterMessage::Unknown { kind, .. } => {
            assert_eq!(kind, "some_future_message");
        }
        other => panic!("expected Unknown, got {:?}", std::mem::discriminant(&other)),
    }
}

#[test]
fn openai_content_can_be_array_of_parts() {
    // Multimodal-style message: content is an array of parts.
    let raw = json!({
        "inferenceRequest": {
            "requestID": "req-vl",
            "request": {
                "model": "google/gemma-3-27b-it",
                "messages": [{
                    "role": "user",
                    "content": [
                        {"type": "text", "text": "describe this"},
                        {"type": "image_url", "image_url": {"url": "data:image/png;base64,..."}}
                    ]
                }],
                "stream": true
            },
            "streaming": true
        }
    });
    let bytes = serde_json::to_vec(&raw).unwrap();
    let parsed = ClusterMessage::parse(&bytes).expect("parse");
    if let ClusterMessage::InferenceRequest(p) = parsed {
        assert_eq!(p.request_id, "req-vl");
        assert!(p.request.messages[0].content.is_array());
    } else {
        panic!("expected InferenceRequest");
    }
}
