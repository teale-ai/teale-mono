//! Noise_IK_25519_ChaChaPoly_BLAKE2s — wire-compatible with WANKit's Swift
//! implementation, including its two deliberate spec deviations:
//!
//! 1. Every DH output is wrapped in HKDF-SHA256(salt="", info="", 32B)
//!    because CryptoKit cannot expose raw X25519 shared secrets.
//! 2. msg2's `se` token re-mixes DH(initiator_ephemeral, responder_static)
//!    — a repeat of `es` — instead of standard IK's
//!    DH(initiator_static, responder_ephemeral).
//!
//! Do NOT "correct" either deviation: the Swift side is deployed. Golden
//! vectors from the Swift implementation live in
//! protocol/tests/fixtures/noise_vectors.json and are replayed below.

use anyhow::{anyhow, bail, Context, Result};
use blake2::digest::consts::U32;
use blake2::{Blake2s, Digest};
use chacha20poly1305::aead::{Aead, Payload};
use chacha20poly1305::{ChaCha20Poly1305, KeyInit, Nonce};
use x25519_dalek::{PublicKey, StaticSecret};

type Blake2s256 = Blake2s<U32>;

const PROTOCOL_NAME: &[u8] = b"Noise_IK_25519_ChaChaPoly_BLAKE2s";
const BLAKE2S_BLOCK_SIZE: usize = 64;
const TAG_LEN: usize = 16;
/// Receiver-side anti-replay window (bits), matching NoiseSession.swift.
const REPLAY_WINDOW: u64 = 2048;

fn blake2s(data: &[u8]) -> [u8; 32] {
    let mut hasher = Blake2s256::new();
    hasher.update(data);
    hasher.finalize().into()
}

fn mix_hash(h: &[u8; 32], data: &[u8]) -> [u8; 32] {
    let mut hasher = Blake2s256::new();
    hasher.update(h);
    hasher.update(data);
    hasher.finalize().into()
}

fn hmac_blake2s(key: &[u8], data: &[u8]) -> [u8; 32] {
    let mut normalized = if key.len() > BLAKE2S_BLOCK_SIZE {
        blake2s(key).to_vec()
    } else {
        key.to_vec()
    };
    normalized.resize(BLAKE2S_BLOCK_SIZE, 0);
    let mut ipad = vec![0u8; BLAKE2S_BLOCK_SIZE];
    let mut opad = vec![0u8; BLAKE2S_BLOCK_SIZE];
    for i in 0..BLAKE2S_BLOCK_SIZE {
        ipad[i] = normalized[i] ^ 0x36;
        opad[i] = normalized[i] ^ 0x5c;
    }
    let inner = blake2s(&[ipad.as_slice(), data].concat());
    blake2s(&[opad.as_slice(), inner.as_slice()].concat())
}

/// Noise HKDF (2 outputs) over HMAC-BLAKE2s.
fn noise_hkdf(chaining_key: &[u8; 32], ikm: &[u8]) -> ([u8; 32], [u8; 32]) {
    let temp = hmac_blake2s(chaining_key, ikm);
    let out1 = hmac_blake2s(&temp, &[0x01]);
    let out2 = hmac_blake2s(&temp, &[out1.as_slice(), &[0x02]].concat());
    (out1, out2)
}

/// The WANKit DH: X25519 then HKDF-SHA256(salt empty, info empty, 32 bytes).
fn dh(private: &StaticSecret, public: &PublicKey) -> [u8; 32] {
    let raw = private.diffie_hellman(public);
    let hk = hkdf::Hkdf::<sha2::Sha256>::new(None, raw.as_bytes());
    let mut out = [0u8; 32];
    hk.expand(&[], &mut out)
        .expect("32 bytes is valid for HKDF-SHA256");
    out
}

/// 12-byte AEAD nonce: 4 zero bytes ++ 8-byte little-endian counter.
fn aead_nonce(counter: u64) -> Nonce {
    let mut bytes = [0u8; 12];
    bytes[4..].copy_from_slice(&counter.to_le_bytes());
    Nonce::from(bytes)
}

fn encrypt(key: &[u8; 32], counter: u64, ad: &[u8], plaintext: &[u8]) -> Vec<u8> {
    let cipher = ChaCha20Poly1305::new(key.into());
    cipher
        .encrypt(
            &aead_nonce(counter),
            Payload {
                msg: plaintext,
                aad: ad,
            },
        )
        .expect("ChaCha20Poly1305 encryption is infallible for in-memory buffers")
}

