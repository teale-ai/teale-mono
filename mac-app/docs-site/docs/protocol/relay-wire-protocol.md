# Relay Wire Protocol

Complete specification for the TealeNet relay server WebSocket protocol.

## Connection

- **Endpoint:** `wss://relay.teale.com/ws?node={nodeID}`
- **Transport:** WebSocket (text or binary frames, JSON-encoded)
- **Keepalive:** Send WebSocket ping frames every 25 seconds
- **Reconnect:** Exponential backoff starting at 1 second, maximum 60 seconds

The `nodeID` query parameter is the hex-encoded Ed25519 public key (64 hex characters). See [Ed25519 Identity](ed25519-identity.md) for details.

## HTTP Endpoints

### `GET /health`

Returns server health status.

```json
{"ok": true, "peers": 42}
```

### `GET /peers`

Returns list of connected peers (truncated node IDs for privacy).

### `GET /metrics`

Returns server metrics.

```json
{
  "peers": 42,
  "messagesPerMinute": 156,
  "relaySessionsActive": 3,
  "uptimeSeconds": 86400,
  "totalMessages": 12345
}
```

### `GET /ws`

WebSocket upgrade endpoint. Requires the `node` query parameter.

## Date Encoding

All `Date` fields use **Apple's reference date** encoding: seconds since `2001-01-01T00:00:00Z` as a floating-point number. This is Swift's `.deferredToDate` encoding strategy.

```
referenceDate = 2001-01-01T00:00:00Z
encodedValue = (unix_timestamp_ms / 1000) - 978307200
```

The constant `978307200` is the number of seconds between the Unix epoch (1970-01-01) and Apple's reference date (2001-01-01).

**Example:** Unix timestamp `1713100000` (2024-04-14) encodes as `734792800.0`.

## Message Format

Each WebSocket message is a JSON object with exactly **one key** identifying the message type. The key's value is the payload object.

```json
{"register": { ...payload... }}
{"relayData": { ...payload... }}
```

This design makes message routing trivial: read the single key, dispatch to the appropriate handler.

---

## Message Types

### `register`

Register this node with the relay server. Must be the first message sent after connecting.

```json
{
  "register": {
    "nodeID": "a1b2c3...64-hex-chars",
    "publicKey": "a1b2c3...64-hex-chars",
    "wgPublicKey": "d4e5f6...64-hex-chars",
    "displayName": "My Linux Server",
    "capabilities": {
      "hardware": { ...HardwareCapability... },
      "loadedModels": ["mlx-community/Qwen3-8B-4bit"],
      "maxModelSizeGB": 20.0,
      "isAvailable": true,
      "ptnIDs": []
    },
    "signature": "hex-encoded-ed25519-signature"
  }
}
```

| Field | Type | Description |
|-------|------|-------------|
| `nodeID` | string | Hex-encoded Ed25519 public key (64 hex chars) |
| `publicKey` | string | Same as `nodeID` (Ed25519 signing public key) |
| `wgPublicKey` | string or null | Hex-encoded Curve25519 key agreement public key (for Noise handshake) |
| `displayName` | string | Human-readable node name |
| `capabilities` | object | [NodeCapabilities](node-capabilities.md) schema |
| `signature` | string | Hex-encoded Ed25519 signature of the `nodeID` string as UTF-8 bytes |

**Signature:** `Ed25519.sign(UTF8_bytes(nodeID))` -- sign the hex-encoded public key string (not the raw bytes, but the hex string itself) encoded as UTF-8.

**Note:** `publicKey` and `nodeID` are identical values. Both are the hex-encoded 32-byte Ed25519 signing public key.

### `registerAck`

Server confirms registration.

```json
{
  "registerAck": {
    "nodeID": "a1b2c3...",
    "registeredAt": 798134400.0,
    "ttlSeconds": 300
  }
}
```

| Field | Type | Description |
|-------|------|-------------|
| `nodeID` | string | Confirmed node ID |
| `registeredAt` | number | Apple reference date timestamp |
| `ttlSeconds` | number | Registration TTL; re-register before expiry |

### `discover`

Request a filtered list of peers from the relay.

