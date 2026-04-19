# Health Check

```
GET /health
```

Returns the health status of the node. This endpoint never requires authentication.

## Authentication

None required.

## Request

No request body. No query parameters.

## Response

```json
{
  "status": "ok"
}
```

| Field | Type | Description |
|---|---|---|
| `status` | string | `ok` when the node is running and accepting requests |

## Example

```bash
curl http://localhost:11435/health
```
