# Networking

Teale's networking stack has three layers: LAN for local peers, WAN for internet peers, and a relay for discovery when direct connections are not possible.

## LAN layer

The LAN layer connects Macs and iPhones on the same local network with zero configuration.

### Discovery

Teale uses Bonjour (mDNS/DNS-SD) to advertise and discover peers on the local network. Each node publishes a service record containing its node ID, loaded models, and hardware capabilities. Discovery is automatic and requires no manual setup.

### Transport

LAN connections use Apple's Network.framework (`NWConnection`) over TCP with a custom `NWProtocolFramer`. The framer implements length-prefixed JSON messaging:

```
[4 bytes: payload length (big-endian UInt32)] [JSON payload]
```

All inter-node messages follow this format. Messages are plain JSON objects with a `type` field and a `payload` field. This makes the protocol easy to debug with standard network tools.

### Authentication

LAN clusters support optional passcode authentication. When enabled, peers must present the correct passcode during the handshake before joining the cluster. Without a passcode, any device on the local network can join.

### Health monitoring

Each peer connection maintains a heartbeat at configurable intervals:

- **5 seconds** --- aggressive, for latency-sensitive setups
- **15 seconds** --- default, balances responsiveness with efficiency
- **30 seconds** --- conservative, for stable long-running clusters

If a peer misses three consecutive heartbeats, it is marked as disconnected and removed from the routing pool.

### Model sharing

Nodes can share downloaded models with LAN peers using chunked file transfer. Models are split into 1MB chunks and streamed over the persistent TCP connection, avoiding redundant downloads from HuggingFace Hub.

## WAN layer

The WAN layer connects nodes across the internet using QUIC for direct peer-to-peer communication and WebSocket for relay signaling.

### Identity

Every node generates an Ed25519 keypair on first launch, stored in the system Keychain. The public key (64 hex characters) serves as the node's unique identifier across the network. This identity is used for encryption handshakes, message signing, and credit attribution.

### NAT traversal

Before establishing a direct connection, Teale uses STUN to determine the node's NAT type and public endpoint:

1. **Full cone NAT** --- Direct QUIC connection succeeds without hole-punching.
2. **Address-restricted or port-restricted NAT** --- Coordinated hole-punching via the relay, then direct QUIC.
3. **Symmetric NAT** --- Direct connection not possible. Traffic routes through the relay.

### Direct connections (QUIC)

When NAT permits, nodes establish direct QUIC connections using Apple's Network.framework. QUIC provides:

- Multiplexed streams over a single connection
- Built-in congestion control
- 0-RTT resumption for repeat connections
- TLS 1.3 as part of the protocol

### Relay signaling

Nodes that cannot connect directly use the relay for signaling (exchanging connection metadata) and, when necessary, for relayed data transfer.

The relay protocol uses WebSocket messages with JSON payloads:

| Message | Direction | Purpose |
|---------|-----------|---------|
| `register` | Node to relay | Register with node ID and capabilities |
| `discover` | Node to relay | Request list of available peers |
| `peers` | Relay to node | Response with peer list and capabilities |
| `signal` | Node to relay | Forward signaling data to a specific peer |
| `relayData` | Node to relay | Send data through relay when direct fails |

### Encryption

All WAN traffic is end-to-end encrypted using the Noise protocol. See [Security Model](security-model.md) for the full cryptographic specification.

## Relay

The relay is a single rendezvous point at `wss://relay.teale.com/ws`. It serves four functions:

1. **Registration** --- Nodes register their ID, capabilities, and loaded models.
2. **Discovery** --- Nodes query for peers that have specific models or capabilities.
3. **Signaling** --- Nodes exchange STUN results and connection metadata to establish direct QUIC connections.
4. **Relayed data** --- When direct P2P fails (symmetric NAT), the relay forwards encrypted data between nodes.

### What the relay cannot do

The relay is not a central server. It cannot:

- Read prompts or completions (all data is E2E encrypted)
- Store messages (it is stateless, messages are forwarded in real-time)
- Authenticate users (identity is Ed25519 keypairs, verified peer-to-peer)
- Control the network (nodes can communicate directly without it)

### Infrastructure

The relay currently runs as a single Bun (TypeScript) server on Fly.io, costing $3--4/month. It is designed to become less important as the network grows --- more direct connections mean less relay traffic. See [docs/relay-scaling-roadmap.md](https://github.com/taylorhou/teale-mac-app/blob/main/docs/relay-scaling-roadmap.md) for the scaling plan.

### Relay importance over time

```
Relay importance
  ^
  |  *
  |   *
  |    *
  |      *
  |         *
  |             *
  |                  *
  |                        *
  +------------------------------> Network size
  Small                    Large
```

As the network grows, nodes are more likely to find peers they can reach directly. The relay's role shrinks from "essential for every connection" to "fallback for the hardest NAT scenarios."

## Related pages

- [How Teale Works](how-teale-works.md) --- architecture overview
- [Security Model](security-model.md) --- E2E encryption and identity
- [Private TealeNet](private-tealenet.md) --- private subnets with certificate-based membership