```json
{
  "discover": {
    "requestingNodeID": "a1b2c3...",
    "filter": {
      "modelID": "mlx-community/Qwen3-8B-4bit",
      "minRAMGB": 16.0,
      "minTier": 2,
      "maxPeers": 50
    }
  }
}
```

| Field | Type | Description |
|-------|------|-------------|
| `requestingNodeID` | string | The requesting node's ID |
| `filter` | object or null | Optional filter criteria |
| `filter.modelID` | string | Only peers with this model in `capabilities.loadedModels` |
| `filter.minRAMGB` | number | Only peers with `capabilities.hardware.totalRAMGB >= value` |
| `filter.minTier` | number | Only peers with `capabilities.hardware.tier <= value` (tier 1 is best) |
| `filter.maxPeers` | number | Cap response to this many peers (default 50). If more match, a random sample is returned. |

All filter fields are optional. The `filter` object itself can be null or omitted.

**Rate limit:** Maximum 1 discover request per 10 seconds per node. Exceeding this returns a `rate_limited` error.

### `discoverResponse`

Server returns a filtered list of connected peers (excluding the requester), capped at `maxPeers`.

```json
{
  "discoverResponse": {
    "peers": [
      {
        "nodeID": "d4e5f6...",
        "publicKey": "d4e5f6...",
        "wgPublicKey": "a7b8c9...",
        "displayName": "Mac Studio",
        "capabilities": { ...NodeCapabilities... },
        "lastSeen": 798134400.0,
        "natType": "fullCone",
        "endpoints": []
      }
    ]
  }
}
```

| Field | Type | Description |
|-------|------|-------------|
| `peers` | array | List of matching peer objects |
| `peers[].nodeID` | string | Peer's node ID |
| `peers[].publicKey` | string | Peer's Ed25519 public key (same as nodeID) |
| `peers[].wgPublicKey` | string or null | Peer's Curve25519 key agreement public key |
| `peers[].displayName` | string | Peer's display name |
| `peers[].capabilities` | object | Peer's [NodeCapabilities](node-capabilities.md) |
| `peers[].lastSeen` | number | Apple reference date of last activity |
| `peers[].natType` | string | Detected NAT type (`fullCone`, `restrictedCone`, `portRestricted`, `symmetric`, `unknown`) |
| `peers[].endpoints` | array | Known network endpoints |

### `offer`

Initiate a direct connection to a peer (NAT traversal signaling).

```json
{
  "offer": {
    "fromNodeID": "a1b2c3...",
    "toNodeID": "d4e5f6...",
    "sessionID": "550e8400-e29b-41d4-a716-446655440000",
    "connectionInfo": {
      "publicIP": "1.2.3.4",
      "publicPort": 51820,
      "localIP": "192.168.1.10",
      "localPort": 51820,
      "natType": "fullCone",
      "wgPublicKey": "hex..."
    },
    "signature": "hex-encoded-ed25519-signature"
  }
}
```

**Signature:** `Ed25519.sign(UTF8_bytes("{fromNodeID}:{toNodeID}:{sessionID}"))`.

### `answer`

Reply to an offer with the responder's connection information. Same schema as `offer`.

```json
{
  "answer": {
    "fromNodeID": "d4e5f6...",
    "toNodeID": "a1b2c3...",
    "sessionID": "550e8400-e29b-41d4-a716-446655440000",
    "connectionInfo": {
      "publicIP": "5.6.7.8",
      "publicPort": 51820,
      "localIP": "192.168.2.20",
      "localPort": 51820,
      "natType": "restrictedCone",
      "wgPublicKey": "hex..."
    },
    "signature": "hex-encoded-ed25519-signature"
  }
}
```

### `iceCandidate`

ICE candidate for NAT traversal.

```json
{
  "iceCandidate": {
    "fromNodeID": "a1b2c3...",
    "toNodeID": "d4e5f6...",
    "sessionID": "550e8400-...",
    "candidate": {
      "ip": "1.2.3.4",
      "port": 51820,
      "type": "host",
      "priority": 100
    }
  }
}
```

| Candidate Type | Description |
|---------------|-------------|
| `host` | Local network address |
| `serverReflexive` | Public address discovered via STUN |
| `relayed` | Address allocated by a relay/TURN server |

### `relayOpen`

Request a relayed session to a peer (when direct connection fails).

