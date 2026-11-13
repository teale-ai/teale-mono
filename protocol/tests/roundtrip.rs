//! Wire-format round-trip tests.
//!
//! These guard against serde drift between node and gateway: if a field
//! name changes or a variant encoding shifts, these explode fast instead
//! of at 3 am during a streaming fault.

use serde_json::{json, Value};
use teale_protocol::cluster::{
    SocksClosePayload, SocksDataPayload, SocksOpenPayload, SocksOpenResultPayload,
};
use teale_protocol::openai::{ApiMessage, ChatCompletionRequest};
use teale_protocol::{
    now_reference_seconds, ClusterMessage, DiscoverFilter, DiscoverPayload, HardwareCapability,
    HeartbeatPayload, HelloAckPayload, HelloPayload, IceCandidatePayload, IncomingRelayMessage,
    InferenceChunkPayload, InferenceCompletePayload, InferenceErrorCode, InferenceErrorPayload,
    InferenceRequestPayload, LoadModelPayload, ModelLoadErrorPayload, ModelLoadedPayload,
    NodeCapabilities, OfferAnswerPayload, OutgoingRelayMessage, RegisterPayload, RelayDataPayload,
    RelaySessionPayload, ThermalLevel,
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
        backend_slots_busy: None,
        backend_slots_total: None,
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
            extra: [("reasoning_effort".to_string(), json!("none"))].into(),
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
    let msg = ClusterMessage::InferenceRequest(Box::new(sample_request()));
    let value = msg.to_value();
    assert_eq!(
        value["inferenceRequest"]["_0"]["request"]["reasoning_effort"],
        json!("none")
    );
    assert_round_trip(msg);
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

#[test]
fn hello_and_hello_ack_roundtrip() {
    let device_info = json!({ "id": "dev-1", "name": "node", "loadedModels": [] });
    let hello = ClusterMessage::Hello(HelloPayload {
        device_info: device_info.clone(),
        protocol_version: 1,
        loaded_models: vec!["m".into()],
    });
    let v = hello.to_value();
    let inner = &v["hello"]["_0"];
    assert_eq!(inner["deviceInfo"], device_info);
    assert_eq!(inner["protocolVersion"], json!(1));
    assert_eq!(inner["loadedModels"], json!(["m"]));
    assert_round_trip(hello);

    let ack = ClusterMessage::HelloAck(HelloAckPayload {
        device_info,
        protocol_version: 1,
        loaded_models: vec![],
    });
    let v = ack.to_value();
    assert_eq!(v["helloAck"]["_0"]["protocolVersion"], json!(1));
    assert_round_trip(ack);
}

#[test]
fn socks_messages_roundtrip_with_wire_keys() {
    let open = ClusterMessage::SocksOpen(SocksOpenPayload {
        pin_id: "pin-1".into(),
        stream_id: "s-1".into(),
        dest_host: "example.com".into(),
        dest_port: 443,
    });
    let v = open.to_value();
    let inner = &v["socksOpen"]["_0"];
    assert_eq!(inner["pinId"], json!("pin-1"));
    assert_eq!(inner["streamID"], json!("s-1"));
    assert_eq!(inner["destHost"], json!("example.com"));
    assert_eq!(inner["destPort"], json!(443));
    assert_round_trip(open);

    let result = ClusterMessage::SocksOpenResult(SocksOpenResultPayload {
        stream_id: "s-1".into(),
        ok: false,
        error: Some("exit not offered".into()),
    });
    let v = result.to_value();
    let inner = &v["socksOpenResult"]["_0"];
    assert_eq!(inner["streamID"], json!("s-1"));
    assert_eq!(inner["error"], json!("exit not offered"));
    assert_round_trip(result);

    let data = ClusterMessage::SocksData(SocksDataPayload {
        stream_id: "s-1".into(),
        data: "aGk=".into(),
    });
    let v = data.to_value();
    assert_eq!(v["socksData"]["_0"]["streamID"], json!("s-1"));
    assert_round_trip(data);

    let close = ClusterMessage::SocksClose(SocksClosePayload {
        stream_id: "s-1".into(),
        reason: None,
    });
    let v = close.to_value();
    assert_eq!(v["socksClose"]["_0"]["streamID"], json!("s-1"));
    assert!(v["socksClose"]["_0"].get("reason").is_none());
    assert_round_trip(close);
}

fn session() -> RelaySessionPayload {
    RelaySessionPayload {
        from_node_id: "a".repeat(64),
        to_node_id: "b".repeat(64),
        session_id: "sess-1".into(),
    }
}

fn assert_session_keys(payload: &Value) {
    assert_eq!(payload["fromNodeID"], json!("a".repeat(64)));
    assert_eq!(payload["toNodeID"], json!("b".repeat(64)));
    assert_eq!(payload["sessionID"], json!("sess-1"));
}

#[test]
fn outgoing_relay_envelopes_use_wire_keys() {
    let register = serde_json::to_value(OutgoingRelayMessage::Register {
        register: Box::new(RegisterPayload {
            node_id: "a".repeat(64),
            public_key: "a".repeat(64),
            wg_public_key: None,
            display_name: "node".into(),
            capabilities: sample_capabilities(),
            signature: "00".repeat(64),
        }),
    })
    .unwrap();
    let r = &register["register"];
    assert_eq!(r["nodeID"], json!("a".repeat(64)));
    assert_eq!(r["publicKey"], json!("a".repeat(64)));
    assert_eq!(r["displayName"], json!("node"));
    assert!(r.get("wgPublicKey").is_none());
    assert!(r["capabilities"].get("loadedModels").is_some());
    assert!(r.get("signature").is_some());

    let discover = serde_json::to_value(OutgoingRelayMessage::Discover {
        discover: DiscoverPayload {
            requesting_node_id: "a".repeat(64),
            filter: Some(DiscoverFilter {
                model_id: Some("m".into()),
                min_ram_gb: Some(32.0),
                min_tier: Some(2),
                max_peers: Some(10),
            }),
        },
    })
    .unwrap();
    let d = &discover["discover"];
    assert_eq!(d["requestingNodeID"], json!("a".repeat(64)));
    assert_eq!(
        d["filter"],
        json!({ "modelID": "m", "minRAMGB": 32.0, "minTier": 2, "maxPeers": 10 })
    );
    let bare = serde_json::to_value(OutgoingRelayMessage::Discover {
        discover: DiscoverPayload {
            requesting_node_id: "a".repeat(64),
            filter: None,
        },
    })
    .unwrap();
    assert!(bare["discover"].get("filter").is_none());

    for (msg, key) in [
        (
            OutgoingRelayMessage::RelayOpen {
                relay_open: session(),
            },
            "relayOpen",
        ),
        (
            OutgoingRelayMessage::RelayReady {
                relay_ready: session(),
            },
            "relayReady",
        ),
        (
            OutgoingRelayMessage::RelayClose {
                relay_close: session(),
            },
            "relayClose",
        ),
    ] {
        let v = serde_json::to_value(msg).unwrap();
        assert_eq!(v.as_object().unwrap().len(), 1);
        assert_session_keys(&v[key]);
    }

    let data = serde_json::to_value(OutgoingRelayMessage::RelayData {
        relay_data: RelayDataPayload {
            from_node_id: "a".repeat(64),
            to_node_id: "b".repeat(64),
            session_id: "sess-1".into(),
            data: json!("aGk="),
        },
    })
    .unwrap();
    assert_session_keys(&data["relayData"]);
    assert_eq!(data["relayData"]["data"], json!("aGk="));

    let offer = OfferAnswerPayload {
        from_node_id: "a".repeat(64),
        to_node_id: "b".repeat(64),
        session_id: "sess-1".into(),
        connection_info: json!({ "publicIP": "1.2.3.4", "publicPort": 51820 }),
        signature: "00".repeat(64),
    };
    let v = serde_json::to_value(OutgoingRelayMessage::Offer {
        offer: offer.clone(),
    })
    .unwrap();
    assert_session_keys(&v["offer"]);
    assert_eq!(v["offer"]["connectionInfo"]["publicPort"], json!(51820));
    let v = serde_json::to_value(OutgoingRelayMessage::Answer { answer: offer }).unwrap();
    assert_session_keys(&v["answer"]);

    let v = serde_json::to_value(OutgoingRelayMessage::IceCandidate {
        ice_candidate: IceCandidatePayload {
            from_node_id: "a".repeat(64),
            to_node_id: "b".repeat(64),
            session_id: "sess-1".into(),
            candidate: json!({ "ip": "1.2.3.4", "port": 51820, "type": "host" }),
        },
    })
    .unwrap();
    assert_session_keys(&v["iceCandidate"]);
    assert_eq!(v["iceCandidate"]["candidate"]["type"], json!("host"));
}

#[test]
fn incoming_relay_envelopes_parse() {
    let session_json = json!({
        "fromNodeID": "a".repeat(64),
        "toNodeID": "b".repeat(64),
        "sessionID": "sess-1",
    });
    let parse = |v: Value| IncomingRelayMessage::parse(&v.to_string()).expect("parse");

    let ack = json!({ "registerAck": { "nodeID": "a".repeat(64), "ttlSeconds": 300 } });
    match parse(ack) {
        IncomingRelayMessage::RegisterAck { node_id } => assert_eq!(node_id, "a".repeat(64)),
        other => panic!("unexpected {other:?}"),
    }
    let discover = json!({ "discoverResponse": { "peers": [{ "nodeID": "c" }] } });
    match parse(discover) {
        IncomingRelayMessage::DiscoverResponse { peers } => assert_eq!(peers.len(), 1),
        other => panic!("unexpected {other:?}"),
    }
    for key in ["relayOpen", "relayReady", "relayClose"] {
        match (key, parse(json!({ key: session_json.clone() }))) {
            ("relayOpen", IncomingRelayMessage::RelayOpen(s))
            | ("relayReady", IncomingRelayMessage::RelayReady(s))
            | ("relayClose", IncomingRelayMessage::RelayClose(s)) => {
                assert_eq!(s.from_node_id, "a".repeat(64));
                assert_eq!(s.to_node_id, "b".repeat(64));
                assert_eq!(s.session_id, "sess-1");
            }
            (key, other) => panic!("{key}: unexpected {other:?}"),
        }
    }
    let mut data = session_json.clone();
    data["data"] = json!("aGk=");
    match parse(json!({ "relayData": data })) {
        IncomingRelayMessage::RelayData(d) => {
            assert_eq!(d.session_id, "sess-1");
            assert_eq!(
                teale_protocol::decode_relay_data(&d.data),
                Some(b"hi".to_vec())
            );
        }
        other => panic!("unexpected {other:?}"),
    }
    let mut offer = session_json.clone();
    offer["connectionInfo"] = json!({ "publicIP": "1.2.3.4", "publicPort": 51820 });
    offer["signature"] = json!("00");
    for key in ["offer", "answer"] {
        match (key, parse(json!({ key: offer.clone() }))) {
            ("offer", IncomingRelayMessage::Offer(p))
            | ("answer", IncomingRelayMessage::Answer(p)) => {
                assert_eq!(p.from_node_id, "a".repeat(64));
                assert_eq!(p.connection_info["publicPort"], json!(51820));
            }
            (key, other) => panic!("{key}: unexpected {other:?}"),
        }
    }
    let mut ice = session_json;
    ice["candidate"] = json!({ "ip": "1.2.3.4", "port": 1, "type": "host", "priority": 1 });
    match parse(json!({ "iceCandidate": ice })) {
        IncomingRelayMessage::IceCandidate(p) => assert_eq!(p.candidate["type"], json!("host")),
        other => panic!("unexpected {other:?}"),
    }
    for key in ["peerJoined", "peerLeft"] {
        match parse(json!({ key: { "nodeID": "c", "displayName": "n" } })) {
            IncomingRelayMessage::PeerJoined(p) | IncomingRelayMessage::PeerLeft(p) => {
                assert_eq!(p.node_id, "c");
                assert_eq!(p.display_name, "n");
            }
            other => panic!("unexpected {other:?}"),
        }
    }
    let error = json!({ "error": { "code": "invalid_signature", "message": "nope" } });
    match parse(error) {
        IncomingRelayMessage::Error(e) => {
            assert_eq!(e.code, "invalid_signature");
            assert_eq!(e.retry_after_seconds, None);
        }
        other => panic!("unexpected {other:?}"),
    }
    match parse(json!({ "somethingNew": {} })) {
        IncomingRelayMessage::Unknown(kind) => assert_eq!(kind, "somethingNew"),
        other => panic!("unexpected {other:?}"),
    }
}
