# App Snapshot

```
GET /v1/app
```

Returns a full snapshot of the application state, including the currently loaded model, hardware information, connected peers, credit balance, and settings.

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
  "node": {
    "id": "node-abc123",
    "name": "My MacBook Pro"
  },
  "hardware": {
    "chip": "Apple M2 Pro",
    "memory_gb": 32,
    "gpu_cores": 19
  },
  "model": {
    "id": "llama-3.1-8b-q4",
    "status": "loaded",
    "context_length": 8192
  },
  "peers": {
    "lan": 3,
    "wan": 7
  },
  "wallet": {
    "balance": 1.234
  },
  "settings": {
    "cluster_enabled": true,
    "wan_enabled": false,
    "allow_network_access": false,
    "keep_awake": true,
    "auto_manage_models": true,
    "inference_backend": "mlx",
    "language": "en"
  }
}
```

## Example

```bash
curl http://localhost:11435/v1/app
```

```bash
curl http://localhost:11435/v1/app \
  -H "Authorization: Bearer your-api-key"
```
