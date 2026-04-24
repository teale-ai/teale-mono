# GET /health

Use this endpoint to confirm that the local model server is alive.

## Where it exists

- macOS app local server: `http://127.0.0.1:11435/health`
- Windows local model server: use the host behind `demand.local_base_url` and request `/health`

The Windows companion API on `127.0.0.1:11437` does not use this route for its own state snapshot. Use `GET /v1/app` there instead.

## Example

```bash
curl http://127.0.0.1:11435/health
```

## Response

```json
{"status":"ok"}
```
