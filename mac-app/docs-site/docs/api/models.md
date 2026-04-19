# List Models

```
GET /v1/models
```

Returns the list of models available on this node and its connected peers. This endpoint is OpenAI-compatible.

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
  "object": "list",
  "data": [
    {
      "id": "llama-3.1-8b-q4",
      "object": "model",
      "owned_by": "local"
    },
    {
      "id": "qwen3-4b-q4",
      "object": "model",
      "owned_by": "local"
    },
    {
      "id": "gemma-3-12b-q4",
      "object": "model",
      "owned_by": "peer:abc123"
    }
  ]
}
```

### Model Object

| Field | Type | Description |
|---|---|---|
| `id` | string | Model identifier, used in chat completion requests |
| `object` | string | Always `model` |
| `owned_by` | string | `local` for models on this node, `peer:<id>` for models available via connected peers |

## Example

```bash
curl http://localhost:11435/v1/models
```

```bash
curl http://localhost:11435/v1/models \
  -H "Authorization: Bearer your-api-key"
```
