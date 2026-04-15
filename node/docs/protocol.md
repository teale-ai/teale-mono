# TealeNet Relay Protocol Specification

Version 1.0 — Language-neutral wire protocol for cross-platform node agents.

## Overview

TealeNet uses a **relay server** as a rendezvous point. Nodes connect via WebSocket, register their identity and capabilities, discover peers, and exchange inference requests/responses through relayed sessions. All messages are JSON over WebSocket.

## Connection

- **Endpoint:** `wss://relay.teale.com/ws?node={nodeID}`
- **Transport:** WebSocket (text or binary frames, JSON-encoded)
- **Keepalive:** Send WebSocket ping frames every 25 seconds
- **Reconnect:** Exponential backoff starting at 1s, max 60s

## Date Encoding

All `Date` fields use **Apple's reference date** encoding: seconds since `2001-01-01T00:00:00Z` as a floating-point number. This is Swift's `.deferredToDate` strategy.

```
referenceDate = 2001-01-01T00:00:00Z
encodedValue = (unix_timestamp_ms / 1000) - 978307200
```

The relay server constant: `referenceDateSeconds = Date.parse("2001-01-01T00:00:00Z") / 1000` = 978307200.

## Message Format

Each message is a JSON object with exactly **one key** identifying the message type, whose value is the payload:

```json
{"register": { ...payload... }}
{"relayData": { ...payload... }}
```

## Relay Message Types

### `register`

Register this node with the relay server.

```json
{
  "register": {
    "nodeID": "hex-encoded-ed25519-public-key",
    "publicKey": "hex-encoded-ed25519-public-key",
    "wgPublicKey": "hex-encoded-curve25519-key-agreement-public-key",
    "displayName": "My Linux Server",
    "capabilities": { ...NodeCapabilities... },
    "signature": "hex-encoded-ed25519-signature-of-nodeID-utf8-bytes"
  }
}
```

**Signature:** `Ed25519.sign(UTF8_bytes(nodeID))` — sign the hex-encoded public key string as UTF-8 bytes.

**Note:** `publicKey` and `nodeID` are the same value (hex-encoded Ed25519 signing public key, 64 hex chars = 32 bytes).

### `registerAck`

Server confirms registration.

```json
{
  "registerAck": {
    "nodeID": "...",
    "registeredAt": 798134400.0,
    "ttlSeconds": 300
  }
}
```

`registeredAt` uses Apple reference date encoding.

### `discover`

Request peer list from relay.

```json
{
  "discover": {
    "requestingNodeID": "...",
    "filter": {
      "modelID": "optional-model-id",
      "minRAMGB": 16.0,
      "minTier": 2
    }
  }
}
```

`filter` is optional (can be null or omitted).

### `discoverResponse`

Server returns list of all connected peers (excluding requester).

```json
{
  "discoverResponse": {
    "peers": [
      {
        "nodeID": "...",
        "publicKey": "...",
        "wgPublicKey": "..." or null,
        "displayName": "...",
        "capabilities": { ...NodeCapabilities... },
        "lastSeen": 798134400.0,
        "natType": "unknown",
        "endpoints": []
      }
    ]
  }
}
```

### `offer` / `answer`

Direct connection signaling (for NAT traversal / WireGuard).

