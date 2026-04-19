# Ed25519 Identity

How nodes generate, store, and use cryptographic identities.

## Key Type

TealeNet uses **Ed25519** (Curve25519.Signing in Apple CryptoKit) for node identity. Every node has exactly one Ed25519 keypair.

- **Private key:** 32 bytes (raw scalar)
- **Public key:** 32 bytes (compressed point)
- **Node ID:** Hex-encoded public key (64 hex characters)

The node ID and public key are the same value -- the hex-encoded 32-byte Ed25519 signing public key.

## Key Generation

Generate a new Ed25519 keypair:

```swift
import CryptoKit

let privateKey = Curve25519.Signing.PrivateKey()
let publicKey = privateKey.publicKey
let nodeID = publicKey.rawRepresentation.map { String(format: "%02x", $0) }.joined()
// nodeID is 64 hex chars, e.g. "a1b2c3d4e5f6..."
```

In other languages, use any Ed25519 implementation (libsodium, ring, tweetnacl, etc.).

## Key Persistence

The raw 32-byte private key is stored in a file with `0600` permissions (owner read/write only).

| Platform | Path |
|----------|------|
| macOS / iOS | `~/Library/Application Support/Teale/wan-identity.key` |
| Linux | `~/.local/share/teale/wan-identity.key` |
| Windows | `%APPDATA%\Teale\wan-identity.key` |
| Android | App-private directory |

The file contains exactly 32 bytes -- the raw private key with no encoding or wrapper.

## Registration Signature

When registering with the relay, the node proves ownership of its Ed25519 keypair by signing the node ID string.

```
signature = Ed25519.sign(UTF8_bytes(nodeID))
```

**Important:** The input to the signature function is the hex-encoded public key string (64 ASCII characters) encoded as UTF-8 bytes, not the raw 32-byte public key. This means the signature is over 64 bytes of hex characters, not 32 bytes of key material.

Example in pseudocode:

```
private_key = load_key("wan-identity.key")       // 32 bytes
public_key = derive_public_key(private_key)       // 32 bytes
node_id = hex_encode(public_key)                  // "a1b2c3..." (64 chars)
signature = ed25519_sign(private_key, node_id)    // sign the string
hex_signature = hex_encode(signature)             // 128 hex chars
```

## Offer/Answer Signature

When sending `offer` or `answer` messages for connection signaling, the signature covers a concatenation of the session participants and session ID.

```
signature = Ed25519.sign(UTF8_bytes("{fromNodeID}:{toNodeID}:{sessionID}"))
```

Example input string:

```
a1b2c3...:d4e5f6...:550e8400-e29b-41d4-a716-446655440000
```

## Key Agreement Derivation

For the [Noise protocol handshake](noise-encryption.md), a Curve25519 key agreement keypair is derived from the same seed as the Ed25519 signing keypair. In Apple CryptoKit, the same 32-byte private key seed can initialize both:

- `Curve25519.Signing.PrivateKey(rawRepresentation: seed)` -- for signing
- `Curve25519.KeyAgreement.PrivateKey(rawRepresentation: seed)` -- for Noise DH

The key agreement public key is advertised as `wgPublicKey` in registration and discovery messages. Nodes that set `wgPublicKey` to a non-null value indicate support for Noise encryption.

## Security Considerations

1. **Key file permissions:** Always set `0600` on the key file. The raw private key provides full control of the node identity.
2. **No key derivation:** The private key is stored as raw bytes, not derived from a password or mnemonic. Back it up accordingly.
3. **Single identity:** Each node has one identity. Running multiple nodes requires separate key files.
4. **Key rotation:** Not currently supported at the protocol level. Changing keys means appearing as a new node to the network.
