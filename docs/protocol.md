# TealeNet Relay Protocol Specification

Language-neutral wire protocol for cross-platform node agents. This is the
single spec for the relay; it describes `relay/server.ts` as implemented.
Rust types live in `protocol/src/relay.rs` and `protocol/src/cluster.rs`;
Swift types in `mac-app/Sources/WANKit/RelayClient.swift`.

## Overview

TealeNet uses a **relay server** as a rendezvous point. Nodes connect via
WebSocket, register a signed identity and their capabilities, discover peers,
and exchange inference requests/responses through relayed sessions. All
messages are JSON text frames.

## Connection

- **Endpoint:** `wss://relay.teale.com/ws` (clients append `?node={nodeID}`;
  the relay ignores the query string)
- **Transport:** WebSocket, one JSON object per frame
- **Keepalive:** Send WebSocket ping frames every 25 seconds. Any message
  from a registered socket also refreshes that peer's `lastSeen`.
- **Reconnect:** Exponential backoff starting at 1s, max 60s

## HTTP Endpoints

| Path | Auth | Response |
|---|---|---|
| `GET /health` | none | `{ "ok": true, "peers": N, "enforceSignatures": bool, "stats": {...}, "eventlog": {...} }`. `stats` has delivery counters (`sent`, `dropped`, `backpressured`, `lastDropAt`, `lastDropTo`, `registerRejected`, `fromNodeIDOverwritten`). |
| `GET /peers` | admin token if configured | `{ "peers": [{ "nodeID": "<16 hex>...", "displayName", "wgPublicKey": "<16 hex>..." or null, "lastSeen" }] }` |
| `GET /events?since=&kind=&node=&limit=` | admin token if configured | Recent control-plane events (register, register_rejected, close, mass_close, peer_not_found, drop, backpressure, from_overwritten, stats, start), oldest first. Node IDs are truncated to 16 characters at every nesting level. `limit` defaults to 200, max 2000. |
| `GET /ws` | none | WebSocket upgrade |

Anything else returns `404`. When the relay runs with `RELAY_ADMIN_TOKEN`
set, `/peers` and `/events` require `Authorization: Bearer <token>` and
return `401` otherwise. There is no `/metrics` endpoint.

## Server configuration

| Env var | Default | Meaning |
|---|---|---|
| `PORT` | `8080` | Listen port |
| `RELAY_ENFORCE_SIGNATURES` | `true` | `false` turns register-signature failures into log-only events (escape hatch for a broken client rollout) |
| `RELAY_ADMIN_TOKEN` | unset | Bearer token for `/peers` and `/events` |
| `RELAY_LOG_DIR` | `/app/logs` | Directory of the JSONL event log |

## Date Encoding

All `Date` fields use **Apple's reference date** encoding: seconds since
`2001-01-01T00:00:00Z` as a floating-point number (Swift `.deferredToDate`).

```
referenceDate = 2001-01-01T00:00:00Z
encodedValue = (unix_timestamp_ms / 1000) - 978307200
```

## Message Format

Each message is a JSON object with exactly **one key** naming the message
type; its value is the payload:

```json
{"register": { ...payload... }}
{"relayData": { ...payload... }}
```

The relay also accepts Swift's synthesized wrapper `{"register": {"_0": {...}}}`
and unwraps `_0` before processing. Messages are processed strictly in order
per socket (a message sent right after `register` waits until the register
signature has been verified).

## Identity and the register signature

- **Key type:** Ed25519 (`Curve25519.Signing` in CryptoKit, `ed25519-dalek` in Rust)
- **nodeID:** lowercase hex of the 32-byte public key (64 characters)
- **publicKey:** the same value as `nodeID`
- **signature:** hex of `Ed25519.sign(UTF8_bytes(nodeID))` (64 bytes, 128 hex characters)

On every `register` the relay checks, before touching any existing session:

1. `nodeID` equals `publicKey` (case-insensitive) and decodes to 32 bytes;
2. `signature` decodes to 64 bytes and verifies over the UTF-8 bytes of
   `nodeID` **exactly as sent** with that public key.

If either check fails the relay replies `error` with code
`invalid_signature` and drops the register: an existing session for that
`nodeID` is **not** replaced or closed. With `RELAY_ENFORCE_SIGNATURES=false`
the failure is logged (`register_rejected` event) and the registration is
accepted anyway.

A heartbeat re-register on the same socket with the same, already verified
signature is not re-verified.

**Known limitation (replay):** the signed message is the static nodeID, so a
captured register payload can be replayed by anyone who obtained it. Register
payloads only travel over TLS to the relay and the relay never echoes
signatures, which limits exposure, but this is not a proof of possession per
connection. Follow-up: a challenge-response — the relay sends a random nonce
on connect (e.g. `{"challenge": {"nonce": "<hex>"}}`) and clients sign
`"teale-relay-register:" + nodeID + ":" + nonce`; keep accepting the static
signature behind a flag until all clients ship it.

**Sender identity:** for every forwarded message (`offer`, `answer`,
`iceCandidate`, `relay*`) the relay overwrites `fromNodeID` with the nodeID
registered on the sending socket. A socket that has not registered gets
`not_registered` (with enforcement off, its own `fromNodeID` is forwarded as
before).

## Relay Message Types

### `register` (client → relay)

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

Required: `nodeID`, `publicKey`, `signature` (strings) and `capabilities`
(object). Optional: `wgPublicKey` (string), `displayName` (string, default `""`).