fn decrypt(key: &[u8; 32], counter: u64, ad: &[u8], ciphertext_and_tag: &[u8]) -> Result<Vec<u8>> {
    if ciphertext_and_tag.len() < TAG_LEN {
        bail!("ciphertext shorter than tag");
    }
    let cipher = ChaCha20Poly1305::new(key.into());
    cipher
        .decrypt(
            &aead_nonce(counter),
            Payload {
                msg: ciphertext_and_tag,
                aad: ad,
            },
        )
        .map_err(|_| anyhow!("AEAD decryption failed"))
}

fn initialize_symmetric() -> ([u8; 32], [u8; 32]) {
    // Swift: names ≤32 bytes are zero-padded, longer names are hashed.
    // This protocol name is 33 bytes, so it is hashed.
    let h = if PROTOCOL_NAME.len() <= 32 {
        let mut padded = [0u8; 32];
        padded[..PROTOCOL_NAME.len()].copy_from_slice(PROTOCOL_NAME);
        padded
    } else {
        blake2s(PROTOCOL_NAME)
    };
    (h, h) // (ck, h)
}

/// Result of a completed handshake, before being wrapped in a session.
pub struct TransportKeys {
    pub send_key: [u8; 32],
    pub receive_key: [u8; 32],
    pub handshake_hash: [u8; 32],
}

/// Initiator state between msg1 and msg2.
pub struct InitiatorState {
    ck: [u8; 32],
    h: [u8; 32],
    local_ephemeral: StaticSecret,
    remote_static: PublicKey,
}

/// Build msg1. `payload` is a replay-protection timestamp in production
/// (see `timestamp_payload`); injectable for the golden-vector tests.
pub fn initiator_begin(
    local_static: &StaticSecret,
    remote_static: &PublicKey,
    ephemeral: StaticSecret,
    payload: &[u8],
) -> (Vec<u8>, InitiatorState) {
    let (mut ck, mut h) = initialize_symmetric();
    h = mix_hash(&h, remote_static.as_bytes());

    // -> e
    let eph_pub = PublicKey::from(&ephemeral);
    h = mix_hash(&h, eph_pub.as_bytes());
    let mut message = eph_pub.as_bytes().to_vec();

    // -> es
    let es = dh(&ephemeral, remote_static);
    let (ck1, k1) = noise_hkdf(&ck, &es);
    ck = ck1;

    // -> s (encrypted initiator static pub)
    let local_static_pub = PublicKey::from(local_static);
    let encrypted_static = encrypt(&k1, 0, &h, local_static_pub.as_bytes());
    h = mix_hash(&h, &encrypted_static);
    message.extend_from_slice(&encrypted_static);

    // -> ss
    let ss = dh(local_static, remote_static);
    let (ck2, k2) = noise_hkdf(&ck, &ss);
    ck = ck2;

    let encrypted_payload = encrypt(&k2, 0, &h, payload);
    h = mix_hash(&h, &encrypted_payload);
    message.extend_from_slice(&encrypted_payload);

    (
        message,
        InitiatorState {
            ck,
            h,
            local_ephemeral: ephemeral,
            remote_static: *remote_static,
        },
    )
}

/// Consume msg2 and derive transport keys (initiator side).
pub fn initiator_finish(state: InitiatorState, message2: &[u8]) -> Result<TransportKeys> {
    if message2.len() < 32 {
        bail!("message2 too short");
    }
    let mut ck = state.ck;
    let mut h = state.h;

    // <- e
    let remote_eph =
        PublicKey::from(<[u8; 32]>::try_from(&message2[..32]).expect("checked length above"));
    h = mix_hash(&h, remote_eph.as_bytes());

    // <- ee
    let ee = dh(&state.local_ephemeral, &remote_eph);
    let (ck1, _k1) = noise_hkdf(&ck, &ee);
    ck = ck1;

    // <- "se" — WANKit deviation: DH(initiator_ephemeral, responder_static),
    // a repeat of es. See module docs.
    let se = dh(&state.local_ephemeral, &state.remote_static);
    let (ck2, k2) = noise_hkdf(&ck, &se);
    ck = ck2;

    let encrypted_payload = &message2[32..];
    if !encrypted_payload.is_empty() {
        decrypt(&k2, 0, &h, encrypted_payload).context("msg2 payload decryption failed")?;
        h = mix_hash(&h, encrypted_payload);
    }

    let (send_key, receive_key) = noise_hkdf(&ck, &[]);
    Ok(TransportKeys {
        send_key,
        receive_key,
        handshake_hash: h,
    })
}

