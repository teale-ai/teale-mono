# GET /v1/models

Lists models that are immediately available to satisfy an OpenAI-compatible chat request.

## Example

```bash
curl http://127.0.0.1:11435/v1/models
```

## macOS behavior

The released macOS app publishes:

- `teale-auto`
- the current loaded local model
- currently reachable live peer models
- live gateway models that have at least one loaded serving device

That makes the local macOS `/v1/models` route useful as a "what can I use right now?" surface rather than a raw download catalog.

## Windows and Linux behavior

For Windows and Linux, use:

- the local model server's `/v1/models` for the currently loaded local model
- `GET /v1/app/network/models` on the companion API for the live Teale Network table shown in Demand

## Example response

```json
{
  "data": [
    { "id": "teale-auto", "object": "model", "created": 1713984000, "owned_by": "teale" },
    { "id": "nousresearch/hermes-3-llama-3.1-8b", "object": "model", "created": 1713984000, "owned_by": "local" },
    { "id": "moonshotai/kimi-k2.6", "object": "model", "created": 1713984000, "owned_by": "gateway" }
  ]
}
```