```json
{
  "offer": {
    "fromNodeID": "...",
    "toNodeID": "...",
    "sessionID": "uuid-string",
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

**Offer/Answer signature:** `Ed25519.sign(UTF8_bytes("{fromNodeID}:{toNodeID}:{sessionID}"))`.

### `iceCandidate`

ICE candidate for NAT traversal.

```json
{
  "iceCandidate": {
    "fromNodeID": "...",
    "toNodeID": "...",
    "sessionID": "...",
    "candidate": {
      "ip": "1.2.3.4",
      "port": 51820,
      "type": "host",
      "priority": 100
    }
  }
}
```

Candidate types: `host`, `serverReflexive`, `relayed`.

### `relayOpen`

Request a relayed session to a peer (when direct connection fails).

```json
{
  "relayOpen": {
    "fromNodeID": "...",
    "toNodeID": "...",
    "sessionID": "uuid-string"
  }
}
```

### `relayReady`

Accept a relayed session.

```json
{
  "relayReady": {
    "fromNodeID": "...",
    "toNodeID": "...",
    "sessionID": "..."
  }
}
```

### `relayData`

Send data through a relayed session. The `data` field contains base64-encoded bytes (Swift `Data` default encoding).

```json
{
  "relayData": {
    "fromNodeID": "...",
    "toNodeID": "...",
    "sessionID": "...",
    "data": "base64-encoded-bytes"
  }
}
```

The `data` payload is a **JSON-encoded `ClusterMessage`** (see below). When Noise encryption is active, the data is encrypted first, then base64-encoded. Without encryption (plaintext fallback), it's raw JSON bytes base64-encoded.

### `relayClose`

Close a relayed session.

```json
{
  "relayClose": {
    "fromNodeID": "...",
    "toNodeID": "...",
    "sessionID": "..."
  }
}
```

### `peerJoined` / `peerLeft`

Broadcast by relay server when peers register/disconnect.

```json
{
  "peerJoined": { "nodeID": "...", "displayName": "..." }
}
```

### `error`

Error from relay server.

```json
{
  "error": { "code": "peer_not_found", "message": "Peer abc... is not connected" }
}
```

## NodeCapabilities

```json
{
  "hardware": {
    "chipFamily": "nvidiaGPU",
    "chipName": "NVIDIA RTX 4090",
    "totalRAMGB": 32.0,
    "gpuCoreCount": 16384,
    "memoryBandwidthGBs": 1008.0,
    "tier": 1,
    "gpuBackend": "cuda",
    "platform": "linux",
    "gpuVRAMGB": 24.0
  },
  "loadedModels": ["Qwen/Qwen3-8B-GGUF"],
  "maxModelSizeGB": 20.0,
  "isAvailable": true,
  "ptnIDs": []
}
```

**chipFamily values:** `m1`, `m1Pro`, ... `m4Ultra`, `a14`...`a19Pro`, `nvidiaGPU`, `amdGPU`, `intelCPU`, `amdCPU`, `armGeneric`, `unknown`

**gpuBackend values:** `metal`, `cuda`, `rocm`, `vulkan`, `sycl`, `cpu` (optional field)

**platform values:** `macOS`, `iOS`, `linux`, `windows`, `android`, `freebsd` (optional field)

**tier values:** 1 (backbone), 2 (desktop), 3 (tablet), 4 (phone/leaf)

## Cluster Messages (inside relayData)

These are JSON-encoded and sent as the `data` payload inside `relayData` messages.

### Inference Flow (supply node must implement)

#### `inferenceRequest`

```json
{
  "inferenceRequest": {
    "requestID": "uuid-string",
    "request": {
      "model": "Qwen/Qwen3-8B-GGUF",
      "messages": [
        {"role": "system", "content": "You are helpful."},
        {"role": "user", "content": "Hello"}
      ],
      "temperature": 0.7,
      "top_p": 0.9,
      "max_tokens": 2048,
      "stream": true
    },
    "streaming": true
  }
}
```

The `request` field is an OpenAI-compatible `ChatCompletionRequest`.

#### `inferenceChunk`

Stream back one token/chunk:

```json
{
  "inferenceChunk": {
    "requestID": "uuid-string",
    "chunk": {
      "id": "chatcmpl-xxx",
      "object": "chat.completion.chunk",
      "created": 1713100000,
      "model": "Qwen/Qwen3-8B-GGUF",
      "choices": [
        {
          "index": 0,
          "delta": { "content": "Hello" },
          "finish_reason": null
        }
      ]
    }
  }
}
```

#### `inferenceComplete`

```json
{
  "inferenceComplete": {
    "requestID": "uuid-string"
  }
}
```

#### `inferenceError`

```json
{
  "inferenceError": {
    "requestID": "uuid-string",
    "errorMessage": "Model not loaded"
  }
}
```

### Handshake (hello/helloAck)

```json
{
  "hello": {
    "deviceInfo": {
      "id": "uuid",
      "name": "Linux Server",
      "hardware": { ...HardwareCapability... },
      "registeredAt": 798134400.0,
      "lastSeenAt": 798134400.0,
      "isCurrentDevice": true,
      "loadedModels": []
    },
    "protocolVersion": 1,
    "loadedModels": ["model-id"]
  }
}
```

### Heartbeat

```json
{
  "heartbeat": {
    "deviceID": "uuid",
    "timestamp": 798134400.0,
    "thermalLevel": "nominal",
    "throttleLevel": 100,
    "loadedModels": ["model-id"],
    "isGenerating": false,
    "queueDepth": 0
  }
}
```

`thermalLevel`: `nominal`, `fair`, `serious`, `critical`
`throttleLevel`: 0 (paused) to 100 (full)

## Ed25519 Identity

- **Key type:** Curve25519.Signing (Ed25519)
- **Node ID:** hex-encoded 32-byte public key (64 hex characters)
- **Persistence:** Raw 32-byte private key stored in a file (0600 permissions)
  - macOS/iOS: `~/Library/Application Support/Teale/wan-identity.key`
  - Linux: `~/.local/share/teale/wan-identity.key`
  - Windows: `%APPDATA%\Teale\wan-identity.key`
  - Android: app private directory

## Noise Protocol (E2E Encryption)

Optional — plaintext fallback is supported for legacy peers.

When both peers have `wgPublicKey` set, they perform a Noise handshake:

1. **Initiator** sends: `0x01` prefix byte + Noise handshake message 1
2. **Responder** replies: `0x02` prefix byte + Noise handshake message 2
3. After handshake: all `relayData` payloads are encrypted with the negotiated Noise session

The handshake uses Curve25519 KeyAgreement keys (derived from the same seed as the Ed25519 signing key).

Without encryption, `relayData.data` contains raw JSON-encoded ClusterMessages.

## Supply Node Lifecycle (Minimal Implementation)

1. Generate/load Ed25519 identity
2. Connect WebSocket to `wss://relay.teale.com/ws?node={nodeID}`
3. Send `register` with capabilities and signature
4. Receive `registerAck`
5. Start llama-server subprocess (or connect to existing one)
6. Listen for incoming messages:
   - `relayOpen` → reply `relayReady`, create session
   - `relayData` → decode ClusterMessage:
     - `hello` → reply `helloAck`
     - `heartbeat` → reply `heartbeatAck`
     - `inferenceRequest` → proxy to llama-server, stream `inferenceChunk` back, then `inferenceComplete`
   - `relayClose` → clean up session
7. Send WebSocket pings every 25s
8. On disconnect: exponential backoff reconnect
