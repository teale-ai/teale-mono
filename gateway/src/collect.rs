//! Collect a full completion from one device, out of band.
//!
//! Shared by the probation benchmark (benchmark.rs) and the stranger
//! shadow replay (shadow.rs): open a session to a specific node, send one
//! non-client request, aggregate the streamed chunks into text + timing.
//! This mirrors the probe.rs dispatch shape but returns the output
//! instead of only observing latency - kept generic so every out-of-band
//! caller shares one session-lifecycle implementation (admit/open/
//! register/send/drain/close/dec, with cleanup on every failure path).

use std::time::{Duration, Instant};

use tokio::sync::mpsc;
use uuid::Uuid;

use teale_protocol::{openai::ChatCompletionRequest, ClusterMessage, InferenceRequestPayload};

use crate::relay_client::{PendingSession, SessionEvent};
use crate::state::AppState;

pub struct CollectedCompletion {
    pub text: String,
    pub ttft_ms: u64,
    pub completion_tokens: u64,
}

pub async fn collect_completion(
    state: &AppState,
    node_id: &str,
    model_id: &str,
    request: ChatCompletionRequest,
) -> anyhow::Result<CollectedCompletion> {
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
            request,
            streaming: true,
        })),
    );
    if let Err(err) = send {
        state.relay.close_session(node_id, &session_id);
        state.registry.dec_in_flight(node_id, false);
        anyhow::bail!("relay send: {}", err);
    }

    let started = Instant::now();
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
                break Ok(CollectedCompletion {
                    text,
                    ttft_ms: first_token_at.duration_since(started).as_millis() as u64,
                    completion_tokens: tokens_out.map(|v| v as u64).unwrap_or(chunk_count).max(1),
                });
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
    let _ = model_id;
    result
}