Registering a nodeID that is already connected on another socket replaces
that session: the old socket is closed with code `1012` ("Replaced by newer
session"). Re-registering on the same socket refreshes the stored
capabilities (heartbeat) and does not broadcast `peerJoined`.

### `registerAck` (relay → client)

```json
{ "registerAck": { "nodeID": "...", "registeredAt": 798134400.0, "ttlSeconds": 300 } }
```

### `discover` (client → relay)

```json
{
  "discover": {
    "requestingNodeID": "...",
    "filter": { "modelID": "model-id", "minRAMGB": 16.0, "minTier": 2, "maxPeers": 50 }
  }
}
```

The payload, `requestingNodeID` and `filter` and every filter field are
optional (`null` is treated as absent). Server-side filtering:

- `modelID` — only peers whose `capabilities.loadedModels` contains it
- `minRAMGB` — only peers with `capabilities.hardware.totalRAMGB >= value`
- `minTier` — only peers with `1 <= capabilities.hardware.tier <= value` (tier 1 is the most capable)
- `maxPeers` — positive integer; if more peers match, a uniform random sample of that size is returned. No cap when absent.

The requester (`requestingNodeID`, or the nodeID registered on the socket
when omitted) is excluded. A filter field with the wrong type returns
`invalid_message`. There is no discover rate limit.

### `discoverResponse` (relay → client)

```json
{
  "discoverResponse": {
    "peers": [
      {
        "nodeID": "...",
        "publicKey": "...",
        "wgPublicKey": "..." ,
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

`wgPublicKey` is `null` when the peer did not send one. `natType` is always
`"unknown"` and `endpoints` always empty (the relay does not observe them).

### Forwarded messages

All of these carry `fromNodeID`, `toNodeID` and `sessionID` (strings;
`toNodeID` and `sessionID` required). The relay forwards the payload
unchanged except for `fromNodeID` (see above). If `toNodeID` is not
connected the sender gets `peer_not_found` with message
`Peer <toNodeID> is not connected`.

#### `offer` / `answer`

Direct connection signaling (NAT traversal / WireGuard).

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

Signature: `Ed25519.sign(UTF8_bytes("{fromNodeID}:{toNodeID}:{sessionID}"))`,
verified by the receiving peer (not by the relay).

#### `iceCandidate`

```json
{
  "iceCandidate": {
    "fromNodeID": "...",
    "toNodeID": "...",
    "sessionID": "...",
    "candidate": { "ip": "1.2.3.4", "port": 51820, "type": "host", "priority": 100 }
  }
}
```

Candidate types: `host`, `serverReflexive`, `relayed`.

#### `relayOpen` / `relayReady` / `relayClose`

Open (requester → peer), accept (peer → requester) and close a relayed session.

```json
{ "relayOpen": { "fromNodeID": "...", "toNodeID": "...", "sessionID": "uuid-string" } }
```

#### `relayData`

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

`data` is standard base64 (Swift `Data` default encoding). Rust receivers
also accept a JSON array of byte values; anything else (non-base64 strings,
array values outside 0–255) is rejected as corrupt. The bytes are a
JSON-encoded `ClusterMessage` (see below), Noise-encrypted when both peers
have `wgPublicKey`.

### `peerJoined` / `peerLeft` (relay → clients)

Broadcast to every other connected peer when a nodeID registers for the
first time or replaces a session (`peerJoined`), and when a peer's current
socket closes (`peerLeft`). Heartbeat re-registers do not broadcast.

```json
{ "peerJoined": { "nodeID": "...", "displayName": "..." } }
```

### `error` (relay → client)

```json
{ "error": { "code": "peer_not_found", "message": "Peer abc... is not connected" } }
```

| Code | When |
|---|---|
| `invalid_json` | The frame is not JSON |
| `invalid_message` | Not a JSON object, empty object, or a payload with the wrong shape (discover, forwarded messages) |
| `invalid_register` | Register payload missing/invalid `nodeID`, `publicKey`, `signature`, `capabilities`, or wrong-typed optional fields |
| `invalid_signature` | Register signature check failed (see above) |
| `not_registered` | Forwarded message from a socket that has not registered |
| `peer_not_found` | `toNodeID` is not connected |
| `unsupported_message` | Unknown message type |
| `internal_error` | Unexpected relay failure while processing the message |

Rust's `RelayErrorPayload` also accepts an optional `retryAfterSeconds`; the
current relay never sends it.

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

**tier values:** plain integer: 1 (backbone), 2 (desktop), 3 (tablet), 4 (phone/leaf); the gateway registers with 0 (virtual)

## Cluster Messages (inside relayData)

These are JSON-encoded and sent as the `data` payload inside `relayData`
messages. The relay never inspects them. Kinds: `hello`, `helloAck`,
`heartbeat`, `heartbeatAck`, `inferenceRequest`, `inferenceChunk`,
`inferenceComplete`, `inferenceError`, `loadModel`, `modelLoaded`,
`modelLoadError`, `socksOpen`, `socksOpenResult`, `socksData`, `socksClose`.

Rust and Swift both emit the payload wrapped as `{"kind": {"_0": {...}}}`
(Swift default `Codable` for enums with associated values) and accept it
with or without the `_0` wrapper. In Rust, an unrecognised kind parses as
`ClusterMessage::Unknown`; a known kind whose payload fails to deserialize
parses as `ClusterMessage::Invalid { kind, error }` so corruption is not
mistaken for a newer message type.

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
- **Node ID:** lowercase hex of the 32-byte public key (64 characters); see "Identity and the register signature" for what the relay verifies
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
4. Receive `registerAck` (an `error` with code `invalid_signature` means the signature check failed)
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
