# PIN data-plane wire protocol (Noise transport)

Reference for the cross-platform Noise transport used by Private Inference
Networks. The Swift implementation (`mac-app/Sources/WANKit/`) is the deployed
ground truth; the Rust implementation (`node/src/pin/`) must match it
byte-for-byte. Golden vectors: `protocol/tests/fixtures/noise_vectors.json`
(regenerate with `swift test --filter NoiseVectorDump` in `mac-app/`).

## Handshake

`Noise_IK_25519_ChaChaPoly_BLAKE2s` — with two deliberate deviations from the
Noise spec that are now wire law:

1. **DH output is not raw X25519.** Every DH result is passed through
   HKDF-SHA256 (salt empty, info empty, 32-byte output) before use, because
   CryptoKit's `SharedSecret` cannot expose raw bytes. Rust must apply the
   same wrapper (`hkdf::Hkdf::<Sha256>::new(None, &raw).expand(&[], 32)`).
2. **msg2's `se` token is a repeat of `es`.** Both sides mix
   `DH(initiator_ephemeral, responder_static)` again, instead of standard
   IK's `DH(initiator_static, responder_ephemeral)`. Both deployed sides
   agree — do NOT "fix" one side alone; interop breaks.

Message layout (payloads are 12-byte timestamps in production; content is
opaque and discarded, only replay freshness matters):

```
msg1 (initiator → responder), 108 bytes:
  [32B initiator ephemeral pub][32+16B AEAD(initiator static pub)][12+16B AEAD(payload)]
msg2 (responder → initiator), 60 bytes:
  [32B responder ephemeral pub][12+16B AEAD(payload)]
```

- Symmetric init: `h = ck = "Noise_IK_25519_ChaChaPoly_BLAKE2s"` zero-padded
  to 32 bytes (name is 33 bytes > 32 → actually hashed; see code — the name
  length decides). Pre-message mixes the responder static pubkey into `h`.
- Every handshake AEAD uses nonce 0 (each encryption has a fresh key).
- HKDF = Noise-style, HMAC-BLAKE2s-256 (block size 64), 2 outputs.
- Transport split: `HKDF(ck, empty)` → initiator send = out[0], receive =
  out[1]; reversed on the responder.
- AEAD nonce layout: 12 bytes = 4 zero bytes ++ 8-byte **little-endian**
  counter.

## Transport session

Packet = `[8-byte LE counter][ciphertext][16-byte Poly1305 tag]`, AD empty.
Independent counters per direction starting at 0. Receiver enforces a
2048-bit sliding anti-replay window. Sessions expire after 24 h (rekey by
re-handshaking).

## UDP packet framing (outermost layer)

First byte is the packet type; remainder as below:

| Type | Meaning              | Body |
|------|----------------------|------|
| 0x01 | Handshake msg1       | raw msg1 |
| 0x02 | Handshake msg2       | raw msg2 |
| 0x03 | Keepalive            | empty (sent after 20 s send-idle) |
| 0x04 | Transport data       | one session packet; plaintext = `[4B BE length][JSON ClusterMessage]` |
| 0x05 | Transport fragment   | one session packet; plaintext = `[4B BE fragmentID][2B BE index][2B BE total][chunk]` |

Messages whose length-prefixed JSON exceeds **1100 bytes** are split into
≤1100-byte chunks, each individually encrypted as an 0x05 packet with a shared
random fragmentID. Receiver reassembles by (fragmentID, index) and decodes the
length-prefixed JSON once all `total` chunks arrive. Stale partial buffers are
pruned after ~10 s.

## Peer authentication (PIN layer)

The Noise static key proves transport identity. The PIN layer maps it to
membership: after the handshake, the peer's static pubkey must equal the
`wgPublicKey` derived from a device listed as active (not disabled) in the
current signed netmap for the network the session claims to serve. Sessions
from unlisted/disabled/removed devices are closed immediately.