/// Consume msg1 and produce msg2 + transport keys (responder side).
/// Returns the initiator's authenticated static public key for the caller to
/// check against the netmap.
pub fn responder_complete(
    local_static: &StaticSecret,
    message1: &[u8],
    ephemeral: StaticSecret,
    payload: &[u8],
) -> Result<(Vec<u8>, TransportKeys, PublicKey)> {
    if message1.len() < 32 + 32 + TAG_LEN {
        bail!("message1 too short");
    }
    let (mut ck, mut h) = initialize_symmetric();
    let local_static_pub = PublicKey::from(local_static);
    h = mix_hash(&h, local_static_pub.as_bytes());

    // -> e
    let remote_eph =
        PublicKey::from(<[u8; 32]>::try_from(&message1[..32]).expect("checked length above"));
    h = mix_hash(&h, remote_eph.as_bytes());

    // -> es (responder mirror)
    let es = dh(local_static, &remote_eph);
    let (ck1, k1) = noise_hkdf(&ck, &es);
    ck = ck1;

    // -> s
    let encrypted_static = &message1[32..32 + 32 + TAG_LEN];
    let remote_static_bytes =
        decrypt(&k1, 0, &h, encrypted_static).context("initiator static key decryption failed")?;
    let remote_static = PublicKey::from(
        <[u8; 32]>::try_from(remote_static_bytes.as_slice())
            .map_err(|_| anyhow!("initiator static key has wrong length"))?,
    );
    h = mix_hash(&h, encrypted_static);

    // -> ss
    let ss = dh(local_static, &remote_static);
    let (ck2, k2) = noise_hkdf(&ck, &ss);
    ck = ck2;

    let encrypted_payload = &message1[32 + 32 + TAG_LEN..];
    if !encrypted_payload.is_empty() {
        decrypt(&k2, 0, &h, encrypted_payload).context("msg1 payload decryption failed")?;
        h = mix_hash(&h, encrypted_payload);
    }

    // <- e
    let eph_pub = PublicKey::from(&ephemeral);
    h = mix_hash(&h, eph_pub.as_bytes());
    let mut reply = eph_pub.as_bytes().to_vec();

    // <- ee
    let ee = dh(&ephemeral, &remote_eph);
    let (ck3, _k3) = noise_hkdf(&ck, &ee);
    ck = ck3;

    // <- "se" — WANKit deviation (see module docs): responder mixes
    // DH(responder_static, initiator_ephemeral), the es mirror.
    let se = dh(local_static, &remote_eph);
    let (ck4, k4) = noise_hkdf(&ck, &se);
    ck = ck4;

    let encrypted_reply_payload = encrypt(&k4, 0, &h, payload);
    h = mix_hash(&h, &encrypted_reply_payload);
    reply.extend_from_slice(&encrypted_reply_payload);

    let (initiator_send, initiator_receive) = noise_hkdf(&ck, &[]);
    Ok((
        reply,
        TransportKeys {
            // Reversed relative to the initiator.
            send_key: initiator_receive,
            receive_key: initiator_send,
            handshake_hash: h,
        },
        remote_static,
    ))
}

/// Production handshake payload: 8-byte BE seconds ++ 4-byte BE nanos.
pub fn timestamp_payload() -> Vec<u8> {
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default();
    let mut data = Vec::with_capacity(12);
    data.extend_from_slice(&now.as_secs().to_be_bytes());
    data.extend_from_slice(&now.subsec_nanos().to_be_bytes());
    data
}

/// Post-handshake symmetric transport with per-direction counters and a
/// sliding anti-replay window — packet format `[8B LE counter][ct][tag]`.
pub struct NoiseSession {
    send_key: [u8; 32],
    receive_key: [u8; 32],
    pub handshake_hash: [u8; 32],
    send_counter: u64,
    replay_high_water: u64,
    replay_bitmap: [u64; 32],
}

impl NoiseSession {
    pub fn new(keys: TransportKeys) -> Self {
        Self {
            send_key: keys.send_key,
            receive_key: keys.receive_key,
            handshake_hash: keys.handshake_hash,
            send_counter: 0,
            replay_high_water: 0,
            replay_bitmap: [0; 32],
        }
    }

