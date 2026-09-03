//! Private Inference Network (PIN) wire types.
//!
//! The netmap is the gateway-signed membership snapshot each member device
//! caches and uses to authenticate peers on the data plane. Devices pin the
//! gateway's Ed25519 public key and verify the signature over a canonical
//! (recursively key-sorted) JSON encoding of the netmap, so Swift and Rust
//! implementations can reproduce identical bytes.

use serde::{Deserialize, Serialize};

/// Cached netmaps older than this are rejected and the device refuses new
/// data-plane connections until it can refresh (spec §14).
pub const NETMAP_MAX_AGE_SECONDS: i64 = 24 * 60 * 60;

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct PinEndpoint {
    /// "lan" | "reflexive" | "relay"
    pub kind: String,
    /// "ip:port" for lan/reflexive; relay node id for relay.
    pub addr: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct PinNetmapMember {
    pub device_id: String,
    /// Ed25519 hex (relay identity pubkey).
    pub node_pubkey: String,
    /// X25519 hex — the Noise static key peers authenticate on the data
    /// plane. NOT derivable from `node_pubkey` (different scalar derivation);
    /// devices advertise it on sync.
    #[serde(default)]
    pub wg_pubkey: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub display_name: Option<String>,
    pub serves_models: bool,
    /// This member offers itself as a SOCKS5 exit node for the network
    /// (Phase 1 exit-node data plane). Independent of `serves_models`.
    #[serde(default)]
    pub offers_exit: bool,
    pub disabled: bool,
    #[serde(default)]
    pub endpoints: Vec<PinEndpoint>,
    #[serde(default)]
    pub loaded_models: Vec<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub last_seen: Option<i64>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct PinNetmap {
    pub pin_id: String,
    pub name: String,
    pub generation: i64,
    pub issued_at: i64,
    pub members: Vec<PinNetmapMember>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct SignedPinNetmap {
    pub netmap: PinNetmap,
    /// Gateway Ed25519 public key, hex.
    pub gateway_pubkey: String,
    /// Ed25519 signature over `canonical_json(netmap)`, hex.
    pub signature: String,
}

/// Serialize with all object keys sorted recursively, producing identical
/// bytes regardless of struct field order or serializer. Swift reproduces
/// this with `.sortedKeys` JSON encoding of the same shape.
pub fn canonical_json<T: Serialize>(value: &T) -> Result<Vec<u8>, serde_json::Error> {
    let value = serde_json::to_value(value)?;
    let sorted = sort_json(value);
    serde_json::to_vec(&sorted)
}

fn sort_json(value: serde_json::Value) -> serde_json::Value {
    match value {
        serde_json::Value::Object(map) => {
            // serde_json's default Map preserves insertion order; rebuild in
            // sorted order so serialization is deterministic.
            let mut entries: Vec<(String, serde_json::Value)> = map.into_iter().collect();
            entries.sort_by(|a, b| a.0.cmp(&b.0));
            let mut sorted = serde_json::Map::new();
            for (k, v) in entries {
                sorted.insert(k, sort_json(v));
            }
            serde_json::Value::Object(sorted)
        }
        serde_json::Value::Array(items) => {
            serde_json::Value::Array(items.into_iter().map(sort_json).collect())
        }
        other => other,
    }
}

impl SignedPinNetmap {
    /// Verify the gateway signature. `pinned_gateway_pubkey` is the key the
    /// device trusts (hex); the embedded `gateway_pubkey` must match it —
    /// otherwise any keypair could sign a forged netmap.
    pub fn verify(&self, pinned_gateway_pubkey: &str) -> bool {
        if !self
            .gateway_pubkey
            .eq_ignore_ascii_case(pinned_gateway_pubkey)
        {
            return false;
        }
        let Ok(pubkey_bytes) = hex::decode(&self.gateway_pubkey) else {
            return false;
        };
        let Ok(pubkey_arr): Result<[u8; 32], _> = pubkey_bytes.try_into() else {
            return false;
        };
        let Ok(verifying_key) = ed25519_dalek::VerifyingKey::from_bytes(&pubkey_arr) else {
            return false;
        };
        let Ok(sig_bytes) = hex::decode(&self.signature) else {
            return false;
        };
        let Ok(sig_arr): Result<[u8; 64], _> = sig_bytes.as_slice().try_into() else {
            return false;
        };
        let signature = ed25519_dalek::Signature::from_bytes(&sig_arr);
        let Ok(message) = canonical_json(&self.netmap) else {
            return false;
        };
        use ed25519_dalek::Verifier;
        verifying_key.verify(&message, &signature).is_ok()
    }

    /// True when the netmap is too old to trust for new connections.
    pub fn is_stale(&self, now_unix: i64) -> bool {
        now_unix - self.netmap.issued_at > NETMAP_MAX_AGE_SECONDS
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use ed25519_dalek::{Signer, SigningKey};

    fn sample_netmap() -> PinNetmap {
        PinNetmap {
            pin_id: "pin-1".into(),
            name: "teale-hq".into(),
            generation: 7,
            issued_at: 1_750_000_000,
            members: vec![PinNetmapMember {
                device_id: "dev-1".into(),
                node_pubkey: "ab".repeat(32),
                wg_pubkey: "cd".repeat(32),
                display_name: Some("Alice's PC".into()),
                serves_models: true,
                disabled: false,
                endpoints: vec![PinEndpoint {
                    kind: "lan".into(),
                    addr: "192.168.1.20:41641".into(),
                }],
                loaded_models: vec!["qwen3-4b".into()],
                last_seen: Some(1_750_000_100),
            }],
        }
    }

    fn sign(netmap: &PinNetmap, key: &SigningKey) -> SignedPinNetmap {
        let message = canonical_json(netmap).unwrap();
        SignedPinNetmap {
            netmap: netmap.clone(),
            gateway_pubkey: hex::encode(key.verifying_key().as_bytes()),
            signature: hex::encode(key.sign(&message).to_bytes()),
        }
    }

    #[test]
    fn serde_round_trip_is_camel_case() {
        let signed = sign(&sample_netmap(), &SigningKey::from_bytes(&[7u8; 32]));
        let json = serde_json::to_string(&signed).unwrap();
        assert!(json.contains("\"pinId\""));
        assert!(json.contains("\"nodePubkey\""));
        assert!(json.contains("\"issuedAt\""));
        assert!(json.contains("\"gatewayPubkey\""));
        let back: SignedPinNetmap = serde_json::from_str(&json).unwrap();
        assert_eq!(back, signed);
    }

    #[test]
    fn canonical_json_sorts_keys_recursively() {
        let scrambled: serde_json::Value =
            serde_json::from_str(r#"{"zeta":1,"alpha":{"nested_z":1,"nested_a":[{"b":2,"a":1}]}}"#)
                .unwrap();
        let bytes = canonical_json(&scrambled).unwrap();
        assert_eq!(
            String::from_utf8(bytes).unwrap(),
            r#"{"alpha":{"nested_a":[{"a":1,"b":2}],"nested_z":1},"zeta":1}"#
        );
    }

    #[test]
    fn verify_accepts_valid_signature() {
        let key = SigningKey::from_bytes(&[42u8; 32]);
        let signed = sign(&sample_netmap(), &key);
        let pinned = hex::encode(key.verifying_key().as_bytes());
        assert!(signed.verify(&pinned));
        assert!(signed.verify(&pinned.to_uppercase()));
    }

    #[test]
    fn verify_rejects_tampering_and_wrong_key() {
        let key = SigningKey::from_bytes(&[42u8; 32]);
        let pinned = hex::encode(key.verifying_key().as_bytes());

        let mut tampered = sign(&sample_netmap(), &key);
        tampered.netmap.members[0].serves_models = false;
        assert!(!tampered.verify(&pinned));

        // Signed by a different key than the device pins: embedded pubkey
        // mismatch must fail even though the signature itself is valid.
        let other = SigningKey::from_bytes(&[9u8; 32]);
        let forged = sign(&sample_netmap(), &other);
        assert!(!forged.verify(&pinned));
    }

    #[test]
    fn staleness_window() {
        let key = SigningKey::from_bytes(&[42u8; 32]);
        let signed = sign(&sample_netmap(), &key);
        let issued = signed.netmap.issued_at;
        assert!(!signed.is_stale(issued + NETMAP_MAX_AGE_SECONDS));
        assert!(signed.is_stale(issued + NETMAP_MAX_AGE_SECONDS + 1));
    }
}
