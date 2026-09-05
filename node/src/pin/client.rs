//! PIN demand path: pick a provider (gateway-scheduled online, cached-netmap
//! fallback offline), dial it directly, stream the completion back.
//!
//! The gateway sees only `{model, ctxEstimate}`; the prompt travels on the
//! encrypted peer connection.

use std::sync::Arc;
use std::time::Duration;

use anyhow::{anyhow, bail, Result};
use serde_json::Value;
use tokio::sync::mpsc;
use x25519_dalek::PublicKey;

use super::manager::PinManager;
use super::transport::dial;
use crate::identity::NodeIdentity;
use teale_protocol::{
    ChatCompletionRequest, ClusterMessage, InferenceRequestPayload, PinNetmapMember,
};

/// Total providers tried per request (1 + 2 cascades), matching DIN.
const MAX_ATTEMPTS: usize = 3;
const DIAL_TIMEOUT: Duration = Duration::from_secs(12);

/// Terminal outcome of a streamed PIN completion.
#[derive(Debug)]
pub enum PinStreamEnd {
    Complete { tokens_in: u32, tokens_out: u32 },
    Error(String),
}

pub struct PinStream {
    pub provider_device_id: String,
    pub pin_id: String,
    pub chunks: mpsc::Receiver<Value>,
    pub end: tokio::sync::oneshot::Receiver<PinStreamEnd>,
}

/// A dialable candidate: netmap member + owning network.
#[derive(Debug, Clone)]
struct Candidate {
    pin_id: String,
    member: PinNetmapMember,
}

/// Run one PIN inference. Tries gateway scheduling per active network first
/// (metadata only), falling back to cached-netmap candidates when the
/// gateway is unreachable; cascades across up to MAX_ATTEMPTS providers.
pub async fn pin_completion(
    manager: &Arc<PinManager>,
    identity: &Arc<NodeIdentity>,
    model: &str,
    request: ChatCompletionRequest,
) -> Result<PinStream> {
    let mut tried: Vec<String> = Vec::new(); // node_pubkeys already attempted
    let mut last_error = anyhow!("no providers available for model {model}");

    for _ in 0..MAX_ATTEMPTS {
        let Some(candidate) = next_candidate(manager, model, &tried).await else {
            break;
        };
        tried.push(candidate.member.node_pubkey.clone());
        match attempt(identity, &candidate, model, &request).await {
            Ok(stream) => return Ok(stream),
            Err(err) => {
                tracing::warn!(
                    "pin provider {} failed: {err:#}",
                    candidate.member.device_id
                );
                last_error = err;
            }
        }
    }
    Err(last_error)
}

/// Gateway-scheduled choice with cached-netmap fallback.
async fn next_candidate(
    manager: &Arc<PinManager>,
    model: &str,
    exclude: &[String],
) -> Option<Candidate> {
    // Online: ask the gateway per active network (it has live load signals).
    for state in manager.snapshot() {
        if state.membership != "active" {
            continue;
        }
        if let Ok(resp) = manager.schedule(&state.pin_id, model, exclude).await {
            // Connection material (wg key + endpoints) comes from the netmap.
            if let Some(member) = state.netmap.as_ref().and_then(|signed| {
                signed
                    .netmap
                    .members
                    .iter()
                    .find(|m| m.device_id == resp.device_id)
                    .cloned()
            }) {
                return Some(Candidate {
                    pin_id: state.pin_id.clone(),
                    member,
                });
            }
        }
    }
    // Offline-LAN fallback: cached netmaps, least-recently-tried first.
    manager
        .serving_peers_for_model(model)
        .into_iter()
        .filter(|(_, m)| !exclude.contains(&m.node_pubkey))
        .map(|(pin_id, member)| Candidate { pin_id, member })
        .next()
}