```json
{
  "relayOpen": {
    "fromNodeID": "a1b2c3...",
    "toNodeID": "d4e5f6...",
    "sessionID": "550e8400-..."
  }
}
```

The relay server forwards this to the target peer. If the target is not connected, a `peer_not_found` error is returned.

### `relayReady`

Accept a relayed session. Sent by the target peer in response to `relayOpen`.

```json
{
  "relayReady": {
    "fromNodeID": "d4e5f6...",
    "toNodeID": "a1b2c3...",
    "sessionID": "550e8400-..."
  }
}
```

### `relayData`

Send data through an established relay session. The `data` field contains base64-encoded bytes.

```json
{
  "relayData": {
    "fromNodeID": "a1b2c3...",
    "toNodeID": "d4e5f6...",
    "sessionID": "550e8400-...",
    "data": "eyJoZWxsbyI6ey4uLn19"
  }
}
```

The `data` payload is a JSON-encoded [ClusterMessage](cluster-messages.md). When Noise encryption is active, the data is encrypted first, then base64-encoded. Without encryption (plaintext fallback), it is raw JSON bytes base64-encoded.

### `relayClose`

Close a relayed session.

```json
{
  "relayClose": {
    "fromNodeID": "a1b2c3...",
    "toNodeID": "d4e5f6...",
    "sessionID": "550e8400-..."
  }
}
```

### `peerJoined` / `peerLeft` (deprecated)

Previously broadcast by the relay server when peers registered or disconnected. **Deprecated as of v1.1** -- the server no longer sends these messages. Clients should use poll-based discovery instead (periodic `discover` calls every 30 seconds).

```json
{
  "peerJoined": { "nodeID": "...", "displayName": "..." }
}
```

### `error`

Error response from the relay server.

```json
{
  "error": {
    "code": "peer_not_found",
    "message": "Peer abc... is not connected"
  }
}
```

Rate-limited errors include a `retryAfterSeconds` field:

```json
{
  "error": {
    "code": "rate_limited",
    "message": "Discover rate limited, retry after 8s",
    "retryAfterSeconds": 8
  }
}
```

## Error Codes

| Code | Description |
|------|-------------|
| `peer_not_found` | Target peer is not connected to the relay |
| `invalid_json` | Message could not be parsed as JSON |
| `invalid_message` | Empty or malformed message (no recognized message type key) |
| `invalid_register` | Missing required fields in register message |
| `rate_limited` | Too many requests; includes `retryAfterSeconds` field |
| `unsupported_message` | Unknown message type |

## Rate Limits

| Action | Limit |
|--------|-------|
| `discover` | 1 request per 10 seconds per node |

## NodeCapabilities Schema

See [Node Capabilities](node-capabilities.md) for the full schema.

```json
{
  "hardware": {
    "chipFamily": "m4Pro",
    "chipName": "Apple M4 Pro",
    "totalRAMGB": 48.0,
    "gpuCoreCount": 20,
    "memoryBandwidthGBs": 273.0,
    "tier": 2,
    "gpuBackend": "metal",
    "platform": "macOS",
    "gpuVRAMGB": null
  },
  "loadedModels": ["mlx-community/Qwen3-8B-4bit"],
  "maxModelSizeGB": 20.0,
  "isAvailable": true,
  "ptnIDs": []
}
```

## Supply Node Lifecycle

A minimal supply node implementation follows this sequence:

1. Generate or load an Ed25519 identity (see [Ed25519 Identity](ed25519-identity.md))
2. Connect WebSocket to `wss://relay.teale.com/ws?node={nodeID}`
3. Send `register` with capabilities and signature
4. Receive `registerAck`
5. Start inference backend (llama-server subprocess or equivalent)
6. Listen for incoming messages:
   - `relayOpen` -- reply with `relayReady`, create session
   - `relayData` -- decode [ClusterMessage](cluster-messages.md):
     - `hello` -- reply with `helloAck`
     - `heartbeat` -- reply with `heartbeatAck`
     - `inferenceRequest` -- proxy to inference backend, stream `inferenceChunk` back, then `inferenceComplete`
   - `relayClose` -- clean up session
7. Send WebSocket pings every 25 seconds
8. On disconnect: exponential backoff reconnect (1s initial, 60s max)
