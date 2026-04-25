# App Model Controls

The released macOS and Windows apps both expose model-control endpoints under `/v1/app/models`.

## POST /v1/app/models/download

Starts a model download from the app catalog.

```bash
curl http://127.0.0.1:11435/v1/app/models/download \
  -H "Content-Type: application/json" \
  -d '{"model":"hermes-3-llama-3.1-8b-4bit"}'
```

## POST /v1/app/models/load

Loads a downloaded model into memory so it becomes usable for local inference and supply.

```bash
curl http://127.0.0.1:11435/v1/app/models/load \
  -H "Content-Type: application/json" \
  -d '{"model":"hermes-3-llama-3.1-8b-4bit"}'
```

## POST /v1/app/models/unload

Unloads the current local model.

```bash
curl -X POST http://127.0.0.1:11435/v1/app/models/unload
```

## Response shape

Both platforms return the updated app snapshot after these operations.

## Important distinction

These endpoints manage the local machine's downloaded and loaded models.

They are different from the live Teale Network model list shown in:

- the Home chat model picker
- `GET /v1/app/network/models` on Windows
- `GET /v1/models` on macOS

Those views only represent models that are currently available to serve requests.
