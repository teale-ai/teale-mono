//! Private Inference Network (PIN) data plane.
//!
//! Direct device↔device encrypted inference: Noise_IK handshake + transport
//! (wire-compatible with the Swift WANKit implementation — see
//! docs/pin-noise-protocol.md and the golden vectors in
//! protocol/tests/fixtures/noise_vectors.json).

pub mod cli;
pub mod client;
pub mod endpoints;
pub mod exit;
pub mod gate;
pub mod manager;
pub mod noise;
pub mod runtime;
pub mod serve;
pub mod transport;
pub mod usage;
