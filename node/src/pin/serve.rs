//! PIN serving path: accept encrypted peer connections, run inference
//! through the same backend as DIN traffic — but admitted via the
//! PIN-first PriorityGate — and record usage counts.

use std::future::Future;
use std::sync::Arc;
use std::time::Duration;

use anyhow::Result;
use serde_json::Value;
use tokio::sync::mpsc;

use super::gate::PriorityGate;
use super::manager::PinManager;
use super::transport::{PeerConnection, PinListener};
use super::usage::{today_utc, UsageBatcher, UsageRecord};
use teale_protocol::{
    ChatCompletionRequest, ClusterMessage, InferenceChunkPayload, InferenceCompletePayload,
    InferenceErrorCode, InferenceErrorPayload, InferenceRequestPayload,
};

/// How long a PIN request may wait for an admission permit before the
/// requester is told to cascade elsewhere.
const PIN_ADMISSION_TIMEOUT: Duration = Duration::from_secs(120);

/// The slice of the inference stack the serving path needs — implemented by
/// `SwapManager` in production, fakeable in tests.
pub trait CompletionBackend: Send + Sync + 'static {
    fn loaded_models(&self) -> impl Future<Output = Vec<String>> + Send;
    fn stream_completion(
        &self,
        request: &ChatCompletionRequest,
    ) -> impl Future<Output = Result<mpsc::Receiver<Value>>> + Send;
}

impl CompletionBackend for crate::swap::SwapManager {
    async fn loaded_models(&self) -> Vec<String> {
        crate::swap::SwapManager::loaded_models(self).await
    }
    async fn stream_completion(
        &self,
        request: &ChatCompletionRequest,
    ) -> Result<mpsc::Receiver<Value>> {
        crate::swap::SwapManager::stream_completion(self, request).await
    }
}

/// Crude prompt-size estimate (chars/4) — usage tracking wants an order of
/// magnitude, not tokenizer precision.
fn estimate_tokens_in(request: &ChatCompletionRequest) -> i64 {
    let chars: usize = request
        .messages
        .iter()
        .map(|m| m.content.to_string().len())
        .sum();
    (chars / 4) as i64
}

/// Accept loop: authenticate peers against the netmap (transport authorizer
/// already gates the handshake), then serve their requests.
pub fn spawn_serving<B: CompletionBackend>(
    mut listener: PinListener,
    manager: Arc<PinManager>,
    backend: Arc<B>,
    gate: Arc<PriorityGate>,
    usage: Arc<UsageBatcher>,
    exit: Option<Arc<super::exit::ExitProvider>>,
) -> tokio::task::JoinHandle<()> {
    tokio::spawn(async move {
        while let Some(connection) = listener.accept().await {
            let peer_hex = hex::encode(connection.remote_static.as_bytes());
            let Some((pin_id, member)) = manager.member_for_wg_key(&peer_hex) else {
                connection.close();
                continue;
            };
            tokio::spawn(serve_peer(
                connection,
                pin_id,
                member.device_id,
                manager.clone(),
                backend.clone(),
                gate.clone(),
                usage.clone(),
                exit.clone(),
            ));
        }
    })
}

async fn serve_peer<B: CompletionBackend>(
    connection: Arc<PeerConnection>,
    pin_id: String,
    consumer_device_id: String,
    manager: Arc<PinManager>,
    backend: Arc<B>,
    gate: Arc<PriorityGate>,
    usage: Arc<UsageBatcher>,
    exit: Option<Arc<super::exit::ExitProvider>>,
) {
    while let Some(message) = connection.recv().await {
        match message {
            ClusterMessage::InferenceRequest(request) => {
                let connection = connection.clone();
                let backend = backend.clone();
                let gate = gate.clone();
                let usage = usage.clone();
                let manager = manager.clone();
                let pin_id = pin_id.clone();
                let consumer = consumer_device_id.clone();
                tokio::spawn(async move {
                    handle_request(
                        connection, *request, pin_id, consumer, manager, backend, gate, usage,
                    )
                    .await;
                });
            }
            // Liveness probe for offline-LAN scheduling.
            ClusterMessage::Heartbeat(hb) => {
                let _ = connection.send(&ClusterMessage::HeartbeatAck(hb)).await;
            }
            // PIN exit-node data plane: SOCKS5-over-Noise egress.
            ClusterMessage::SocksOpen(open) => {
                if let Some(exit) = &exit {
                    let connection = connection.clone();
                    let exit = exit.clone();
                    let pin_id = pin_id.clone();
                    let consumer = consumer_device_id.clone();
                    tokio::spawn(async move {
                        exit.handle_open(connection, pin_id, consumer, open).await;
                    });
                } else {
                    let _ = connection
                        .send(&ClusterMessage::SocksOpenResult(
                            teale_protocol::cluster::SocksOpenResultPayload {
                                stream_id: open.stream_id,
                                ok: false,
                                error: Some("exit not offered".to_string()),
                            },
                        ))
                        .await;
                }
            }
            ClusterMessage::SocksData(data) => {
                if let Some(exit) = &exit {
                    exit.handle_data(data).await;
                }
            }
            ClusterMessage::SocksClose(close) => {
                if let Some(exit) = &exit {
                    exit.handle_close(close).await;
                }
            }
            _ => {}
        }
    }
}

