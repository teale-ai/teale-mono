//! Cross-language golden fixture check. The Swift PINKit test suite verifies
//! the same file; if this fixture or the canonicalization rules change, both
//! suites must be updated together (regenerate with
//! `cargo run -p teale-protocol --example gen_pin_fixture`).

use teale_protocol::SignedPinNetmap;

const FIXTURE: &str = include_str!("fixtures/signed_netmap.json");

#[test]
fn signed_netmap_fixture_verifies() {
    let signed: SignedPinNetmap = serde_json::from_str(FIXTURE).expect("fixture parses");
    assert!(
        signed.verify(&signed.gateway_pubkey.clone()),
        "fixture signature must verify"
    );
    assert_eq!(signed.netmap.members.len(), 2);
    assert_eq!(signed.netmap.generation, 7);
}

#[test]
fn signed_netmap_fixture_rejects_tampering() {
    let mut signed: SignedPinNetmap = serde_json::from_str(FIXTURE).expect("fixture parses");
    signed.netmap.members[1].disabled = false;
    assert!(!signed.verify(&signed.gateway_pubkey.clone()));
}
