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
pub mod pin;
pub mod relay;

pub use apple_date::{now_reference_seconds, reference_to_unix, unix_to_reference};
pub use cluster::{
    decode_relay_data, ClusterMessage, HeartbeatPayload, HelloAckPayload, HelloPayload,
    InferenceChunkPayload, InferenceCompletePayload, InferenceErrorCode, InferenceErrorPayload,
    InferenceRequestPayload, LoadModelPayload, ModelLoadErrorPayload, ModelLoadedPayload,
    ThermalLevel,
};
pub use hardware::{GpuBackend, HardwareCapability, NodeCapabilities};
pub use openai::{ApiMessage, ChatCompletionRequest, ModelEntry, ModelsResponse, Pricing};
pub use pin::{
    canonical_json, PinEndpoint, PinNetmap, PinNetmapMember, SignedPinNetmap,
    NETMAP_MAX_AGE_SECONDS,
};
pub use relay::{
    DiscoverFilter, DiscoverPayload, IceCandidatePayload, IncomingRelayMessage, OfferAnswerPayload,
    OutgoingRelayMessage, PeerNotificationPayload, RegisterPayload, RelayDataPayload,
    RelayErrorPayload, RelaySessionPayload,
};

/// Total per-request budget (prefill + generation) a supply node allows a
/// streamed inference before it cuts the backend stream. One definition
/// shared by the node (which enforces it) and the gateway (which sizes its
/// sole-supplier first-token ceiling and heavy-hold TTL below/above it).
/// History and rationale live with the enforcement in
/// `node/src/inference.rs`.
pub const STREAM_BUDGET_SECONDS: u64 = 1800;