    pub fn encrypt(&mut self, plaintext: &[u8]) -> Vec<u8> {
        let counter = self.send_counter;
        self.send_counter += 1;
        let encrypted = encrypt(&self.send_key, counter, &[], plaintext);
        let mut packet = counter.to_le_bytes().to_vec();
        packet.extend_from_slice(&encrypted);
        packet
    }

    pub fn decrypt(&mut self, packet: &[u8]) -> Result<Vec<u8>> {
        if packet.len() < 8 + TAG_LEN {
            bail!("packet too short");
        }
        let counter = u64::from_le_bytes(packet[..8].try_into().expect("checked length"));
        if self.is_replay(counter) {
            bail!("replayed packet");
        }
        let plaintext = decrypt(&self.receive_key, counter, &[], &packet[8..])?;
        self.mark_received(counter);
        Ok(plaintext)
    }

    fn is_replay(&self, counter: u64) -> bool {
        if counter > self.replay_high_water {
            return false;
        }
        let distance = self.replay_high_water - counter;
        if distance >= REPLAY_WINDOW {
            return true;
        }
        let word = (distance / 64) as usize;
        let bit = distance % 64;
        self.replay_bitmap[word] & (1 << bit) != 0
    }

    fn mark_received(&mut self, counter: u64) {
        if counter > self.replay_high_water {
            let shift = counter - self.replay_high_water;
            if shift >= REPLAY_WINDOW {
                self.replay_bitmap = [0; 32];
            } else {
                self.shift_window(shift);
            }
            self.replay_high_water = counter;
            self.replay_bitmap[0] |= 1;
        } else {
            let distance = self.replay_high_water - counter;
            let word = (distance / 64) as usize;
            let bit = distance % 64;
            self.replay_bitmap[word] |= 1 << bit;
        }
    }

