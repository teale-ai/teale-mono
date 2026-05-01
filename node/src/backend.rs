//! Unified inference backend abstraction.
//!
//! Wraps both HTTP-proxy backends (llama-server, mnn_llm) and in-process
//! engines (LiteRT-LM) behind one interface used by cluster.rs.
//!
//! All backends return a **bounded** mpsc Receiver of chunk JSON so that
//! slow downstream consumers backpressure rather than grow memory unboundedly.

use serde_json::Value;
use tokio::sync::mpsc;

use teale_protocol::openai::ChatCompletionRequest;

use crate::inference::InferenceProxy;
use crate::litert::LiteRtEngine;

pub enum Backend {
    Http(InferenceProxy),
    LiteRt(LiteRtEngine),
    Unavailable,
}

impl Backend {
    pub fn loaded_models(&self) -> Vec<String> {
        match self {
            Backend::Http(proxy) => proxy.loaded_models(),
            Backend::LiteRt(engine) => engine.loaded_models(),
            Backend::Unavailable => vec![],
        }
    }

    pub fn is_ready(&self) -> bool {
        match self {
            Backend::Http(proxy) => proxy.is_ready(),
            Backend::LiteRt(_) => true,
            Backend::Unavailable => false,
        }
    }

    pub async fn stream_completion(
        &self,
        request: &ChatCompletionRequest,
    ) -> anyhow::Result<mpsc::Receiver<Value>> {
        match self {
            Backend::Http(proxy) => proxy.stream_completion(request).await,
            Backend::LiteRt(engine) => engine.stream_completion(request).await,
            Backend::Unavailable => anyhow::bail!("no model loaded"),
        }
    }
}
