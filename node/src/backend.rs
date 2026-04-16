//! Unified inference backend abstraction.
//!
//! Wraps both HTTP-proxy backends (llama-server, mnn_llm) and subprocess
//! backends (LiteRT-LM) behind a single interface used by cluster.rs.

use serde_json::Value;
use tokio::sync::mpsc;

use crate::cluster::ChatCompletionRequest;
use crate::inference::InferenceProxy;
use crate::litert::LiteRtEngine;

/// Unified backend for inference — either an HTTP proxy to a subprocess
/// or an in-process engine.
pub enum Backend {
    /// HTTP proxy to llama-server or mnn_llm subprocess.
    Http(InferenceProxy),
    /// LiteRT-LM subprocess bridge.
    LiteRt(LiteRtEngine),
}

impl Backend {
    pub fn loaded_models(&self) -> Vec<String> {
        match self {
            Backend::Http(proxy) => proxy.loaded_models(),
            Backend::LiteRt(engine) => engine.loaded_models(),
        }
    }

    pub async fn stream_completion(
        &self,
        request: &ChatCompletionRequest,
    ) -> anyhow::Result<mpsc::UnboundedReceiver<Value>> {
        match self {
            Backend::Http(proxy) => proxy.stream_completion(request).await,
            Backend::LiteRt(engine) => engine.stream_completion(request).await,
        }
    }
}