async fn send_error(
    connection: &PeerConnection,
    request_id: &str,
    message: &str,
    code: InferenceErrorCode,
) {
    let _ = connection
        .send(&ClusterMessage::InferenceError(InferenceErrorPayload {
            request_id: request_id.to_string(),
            error_message: message.to_string(),
            code: Some(code),
        }))
        .await;
}

#[allow(clippy::too_many_arguments)]
async fn handle_request<B: CompletionBackend>(
    connection: Arc<PeerConnection>,
    request: InferenceRequestPayload,
    pin_id: String,
    consumer_device_id: String,
    manager: Arc<PinManager>,
    backend: Arc<B>,
    gate: Arc<PriorityGate>,
    usage: Arc<UsageBatcher>,
) {
    let request_id = request.request_id.clone();

    // PIN admission: wait (jump ahead of DIN), bounded.
    let Some(_permit) = gate.acquire_pin(PIN_ADMISSION_TIMEOUT).await else {
        send_error(
            &connection,
            &request_id,
            "queue full",
            InferenceErrorCode::QueueFull,
        )
        .await;
        return;
    };

    let requested_model = request.request.model.clone().unwrap_or_default();
    let loaded = backend.loaded_models().await;
    if !crate::cluster::model_matches_any(&requested_model, &loaded) {
        send_error(
            &connection,
            &request_id,
            &format!("model '{requested_model}' not loaded (loaded: {loaded:?})"),
            InferenceErrorCode::ModelNotLoaded,
        )
        .await;
        return;
    }

    match backend.stream_completion(&request.request).await {
        Ok(mut rx) => {
            let mut tokens_out: i64 = 0;
            while let Some(chunk) = rx.recv().await {
                tokens_out += 1;
                let _ = connection
                    .send(&ClusterMessage::InferenceChunk(InferenceChunkPayload {
                        request_id: request_id.clone(),
                        chunk,
                    }))
                    .await;
            }
            let tokens_in = estimate_tokens_in(&request.request);
            let _ = connection
                .send(&ClusterMessage::InferenceComplete(
                    InferenceCompletePayload {
                        request_id: request_id.clone(),
                        tokens_in: Some(tokens_in as u32),
                        tokens_out: Some(tokens_out as u32),
                    },
                ))
                .await;
            // Count it (never credits). Threshold-triggered flush.
            let should_flush = usage
                .record(&UsageRecord {
                    pin_id,
                    day: today_utc(),
                    consumer_device_id,
                    model_id: requested_model,
                    tokens_in,
                    tokens_out,
                })
                .unwrap_or(false);
            if should_flush {
                let manager = manager.clone();
                let usage = usage.clone();
                tokio::spawn(async move {
                    if let Err(err) = manager.flush_usage(&usage).await {
                        tracing::warn!("pin usage flush failed: {err:#}");
                    }
                });
            }
        }
        Err(err) => {
            send_error(
                &connection,
                &request_id,
                &err.to_string(),
                InferenceErrorCode::InternalError,
            )
            .await;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::identity::NodeIdentity;
    use crate::pin::transport::dial;
    use std::path::{Path, PathBuf};
    use teale_protocol::ApiMessage;
    use tokio::sync::Semaphore;
    use x25519_dalek::{PublicKey, StaticSecret};

    struct FakeBackend;
    impl CompletionBackend for FakeBackend {
        async fn loaded_models(&self) -> Vec<String> {
            vec!["qwen3-4b".to_string()]
        }
        async fn stream_completion(
            &self,
            _request: &ChatCompletionRequest,
        ) -> Result<mpsc::Receiver<Value>> {
            let (tx, rx) = mpsc::channel(8);
            tokio::spawn(async move {
                for i in 0..3 {
                    let _ = tx.send(serde_json::json!({"token": i})).await;
                }
            });
            Ok(rx)
        }
    }

    fn temp_dir() -> PathBuf {
        let dir = std::env::temp_dir().join(format!("pin-serve-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    fn chat_request(model: &str) -> InferenceRequestPayload {
        InferenceRequestPayload {
            request_id: "req-1".into(),
            request: ChatCompletionRequest {
                model: Some(model.into()),
                messages: vec![ApiMessage {
                    role: "user".into(),
                    content: serde_json::json!("hello private world"),
                    name: None,
                    tool_calls: None,
                    tool_call_id: None,
                }],
                ..serde_json::from_str("{\"messages\":[]}").unwrap()
            },
            streaming: true,
        }
    }

    /// Manager wired to a dead gateway (network calls fail fast) but with a
    /// hand-planted netmap state — serving never needs the control plane.
    fn offline_manager(dir: &Path, members: Vec<(String, bool, bool)>) -> Arc<PinManager> {
        use ed25519_dalek::{Signer, SigningKey};
        use teale_protocol::{canonical_json, PinNetmap, PinNetmapMember, SignedPinNetmap};
        let identity = Arc::new(NodeIdentity::load_or_create_in(dir.join("id.key")).unwrap());
        let manager = PinManager::new(
            "http://127.0.0.1:9".into(), // discard port — flushes fail, serving works
            identity,
            dir.join("pin"),
            None,
        )
        .unwrap();
        let key = SigningKey::from_bytes(&[55u8; 32]);
        let netmap = PinNetmap {
            pin_id: "pin-test".into(),
            name: "test".into(),
            generation: 1,
            issued_at: crate::gateway_wallet::now_unix_secs() as i64,
            members: members
                .into_iter()
                .map(|(wg, serves, disabled)| PinNetmapMember {
                    device_id: format!("dev-{}", &wg[..2]),
                    node_pubkey: "ab".repeat(32),
                    wg_pubkey: wg,
                    display_name: None,
                    serves_models: serves,
                    offers_exit: false,
                    disabled,
                    endpoints: vec![],
                    loaded_models: vec!["qwen3-4b".into()],
                    last_seen: None,
                })
                .collect(),
        };
        let message = canonical_json(&netmap).unwrap();
        let signed = SignedPinNetmap {
            gateway_pubkey: hex::encode(key.verifying_key().as_bytes()),
            signature: hex::encode(key.sign(&message).to_bytes()),
            netmap,
        };
        manager.plant_state_for_tests("pin-test", "test", signed);
        manager
    }

    #[tokio::test]
    async fn serves_pin_inference_end_to_end_and_records_usage() {
        let dir = temp_dir();
        let server_static = StaticSecret::from([61u8; 32]);
        let client_static = StaticSecret::from([62u8; 32]);
        let client_wg = hex::encode(PublicKey::from(&client_static).as_bytes());
        let server_wg = hex::encode(PublicKey::from(&server_static).as_bytes());

        let manager = offline_manager(
            &dir,
            vec![(client_wg, false, false), (server_wg, true, false)],
        );
        let usage = UsageBatcher::new(dir.join("usage")).unwrap();
        let gate = PriorityGate::new(Arc::new(Semaphore::new(2)));
        let listener =
            PinListener::bind("127.0.0.1:0", server_static.clone(), manager.authorizer())
                .await
                .unwrap();
        let addr = listener.local_addr().unwrap();
        let _serving = spawn_serving(
            listener,
            manager.clone(),
            Arc::new(FakeBackend),
            gate,
            usage.clone(),
            None,
        );

        let connection = dial(addr, &PublicKey::from(&server_static), &client_static)
            .await
            .unwrap();
        connection
            .send(&ClusterMessage::InferenceRequest(Box::new(chat_request(
                "qwen3-4b",
            ))))
            .await
            .unwrap();

        let mut chunks = 0;
        loop {
            match tokio::time::timeout(Duration::from_secs(5), connection.recv())
                .await
                .expect("response before timeout")
                .expect("connection open")
            {
                ClusterMessage::InferenceChunk(_) => chunks += 1,
                ClusterMessage::InferenceComplete(done) => {
                    assert_eq!(done.tokens_out, Some(3));
                    break;
                }
                ClusterMessage::InferenceError(err) => {
                    panic!("unexpected error: {}", err.error_message)
                }
                _ => {}
            }
        }
        assert_eq!(chunks, 3);
        // Usage recorded locally (flush target is offline — retained).
        usage
            .flush(&reqwest::Client::new(), "http://127.0.0.1:9", "tok")
            .await
            .unwrap();
        assert_eq!(usage.pending_batches(), 1);
    }

    #[tokio::test]
    async fn unknown_model_gets_typed_error() {
        let dir = temp_dir();
        let server_static = StaticSecret::from([63u8; 32]);
        let client_static = StaticSecret::from([64u8; 32]);
        let client_wg = hex::encode(PublicKey::from(&client_static).as_bytes());

        let manager = offline_manager(&dir, vec![(client_wg, false, false)]);
        let usage = UsageBatcher::new(dir.join("usage")).unwrap();
        let gate = PriorityGate::new(Arc::new(Semaphore::new(2)));
        let listener =
            PinListener::bind("127.0.0.1:0", server_static.clone(), manager.authorizer())
                .await
                .unwrap();
        let addr = listener.local_addr().unwrap();
        let _serving = spawn_serving(listener, manager, Arc::new(FakeBackend), gate, usage, None);

        let connection = dial(addr, &PublicKey::from(&server_static), &client_static)
            .await
            .unwrap();
        connection
            .send(&ClusterMessage::InferenceRequest(Box::new(chat_request(
                "no-such-model",
            ))))
            .await
            .unwrap();
        match tokio::time::timeout(Duration::from_secs(5), connection.recv())
            .await
            .unwrap()
            .unwrap()
        {
            ClusterMessage::InferenceError(err) => {
                assert!(matches!(err.code, Some(InferenceErrorCode::ModelNotLoaded)));
            }
            other => panic!("expected typed error, got {other:?}"),
        }
    }
}
