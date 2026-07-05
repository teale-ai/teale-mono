//! Private Inference Network (PIN) data plane.
//!
//! Direct device↔device encrypted inference: Noise_IK handshake + transport
//! (wire-compatible with the Swift WANKit implementation — see
//! docs/pin-noise-protocol.md and the golden vectors in
//! protocol/tests/fixtures/noise_vectors.json).

pub mod client;
pub mod endpoints;
pub mod gate;
pub mod manager;
pub mod noise;
pub mod serve;
pub mod transport;
pub mod usage;
