# Protocol Specification

Language-neutral wire protocol for cross-platform TealeNet nodes.

## Overview

The TealeNet protocol defines how nodes discover each other, establish connections, and exchange inference requests across the network. It is designed for implementors building new clients -- whether a Rust-based `teale-node`, a third-party integration, or a completely independent implementation.

The protocol operates at two layers:

1. **Relay layer** -- WebSocket + JSON messages through a relay server for WAN discovery, signaling, and fallback data transport.
2. **Cluster layer** -- Length-prefixed JSON over persistent TCP connections for LAN communication, or inside relay sessions for WAN communication.

All messages are JSON-encoded. All cryptographic identities use Ed25519. End-to-end encryption uses the Noise protocol framework.

## Protocol Stack

```
+---------------------------------------------------+
|              Application (Inference)               |
+---------------------------------------------------+
|           Cluster Messages (JSON)                  |
|  hello, heartbeat, inferenceRequest, modelQuery    |
+---------------------------------------------------+
|         Noise Encryption (optional)                |
|     Noise_IK_25519_ChaChaPoly_BLAKE2s              |
+---------------------------------------------------+
|            Transport Layer                          |
|   LAN: length-prefixed TCP (Bonjour discovery)     |
|   WAN: relayData over WebSocket                    |
+---------------------------------------------------+
|          Relay Signaling (WAN only)                |
|   register, discover, offer/answer, relayOpen      |
+---------------------------------------------------+
|             WebSocket (TLS)                         |
|        wss://relay.teale.com/ws                     |
+---------------------------------------------------+
```

## Pages

- [Relay Wire Protocol](relay-wire-protocol.md) -- Connection lifecycle, HTTP endpoints, all relay message types with JSON schemas
- [Cluster Messages](cluster-messages.md) -- Messages exchanged inside relay sessions or over LAN TCP connections
- [Node Capabilities](node-capabilities.md) -- HardwareCapability schema, chip families, GPU backends, platforms
- [Ed25519 Identity](ed25519-identity.md) -- Key generation, node IDs, signature schemes, key persistence
- [Noise Encryption](noise-encryption.md) -- Noise_IK handshake, transport encryption, replay protection, session lifetime
- [PTN Certificates](ptn-certificates.md) -- Private TealeNet certificate authority, membership certificates, invite tokens
- [NAT Traversal](nat-traversal.md) -- STUN, NAT types, hole-punching, relay fallback, ICE candidates
- [Pricing Protocol](pricing-protocol.md) -- Token-based pricing, electricity floor, PTN fixed rates, WWTN reverse auction, WFQ scheduling

## Design Principles

1. **JSON everywhere.** All messages are JSON. No binary framing beyond length prefixes on TCP. This makes the protocol easy to implement in any language.
2. **Ed25519 identity.** Every node has a single Ed25519 keypair. The public key is the node ID. No usernames, no accounts, no central registry.
3. **Encryption is optional.** Noise encryption is negotiated per-session. Nodes without encryption support fall back to plaintext. This allows incremental adoption.
4. **Relay is temporary.** The relay server is a rendezvous point, not a permanent intermediary. Nodes should attempt direct connections first and fall back to relay only when NAT prevents it.
5. **OpenAI-compatible.** Inference requests and responses use the OpenAI chat completions format, making Teale a drop-in replacement for existing tools.
