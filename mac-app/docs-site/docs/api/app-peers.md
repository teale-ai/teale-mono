# Peers

```
GET /v1/app/peers
```

Returns a list of all connected peers, including both LAN cluster peers and WAN peers.

## Authentication

Optional. Required when `allow_network_access` is enabled.

```
Authorization: Bearer <your-api-key>
```

## Request

No request body. No query parameters.

## Response

```json
{
  "peers": [
    {
      "id": "node-abc123",
      "name": "Office iMac",
      "type": "lan",
      "model": "llama-3.1-8b-q4",
      "hardware": {
        "chip": "Apple M4",
        "memory_gb": 64
      },
      "latency_ms": 2
    },
    {
      "id": "node-def456",
      "name": "Home Mac Mini",
      "type": "wan",
      "model": "qwen3-4b-q4",
      "hardware": {
        "chip": "Apple M2",
        "memory_gb": 16
      },
      "latency_ms": 45
    }
  ]
}
```

### Peer Object

| Field | Type | Description |
|---|---|---|
| `id` | string | Unique peer identifier |
| `name` | string | Display name of the peer |
| `type` | string | Connection type: `lan` or `wan` |
| `model` | string | Currently loaded model on the peer, or `null` |
| `hardware` | object | Hardware information |
| `hardware.chip` | string | Chip identifier |
| `hardware.memory_gb` | integer | Total system memory in GB |
| `latency_ms` | integer | Network latency to peer in milliseconds |

## Example

```bash
curl http://localhost:11435/v1/app/peers
```
