//! Regenerates tests/fixtures/signed_netmap.json — the cross-language golden
//! fixture that both the Rust (`tests/pin_fixture.rs`) and Swift
//! (`PINKitTests`) suites verify. Deterministic: fixed signing key, fixed
//! timestamps.
//!
//! Usage: cargo run -p teale-protocol --example gen_pin_fixture > protocol/tests/fixtures/signed_netmap.json

use ed25519_dalek::{Signer, SigningKey};
use teale_protocol::{canonical_json, PinEndpoint, PinNetmap, PinNetmapMember, SignedPinNetmap};

fn main() {
    let key = SigningKey::from_bytes(&[42u8; 32]);
    let netmap = PinNetmap {
        pin_id: "11111111-2222-3333-4444-555555555555".into(),
        name: "teale-hq".into(),
        generation: 7,
        issued_at: 1_751_600_000,
        members: vec![
            PinNetmapMember {
                device_id: "dev-windows-01".into(),
                node_pubkey: "ab".repeat(32),
                display_name: Some("Front Desk PC".into()),
                serves_models: true,
                disabled: false,
                endpoints: vec![
                    PinEndpoint {
                        kind: "lan".into(),
                        addr: "192.168.1.20:41641".into(),
                    },
                    PinEndpoint {
                        kind: "reflexive".into(),
                        addr: "203.0.113.7:41641".into(),
                    },
                ],
                loaded_models: vec!["qwen3-4b-instruct".into()],
                last_seen: Some(1_751_599_990),
            },
            PinNetmapMember {
                device_id: "dev-mac-01".into(),
                node_pubkey: "cd".repeat(32),
                display_name: None,
                serves_models: false,
                disabled: true,
                endpoints: vec![],
                loaded_models: vec![],
                last_seen: None,
            },
        ],
    };
    let message = canonical_json(&netmap).expect("canonical json");
    let signed = SignedPinNetmap {
        gateway_pubkey: hex::encode(key.verifying_key().as_bytes()),
        signature: hex::encode(key.sign(&message).to_bytes()),
        netmap,
    };
    println!("{}", serde_json::to_string_pretty(&signed).expect("json"));
}
