# Noise Encryption

End-to-end encryption for peer connections using the Noise protocol framework.

## Overview

TealeNet uses the Noise protocol framework for optional end-to-end encryption between peers. Encryption is negotiated per-session. Peers that do not support Noise fall back to plaintext communication.

**Pattern:** `Noise_IK_25519_ChaChaPoly_BLAKE2s`

| Component | Choice | Description |
|-----------|--------|-------------|
| Pattern | IK | Initiator knows responder's static key |
| DH | 25519 | Curve25519 key agreement |
| Cipher | ChaChaPoly | ChaCha20-Poly1305 AEAD |
| Hash | BLAKE2s | BLAKE2s-256 |

## When Encryption is Used

Encryption is optional. It is activated when **both** peers have a non-null `wgPublicKey` in their registration. The `wgPublicKey` is a Curve25519 key agreement public key derived from the same seed as the Ed25519 signing key (see [Ed25519 Identity](ed25519-identity.md)).

Without encryption, `relayData.data` contains raw JSON-encoded ClusterMessages (base64-encoded).

## Handshake

The IK pattern assumes the initiator already knows the responder's static public key (obtained from discovery).

### Pattern

```
IK:
  <- s                          (pre-message: responder's static key known)
  ...
  -> e, es, s, ss              (initiator sends msg1)
  <- e, ee, se                 (responder sends msg2)
```

### Message 1 (Initiator to Responder)

The initiator sends a message prefixed with `0x01`:

```
[0x01] [ephemeral_pub: 32B] [encrypted_static_pub: 48B] [encrypted_payload: variable]
```

DH operations in order:
1. **es** -- DH(initiator ephemeral, responder static)
2. **ss** -- DH(initiator static, responder static)

The initiator's static public key is encrypted under the key derived from `es`. The payload (a 12-byte timestamp for replay protection) is encrypted under the key derived from `ss`.

### Message 2 (Responder to Initiator)

The responder replies with a message prefixed with `0x02`:

```
[0x02] [ephemeral_pub: 32B] [encrypted_payload: variable]
```

DH operations in order:
1. **ee** -- DH(responder ephemeral, initiator ephemeral)
2. **se** -- DH(responder static, initiator ephemeral)

### Wire Format

| Byte | Description |
|------|-------------|
| 0 | Message type: `0x01` (msg1) or `0x02` (msg2) |
| 1-32 | Ephemeral public key (32 bytes) |
| 33+ | Encrypted data (ciphertext + 16-byte Poly1305 tag per block) |

## Transport Keys

After the handshake completes, both sides derive two 32-byte symmetric keys via HKDF-BLAKE2s:

- **Send key** (initiator's `output[0]`, responder's `output[1]`)
- **Receive key** (initiator's `output[1]`, responder's `output[0]`)

Keys are reversed for the responder so that each side's send key matches the other's receive key.

## Transport Encryption

After handshake, all messages are encrypted with ChaCha20-Poly1305:

```
[nonce: 8B little-endian] [ciphertext] [tag: 16B]
```

**Nonce construction:** The Noise spec uses a 12-byte nonce: 4 zero bytes followed by an 8-byte little-endian counter. The counter increments with each message sent.

**No additional data:** Transport messages use an empty AD (additional data) field.

## Replay Protection

The transport layer implements a sliding-window anti-replay mechanism:

1. Each encrypted message includes an 8-byte little-endian nonce counter prepended to the ciphertext.
2. The receiver maintains a bitmap of the 2048 most recently received nonces.
3. Nonces older than the window are rejected.
4. Duplicate nonces within the window are rejected.
5. Only nonces that decrypt successfully are marked as received.

## Channel Binding

The handshake produces a **handshake hash** (`h`) that both sides can compare for channel binding. If the hashes do not match, the handshake was tampered with and the session must be discarded.

## Session Lifetime

Sessions have a configurable maximum lifetime (default: **24 hours**). After expiry, a new handshake must be performed.

The nonce counter is `UInt64`, so nonce exhaustion is not a practical concern within the session lifetime.

## Cryptographic Primitives

### BLAKE2s

Used for hashing and key derivation. Output size: 32 bytes. Block size: 64 bytes.

### HMAC-BLAKE2s

```
HMAC(key, data) = BLAKE2s((key XOR opad) || BLAKE2s((key XOR ipad) || data))
```

### HKDF-BLAKE2s

Derives 2 output keys from a chaining key and input key material:

```
tempKey = HMAC-BLAKE2s(chainingKey, inputKeyMaterial)
output1 = HMAC-BLAKE2s(tempKey, 0x01)
output2 = HMAC-BLAKE2s(tempKey, output1 || 0x02)
```

### ChaCha20-Poly1305

AEAD cipher. Key: 32 bytes. Nonce: 12 bytes (4 zero + 8 counter). Tag: 16 bytes.

## Plaintext Fallback

When either peer does not advertise a `wgPublicKey`, or when the handshake fails, communication falls back to plaintext. In plaintext mode, `relayData.data` contains unencrypted JSON-encoded ClusterMessages, base64-encoded.

Implementations should log a warning when falling back to plaintext, as the connection is not confidential.
