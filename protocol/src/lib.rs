//! TealeNet wire protocol — shared between relay, node, and gateway.
//!
//! This crate is the **single source of truth** for on-the-wire types.
//! teale-node (supply) and gateway (OpenRouter-facing) both depend on it
//! to eliminate serde drift between components.
//!
//! Message envelope: every relay/cluster message is a JSON object with
//! exactly one key identifying the message type; the value is the payload.

pub mod apple_date;
pub mod cluster;
pub mod hardware;
pub mod openai;
pub mod relay;

pub use apple_date::{now_reference_seconds, reference_to_unix, unix_to_reference};
pub use cluster::{
    decode_relay_data, ClusterMessage, HeartbeatPayload, HelloAckPayload, HelloPayload,
    InferenceChunkPayload, InferenceCompletePayload, InferenceErrorCode, InferenceErrorPayload,
    InferenceRequestPayload, LoadModelPayload, ModelLoadErrorPayload, ModelLoadedPayload,
    ThermalLevel,
};
pub use hardware::{GpuBackend, HardwareCapability, NodeCapabilities, Tier};
pub use openai::{ApiMessage, ChatCompletionRequest, ModelEntry, ModelsResponse, Pricing};
pub use relay::{
    DiscoverPayload, IncomingRelayMessage, OutgoingRelayMessage, PeerNotificationPayload,
    RegisterPayload, RelayDataPayload, RelayErrorPayload, RelaySessionPayload,
};
