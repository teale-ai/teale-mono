# API Keys

Endpoints for managing API keys. API keys are required for authentication when `allow_network_access` is enabled in settings.

---

## List API Keys

```
GET /v1/app/apikeys
```

Returns all API keys for this node.

### Authentication

Optional. Required when `allow_network_access` is enabled.

### Response

```json
{
  "keys": [
    {
      "id": "550e8400-e29b-41d4-a716-446655440000",
      "name": "Development",
      "prefix": "sk-...abc1",
      "created": "2026-04-10T08:00:00Z",
      "lastUsed": "2026-04-14T10:30:00Z"
    }
  ]
}
```

### Example

```bash
curl http://localhost:11435/v1/app/apikeys
```

---

## Generate API Key

```
POST /v1/app/apikeys
```

Generate a new API key. The full key is only returned once in this response -- store it securely.

### Authentication

Optional. Required when `allow_network_access` is enabled.

### Request Body

| Field | Type | Required | Description |
|---|---|---|---|
| `name` | string | Yes | Display name for the key |

```json
{
  "name": "Development"
}
```

### Response

```json
{
  "id": "550e8400-e29b-41d4-a716-446655440000",
  "name": "Development",
  "key": "sk-teale-abc123def456ghi789...",
  "created": "2026-04-14T12:00:00Z"
}
```

### Example

```bash
curl -X POST http://localhost:11435/v1/app/apikeys \
  -H "Content-Type: application/json" \
  -d '{"name": "Development"}'
```

---

## Revoke API Key

```
POST /v1/app/apikeys/revoke
```

Revoke an API key. The key will immediately stop working for authentication.

### Authentication

Optional. Required when `allow_network_access` is enabled.

### Request Body

| Field | Type | Required | Description |
|---|---|---|---|
| `id` | string | Yes | UUID of the key to revoke |

```json
{
  "id": "550e8400-e29b-41d4-a716-446655440000"
}
```

### Response

```json
{
  "status": "revoked",
  "id": "550e8400-e29b-41d4-a716-446655440000"
}
```

### Example

```bash
curl -X POST http://localhost:11435/v1/app/apikeys/revoke \
  -H "Content-Type: application/json" \
  -d '{"id": "550e8400-e29b-41d4-a716-446655440000"}'
```