async fn attempt(
    identity: &Arc<NodeIdentity>,
    candidate: &Candidate,
    model: &str,
    request: &ChatCompletionRequest,
) -> Result<PinStream> {
    let wg_bytes: [u8; 32] = hex::decode(&candidate.member.wg_pubkey)
        .ok()
        .and_then(|b| b.try_into().ok())
        .ok_or_else(|| anyhow!("provider has no usable wg pubkey"))?;
    let wg_pubkey = PublicKey::from(wg_bytes);
    let local_static = identity.wg_static();

    // Dial ladder: lan endpoints first, then reflexive. (Relay fallback is
    // future work — see docs/pin-noise-protocol.md.)
    let mut endpoints: Vec<&teale_protocol::PinEndpoint> = candidate
        .member
        .endpoints
        .iter()
        .filter(|e| e.kind == "lan")
        .collect();
    endpoints.extend(
        candidate
            .member
            .endpoints
            .iter()
            .filter(|e| e.kind == "reflexive"),
    );
    if endpoints.is_empty() {
        bail!("provider advertises no dialable endpoints");
    }

    let mut connection = None;
    for endpoint in endpoints {
        let Ok(addr) = endpoint.addr.parse() else {
            continue;
        };
        match tokio::time::timeout(DIAL_TIMEOUT, dial(addr, &wg_pubkey, &local_static)).await {
            Ok(Ok(conn)) => {
                connection = Some(conn);
                break;
            }
            _ => continue,
        }
    }
    let connection = connection.ok_or_else(|| anyhow!("all endpoints undialable"))?;

    let request_id = uuid::Uuid::new_v4().to_string();
    let mut payload = request.clone();
    payload.model = Some(model.to_string());
    connection
        .send(&ClusterMessage::InferenceRequest(Box::new(
            InferenceRequestPayload {
                request_id: request_id.clone(),
                request: payload,
                streaming: true,
            },
        )))
        .await?;

    let (chunk_tx, chunks) = mpsc::channel(256);
    let (end_tx, end) = tokio::sync::oneshot::channel();
    let provider_device_id = candidate.member.device_id.clone();
    let pin_id = candidate.pin_id.clone();
    let expected_request = request_id.clone();
    tokio::spawn(async move {
        let mut end_tx = Some(end_tx);
        while let Some(message) = connection.recv().await {
            match message {
                ClusterMessage::InferenceChunk(chunk) if chunk.request_id == expected_request => {
                    if chunk_tx.send(chunk.chunk).await.is_err() {
                        break;
                    }
                }
                ClusterMessage::InferenceComplete(done) if done.request_id == expected_request => {
                    if let Some(tx) = end_tx.take() {
                        let _ = tx.send(PinStreamEnd::Complete {
                            tokens_in: done.tokens_in.unwrap_or(0),
                            tokens_out: done.tokens_out.unwrap_or(0),
                        });
                    }
                    break;
                }
                ClusterMessage::InferenceError(err) if err.request_id == expected_request => {
                    if let Some(tx) = end_tx.take() {
                        let _ = tx.send(PinStreamEnd::Error(err.error_message));
                    }
                    break;
                }
                _ => {}
            }
        }
        // Peer vanished mid-stream.
        if let Some(tx) = end_tx.take() {
            let _ = tx.send(PinStreamEnd::Error("provider disconnected".into()));
        }
        connection.close();
    });

    Ok(PinStream {
        provider_device_id,
        pin_id,
        chunks,
        end,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::pin::gate::PriorityGate;
    use crate::pin::serve::{spawn_serving, CompletionBackend};
    use crate::pin::transport::PinListener;
    use crate::pin::usage::UsageBatcher;
    use anyhow::Result;
    use ed25519_dalek::{Signer, SigningKey};
    use std::path::PathBuf;
    use teale_protocol::{canonical_json, PinEndpoint, PinNetmap, SignedPinNetmap};
    use tokio::sync::Semaphore;
    use x25519_dalek::StaticSecret;

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
                for i in 0..2 {
                    let _ = tx.send(serde_json::json!({"delta": i})).await;
                }
            });
            Ok(rx)
        }
    }

    fn temp_dir() -> PathBuf {
        let dir = std::env::temp_dir().join(format!("pin-client-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    fn make_member(
        device: &str,
        wg: &str,
        endpoints: Vec<PinEndpoint>,
        models: &[&str],
    ) -> PinNetmapMember {
        PinNetmapMember {
            device_id: device.into(),
            node_pubkey: format!("{device}-node"),
            wg_pubkey: wg.into(),
            display_name: None,
            serves_models: true,
            offers_exit: false,
            disabled: false,
            endpoints,
            loaded_models: models.iter().map(|s| s.to_string()).collect(),
            last_seen: None,
        }
    }

    fn plant(manager: &Arc<PinManager>, members: Vec<PinNetmapMember>) {
        let key = SigningKey::from_bytes(&[91u8; 32]);
        let netmap = PinNetmap {
            pin_id: "pin-x".into(),
            name: "x".into(),
            generation: 1,
            issued_at: crate::gateway_wallet::now_unix_secs() as i64,
            members,
        };
        let message = canonical_json(&netmap).unwrap();
        let signed = SignedPinNetmap {
            gateway_pubkey: hex::encode(key.verifying_key().as_bytes()),
            signature: hex::encode(key.sign(&message).to_bytes()),
            netmap,
        };
        manager.plant_state_for_tests("pin-x", "x", signed);
    }

    /// Offline end-to-end: dead gateway forces the cached-netmap fallback;
    /// the full demand path (schedule→dial→stream→complete) runs against an
    /// in-process serving node.
    #[tokio::test]
    async fn offline_demand_path_streams_and_cascades() {
        // Provider node.
        let provider_dir = temp_dir();
        let provider_identity = Arc::new(
            crate::identity::NodeIdentity::load_or_create_in(provider_dir.join("id.key")).unwrap(),
        );
        let provider_manager = PinManager::new(
            "http://127.0.0.1:9".into(),
            provider_identity.clone(),
            provider_dir.join("pin"),
            None,
        )
        .unwrap();

        // Consumer node.
        let consumer_dir = temp_dir();
        let consumer_identity = Arc::new(
            crate::identity::NodeIdentity::load_or_create_in(consumer_dir.join("id.key")).unwrap(),
        );
        let consumer_manager = PinManager::new(
            "http://127.0.0.1:9".into(),
            consumer_identity.clone(),
            consumer_dir.join("pin"),
            None,
        )
        .unwrap();

        // Provider listens; both sides share a netmap listing provider +
        // consumer, plus a DEAD provider entry the cascade must skip.
        let listener = PinListener::bind(
            "127.0.0.1:0",
            provider_identity.wg_static(),
            provider_manager.authorizer(),
        )
        .await
        .unwrap();
        let provider_addr = listener.local_addr().unwrap();

        let dead_wg = hex::encode(PublicKey::from(&StaticSecret::from([99u8; 32])).as_bytes());
        let members = vec![
            // Dead provider first — the cascade must survive it.
            make_member(
                "dev-dead",
                &dead_wg,
                vec![PinEndpoint {
                    kind: "lan".into(),
                    addr: "127.0.0.1:1".into(), // nothing listens here
                }],
                &["qwen3-4b"],
            ),
            make_member(
                "dev-provider",
                &provider_identity.wg_pubkey_hex(),
                vec![PinEndpoint {
                    kind: "lan".into(),
                    addr: provider_addr.to_string(),
                }],
                &["qwen3-4b"],
            ),
            make_member(
                "dev-consumer",
                &consumer_identity.wg_pubkey_hex(),
                vec![],
                &[],
            ),
        ];
        plant(&provider_manager, members.clone());
        plant(&consumer_manager, members);

        let usage = UsageBatcher::new(provider_dir.join("usage")).unwrap();
        let _serving = spawn_serving(
            listener,
            provider_manager,
            Arc::new(FakeBackend),
            PriorityGate::new(Arc::new(Semaphore::new(2))),
            usage,
            None,
        );

        let request: ChatCompletionRequest = serde_json::from_value(serde_json::json!({
            "messages": [{"role": "user", "content": "hi"}]
        }))
        .unwrap();
        let mut stream = pin_completion(&consumer_manager, &consumer_identity, "qwen3-4b", request)
            .await
            .expect("cascade reaches the live provider");
        assert_eq!(stream.provider_device_id, "dev-provider");

        let mut chunks = 0;
        while stream.chunks.recv().await.is_some() {
            chunks += 1;
        }
        assert_eq!(chunks, 2);
        match stream.end.await.unwrap() {
            PinStreamEnd::Complete { tokens_out, .. } => assert_eq!(tokens_out, 2),
            PinStreamEnd::Error(err) => panic!("unexpected error: {err}"),
        }
    }

    #[tokio::test]
    async fn no_candidates_is_a_clean_error() {
        let dir = temp_dir();
        let identity =
            Arc::new(crate::identity::NodeIdentity::load_or_create_in(dir.join("id.key")).unwrap());
        let manager = PinManager::new(
            "http://127.0.0.1:9".into(),
            identity.clone(),
            dir.join("pin"),
            None,
        )
        .unwrap();
        let request: ChatCompletionRequest =
            serde_json::from_value(serde_json::json!({"messages": []})).unwrap();
        let result = pin_completion(&manager, &identity, "qwen3-4b", request).await;
        match result {
            Err(err) => assert!(err.to_string().contains("no providers")),
            Ok(_) => panic!("expected no-providers error"),
        }
    }
}
