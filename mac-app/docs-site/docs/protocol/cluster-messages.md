# Cluster Messages

Messages exchanged inside relay sessions or over LAN TCP connections.

## Overview

Cluster messages are the application-layer protocol of TealeNet. They are sent as JSON inside `relayData` payloads (WAN) or as length-prefixed JSON over persistent TCP connections (LAN).

On LAN, messages are framed with a 4-byte big-endian length prefix followed by the JSON payload bytes. On WAN, messages are JSON-encoded, optionally encrypted via [Noise](noise-encryption.md), then base64-encoded into the `relayData.data` field.

All cluster messages use the same single-key JSON format as relay messages:

```json
{"inferenceRequest": { ...payload... }}
```

## Message Categories

| Category | Messages | Direction |
|----------|----------|-----------|
| Handshake | `hello`, `helloAck` | Bidirectional |
| Health | `heartbeat`, `heartbeatAck` | Bidirectional |
| Inference | `inferenceRequest`, `inferenceChunk`, `inferenceComplete`, `inferenceError` | Consumer to provider, provider to consumer |
| Model Sharing | `modelQuery`, `modelQueryResponse`, `modelTransferRequest`, `modelTransferChunk`, `modelTransferComplete` | Bidirectional |

---

## Handshake

### `hello`

Sent when a peer connection is established. Contains device information and loaded models.

```json
{
  "hello": {
    "deviceInfo": {
      "id": "550e8400-e29b-41d4-a716-446655440000",
      "name": "Linux Server",
      "hardware": {
        "chipFamily": "nvidiaGPU",
        "chipName": "NVIDIA RTX 4090",
        "totalRAMGB": 64.0,
        "gpuCoreCount": 16384,
        "memoryBandwidthGBs": 1008.0,
        "tier": 1,
        "gpuBackend": "cuda",
        "platform": "linux",
        "gpuVRAMGB": 24.0
      },
      "registeredAt": 798134400.0,
      "lastSeenAt": 798134400.0,
      "isCurrentDevice": true,
      "loadedModels": []
    },
    "protocolVersion": 1,
    "clusterPasscodeHash": null,
    "loadedModels": ["mlx-community/Qwen3-8B-4bit"],
    "ownerUserID": null
  }
}
```

| Field | Type | Description |
|-------|------|-------------|
| `deviceInfo` | object | Device identification and hardware profile |
| `protocolVersion` | number | Protocol version (currently `1`) |
| `clusterPasscodeHash` | string or null | SHA-256 hash of cluster passcode (LAN clusters) |
| `loadedModels` | array | List of model IDs currently loaded for inference |
| `ownerUserID` | string or null | Optional owner UUID for multi-device ownership |

### `helloAck`

Sent in response to `hello`. Uses the same schema as `hello` with the responder's device information.

---

## Health Monitoring

### `heartbeat`

Periodic health report sent by each node.

```json
{
  "heartbeat": {
    "deviceID": "550e8400-e29b-41d4-a716-446655440000",
    "timestamp": 798134400.0,
    "thermalLevel": "nominal",
    "throttleLevel": 100,
    "loadedModels": ["mlx-community/Qwen3-8B-4bit"],
    "isGenerating": false,
    "queueDepth": 0,
    "organizationID": null,
    "ownerUserID": null
  }
}
```

| Field | Type | Description |
|-------|------|-------------|
| `deviceID` | string | UUID of the sending device |
| `timestamp` | number | Apple reference date timestamp |
| `thermalLevel` | string | One of: `nominal`, `fair`, `serious`, `critical` |
| `throttleLevel` | number | 0 (paused) to 100 (full speed) |
| `loadedModels` | array | Currently loaded model IDs |
| `isGenerating` | boolean | Whether the node is currently generating tokens |
| `queueDepth` | number | Number of queued inference requests |
| `organizationID` | string or null | Optional organization ID |
| `ownerUserID` | string or null | Optional owner UUID |

### `heartbeatAck`

Sent in response to `heartbeat`. Same schema, with the responder's health data.

---

## Inference

### `inferenceRequest`

Request inference from a provider. The `request` field is an OpenAI-compatible `ChatCompletionRequest`.

```json
{
  "inferenceRequest": {
    "requestID": "550e8400-e29b-41d4-a716-446655440000",
    "request": {
      "model": "mlx-community/Qwen3-8B-4bit",
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

| Field | Type | Description |
|-------|------|-------------|
| `requestID` | string | UUID identifying this inference request |
| `request` | object | OpenAI-compatible ChatCompletionRequest |
| `streaming` | boolean | Whether to stream response chunks |

### `inferenceChunk`

A single streamed token or chunk from the provider.

```json
{
  "inferenceChunk": {
    "requestID": "550e8400-...",
    "chunk": {
      "id": "chatcmpl-xxx",
      "object": "chat.completion.chunk",
      "created": 1713100000,
      "model": "mlx-community/Qwen3-8B-4bit",
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

The `chunk` field is an OpenAI-compatible `ChatCompletionChunk`.

### `inferenceComplete`

Signals that all chunks have been sent for a request.

```json
{
  "inferenceComplete": {
    "requestID": "550e8400-..."
  }
}
```

### `inferenceError`

Signals that inference failed for a request.

```json
{
  "inferenceError": {
    "requestID": "550e8400-...",
    "errorMessage": "Model not loaded"
  }
}
```

---

## Model Sharing

Peer-to-peer model transfer for distributing models across the network.

### `modelQuery`

Ask a peer if they have a specific model available for transfer.

```json
{
  "modelQuery": {
    "modelID": "mlx-community/Qwen3-8B-4bit"
  }
}
```

### `modelQueryResponse`

Response indicating model availability and size.

```json
{
  "modelQueryResponse": {
    "modelID": "mlx-community/Qwen3-8B-4bit",
    "available": true,
    "totalSizeBytes": 4831838208
  }
}
```

### `modelTransferRequest`

Request to begin transferring a model.

```json
{
  "modelTransferRequest": {
    "transferID": "550e8400-...",
    "modelID": "mlx-community/Qwen3-8B-4bit"
  }
}
```

### `modelTransferChunk`

A chunk of model data. Models are transferred in 1 MB chunks.

```json
{
  "modelTransferChunk": {
    "transferID": "550e8400-...",
    "fileName": "model.safetensors",
    "offset": 0,
    "data": "base64-encoded-bytes",
    "isLastChunk": false
  }
}
```

| Field | Type | Description |
|-------|------|-------------|
| `transferID` | string | UUID identifying this transfer |
| `fileName` | string | Name of the file being transferred |
| `offset` | number | Byte offset within the file |
| `data` | string | Base64-encoded chunk data (~1 MB) |
| `isLastChunk` | boolean | Whether this is the last chunk for this file |

### `modelTransferComplete`

Signals that all files for a model have been transferred.

```json
{
  "modelTransferComplete": {
    "transferID": "550e8400-...",
    "modelID": "mlx-community/Qwen3-8B-4bit"
  }
}
```
