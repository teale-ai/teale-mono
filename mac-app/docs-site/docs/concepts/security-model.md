# Security Model

Teale uses end-to-end encryption for all network communication, Ed25519 identities for every node, and stores nothing centrally. No server --- including the relay --- can read your prompts or completions.

## Node identity

Every Teale node generates an Ed25519 keypair on first launch. The keypair is stored in the system Keychain (macOS) or Secure Enclave (iOS) and never leaves the device.

- **Public key:** 32 bytes, represented as a 64-character hex string. This is the node's unique ID across the network.
- **Private key:** 32 bytes, used for signing messages and performing Noise handshakes. Never transmitted.

The node ID is deterministic and persistent. Reinstalling the app with the same Keychain entry preserves the identity.

## WAN encryption (Noise protocol)

All WAN traffic between nodes is encrypted using the Noise framework:

```
Noise_IK_25519_ChaChaPoly_BLAKE2s
```

This means:

- **IK pattern:** The initiator knows the responder's static key in advance (from relay discovery). One round-trip handshake.
- **25519:** Curve25519 for Diffie-Hellman key exchange.
- **ChaChaPoly:** ChaCha20-Poly1305 AEAD for symmetric encryption.
- **BLAKE2s:** BLAKE2s for hashing.

### Handshake

```
Initiator                         Responder
    |                                  |
    |-- 0x01 + encrypted static key -->|
    |                                  |
    |<-- 0x02 + encrypted response ----|
    |                                  |
    |== Session established ===========|
    |   (ChaCha20-Poly1305 both dirs)  |
```

1. The initiator sends a message prefixed with `0x01`, containing its encrypted static public key and an ephemeral key exchange.
2. The responder replies with `0x02`, completing the Diffie-Hellman exchange and confirming its identity.
3. Both sides derive independent send and receive session keys (32 bytes each).

After the handshake, all data is encrypted with ChaCha20-Poly1305 using the derived session keys.

### Session encryption

- **AEAD:** Every message is authenticated. Tampered data is rejected immediately --- the decryption fails, and the message is dropped.
- **Nonces:** Each direction maintains an incrementing 64-bit nonce. Replayed messages are rejected because the nonce will not match the expected sequence.
- **Forward secrecy:** Ephemeral keys are used during the handshake and discarded. Compromising a node's long-term key does not decrypt past sessions.

## LAN encryption

LAN connections within a cluster use TCP with the custom NWProtocolFramer. LAN traffic is not encrypted by default because it stays on the local network. When security is needed on LAN, the optional passcode authentication prevents unauthorized nodes from joining the cluster.

For sensitive LAN deployments, using a PTN with certificate-based membership provides authentication without needing encryption (since the traffic never leaves the local network).

## Message signing

Agent-to-agent messages (AgentKit) are signed with the sender's Ed25519 private key. The recipient verifies the signature against the sender's known public key. This ensures:

- **Authentication:** The message came from who it claims.
- **Integrity:** The message was not modified in transit.
- **Non-repudiation:** The sender cannot deny sending the message.

## Group chat encryption

Group conversations use per-group symmetric keys for encryption:

- **GroupCrypto:** Encrypts and decrypts messages using a per-group symmetric key.
- **GroupKeyManager:** Manages the lifecycle of group keys (creation, rotation, revocation).
- **GroupKeyDistributor:** Distributes group keys to members using their Ed25519 public keys.

When a new member joins a group, the key is encrypted to their public key and delivered. When a member leaves, the group key is rotated and re-distributed to remaining members. See [Group Chat](group-chat.md) for the full protocol.

## PTN certificates

Private TealeNet membership is controlled by CA-signed Ed25519 certificates:

- Certificates are signed over canonical (sorted-keys) JSON, ensuring deterministic verification.
- Any node can verify a certificate against the CA public key without contacting the CA.
- Certificates carry roles (admin, provider, consumer) that restrict what the member can do.
- Certificates can have expiry timestamps. Expired certificates are rejected.

See [Private TealeNet](private-tealenet.md) for the full certificate lifecycle.

## Anonymous mode

Teale works without an account. In anonymous mode:

- The node still generates an Ed25519 keypair for network identity.
- A local wallet tracks credits without any server-side state.
- No personal information is collected or stored anywhere.
- The node can participate in inference (both serving and consuming) using only its cryptographic identity.

Signing in (via Sign in with Apple or Phone OTP) enables device management and cross-device features but is never required.

## What Teale does not store centrally

| Data | Where it lives |
|------|---------------|
| Conversations | On-device only |
| Private keys | System Keychain / Secure Enclave |
| Credit ledger | On-device JSON file |
| Model weights | On-device cache |
| Group chat keys | On-device, distributed P2P |
| PTN certificates | On-device, verified against CA public key |

The relay sees encrypted blobs and connection metadata (IP addresses, node IDs). It cannot decrypt any payload.

## Threat model summary

| Threat | Mitigation |
|--------|-----------|
| Relay operator reads prompts | E2E encryption (Noise protocol). Relay sees only encrypted bytes. |
| Man-in-the-middle on WAN | Noise IK pattern authenticates both parties via static keys. |
| Replay attack | Incrementing nonces per session direction. |
| Tampered messages | AEAD (ChaCha20-Poly1305) rejects any modified ciphertext. |
| Compromised long-term key | Forward secrecy via ephemeral DH. Past sessions remain secure. |
| Unauthorized PTN access | CA-signed certificates with role-based access control. |
| Lost device | Keys are device-local. Revoking the device's PTN certificate cuts access. |

## Related pages

- [Networking](networking.md) --- transport protocols and relay architecture
- [Private TealeNet](private-tealenet.md) --- certificate-based access control
- [Group Chat](group-chat.md) --- per-group symmetric encryption