    fn shift_window(&mut self, count: u64) {
        let word_shift = (count / 64) as usize;
        let bit_shift = (count % 64) as u32;
        if word_shift > 0 {
            for i in (word_shift..32).rev() {
                self.replay_bitmap[i] = self.replay_bitmap[i - word_shift];
            }
            for slot in self.replay_bitmap.iter_mut().take(word_shift.min(32)) {
                *slot = 0;
            }
        }
        if bit_shift > 0 {
            for i in (1..32).rev() {
                self.replay_bitmap[i] = (self.replay_bitmap[i] << bit_shift)
                    | (self.replay_bitmap[i - 1] >> (64 - bit_shift));
            }
            self.replay_bitmap[0] <<= bit_shift;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::Value;

    const VECTORS: &str = include_str!("../../../protocol/tests/fixtures/noise_vectors.json");

    fn vectors() -> Value {
        serde_json::from_str(VECTORS).expect("fixture parses")
    }

    fn field_bytes(v: &Value, key: &str) -> Vec<u8> {
        hex::decode(v[key].as_str().unwrap_or_else(|| panic!("missing {key}"))).expect("valid hex")
    }

    fn secret(v: &Value, key: &str) -> StaticSecret {
        StaticSecret::from(<[u8; 32]>::try_from(field_bytes(v, key).as_slice()).unwrap())
    }

    #[test]
    fn replays_swift_golden_vectors_as_initiator() {
        let v = vectors();
        let (message1, state) = initiator_begin(
            &secret(&v, "initiatorStaticPrivate"),
            &PublicKey::from(
                <[u8; 32]>::try_from(field_bytes(&v, "responderStaticPublic").as_slice()).unwrap(),
            ),
            secret(&v, "initiatorEphemeralPrivate"),
            &field_bytes(&v, "initiatorHandshakePayload"),
        );
        assert_eq!(message1, field_bytes(&v, "message1"), "msg1 bytes diverge");

        let keys = initiator_finish(state, &field_bytes(&v, "message2")).unwrap();
        assert_eq!(keys.send_key.to_vec(), field_bytes(&v, "initiatorSendKey"));
        assert_eq!(
            keys.receive_key.to_vec(),
            field_bytes(&v, "initiatorReceiveKey")
        );
        assert_eq!(
            keys.handshake_hash.to_vec(),
            field_bytes(&v, "handshakeHash")
        );
    }

    #[test]
    fn replays_swift_golden_vectors_as_responder() {
        let v = vectors();
        let (message2, keys, learned_initiator) = responder_complete(
            &secret(&v, "responderStaticPrivate"),
            &field_bytes(&v, "message1"),
            secret(&v, "responderEphemeralPrivate"),
            &field_bytes(&v, "responderHandshakePayload"),
        )
        .unwrap();
        assert_eq!(message2, field_bytes(&v, "message2"), "msg2 bytes diverge");
        // Responder keys are the initiator's, reversed.
        assert_eq!(
            keys.send_key.to_vec(),
            field_bytes(&v, "initiatorReceiveKey")
        );
        assert_eq!(
            keys.receive_key.to_vec(),
            field_bytes(&v, "initiatorSendKey")
        );
        assert_eq!(
            learned_initiator.as_bytes().to_vec(),
            field_bytes(&v, "initiatorStaticPublic")
        );
    }

    #[test]
    fn transport_vectors_decrypt_and_encrypt_identically() {
        let v = vectors();
        let initiator_keys = TransportKeys {
            send_key: field_bytes(&v, "initiatorSendKey").try_into().unwrap(),
            receive_key: field_bytes(&v, "initiatorReceiveKey").try_into().unwrap(),
            handshake_hash: field_bytes(&v, "handshakeHash").try_into().unwrap(),
        };
        let mut initiator = NoiseSession::new(initiator_keys);
        let mut responder = NoiseSession::new(TransportKeys {
            send_key: field_bytes(&v, "initiatorReceiveKey").try_into().unwrap(),
            receive_key: field_bytes(&v, "initiatorSendKey").try_into().unwrap(),
            handshake_hash: field_bytes(&v, "handshakeHash").try_into().unwrap(),
        });

        // Encrypting the known plaintexts reproduces Swift's exact packets…
        assert_eq!(
            initiator.encrypt(b"pin-vector-i2r"),
            field_bytes(&v, "transportI2R_0")
        );
        assert_eq!(
            initiator.encrypt(b"pin-vector-i2r-again"),
            field_bytes(&v, "transportI2R_1")
        );
        assert_eq!(
            responder.encrypt(b"pin-vector-r2i"),
            field_bytes(&v, "transportR2I_0")
        );

        // …and Swift's packets decrypt on the Rust side.
        assert_eq!(
            responder
                .decrypt(&field_bytes(&v, "transportI2R_0"))
                .unwrap(),
            b"pin-vector-i2r"
        );
        assert_eq!(
            responder
                .decrypt(&field_bytes(&v, "transportI2R_1"))
                .unwrap(),
            b"pin-vector-i2r-again"
        );
        assert_eq!(
            initiator
                .decrypt(&field_bytes(&v, "transportR2I_0"))
                .unwrap(),
            b"pin-vector-r2i"
        );
    }

    #[test]
    fn replay_and_tamper_rejected() {
        let v = vectors();
        let mut responder = NoiseSession::new(TransportKeys {
            send_key: field_bytes(&v, "initiatorReceiveKey").try_into().unwrap(),
            receive_key: field_bytes(&v, "initiatorSendKey").try_into().unwrap(),
            handshake_hash: field_bytes(&v, "handshakeHash").try_into().unwrap(),
        });
        let packet = field_bytes(&v, "transportI2R_0");
        assert!(responder.decrypt(&packet).is_ok());
        assert!(responder.decrypt(&packet).is_err(), "replay must fail");

        let mut tampered = field_bytes(&v, "transportI2R_1");
        let last = tampered.len() - 1;
        tampered[last] ^= 0xff;
        assert!(responder.decrypt(&tampered).is_err(), "tamper must fail");
    }

    #[test]
    fn full_handshake_round_trip_with_random_keys() {
        let initiator_static = StaticSecret::from([7u8; 32]);
        let responder_static = StaticSecret::from([9u8; 32]);
        let (msg1, state) = initiator_begin(
            &initiator_static,
            &PublicKey::from(&responder_static),
            StaticSecret::from([13u8; 32]),
            &timestamp_payload(),
        );
        let (msg2, responder_keys, learned) = responder_complete(
            &responder_static,
            &msg1,
            StaticSecret::from([17u8; 32]),
            &timestamp_payload(),
        )
        .unwrap();
        assert_eq!(
            learned.as_bytes(),
            PublicKey::from(&initiator_static).as_bytes()
        );
        let initiator_keys = initiator_finish(state, &msg2).unwrap();

        let mut a = NoiseSession::new(initiator_keys);
        let mut b = NoiseSession::new(responder_keys);
        let packet = a.encrypt(b"hello over pin");
        assert_eq!(b.decrypt(&packet).unwrap(), b"hello over pin");
        let reply = b.encrypt(b"hello back");
        assert_eq!(a.decrypt(&reply).unwrap(), b"hello back");
    }
}
