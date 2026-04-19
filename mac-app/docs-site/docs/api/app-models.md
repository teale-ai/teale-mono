# Model Management

Endpoints for loading, downloading, and unloading models on the node.

---

## Load Model

```
POST /v1/app/models/load
```

Load a downloaded model into GPU memory for inference.

### Authentication

Optional. Required when `allow_network_access` is enabled.

### Request Body

| Field | Type | Required | Description |
|---|---|---|---|
| `modelID` | string | Yes | ID of the model to load |

```json
{
  "modelID": "llama-3.1-8b-q4"
}
```

### Response

```json
{
  "status": "loaded",
  "modelID": "llama-3.1-8b-q4"
}
```

### Example

```bash
curl -X POST http://localhost:11435/v1/app/models/load \
  -H "Content-Type: application/json" \
  -d '{"modelID": "llama-3.1-8b-q4"}'
```

---

## Download Model

```
POST /v1/app/models/download
```

Download a model to local storage. The model must be downloaded before it can be loaded.

### Authentication

Optional. Required when `allow_network_access` is enabled.

### Request Body

| Field | Type | Required | Description |
|---|---|---|---|
| `modelID` | string | Yes | ID of the model to download |

```json
{
  "modelID": "llama-3.1-8b-q4"
}
```

### Response

```json
{
  "status": "downloading",
  "modelID": "llama-3.1-8b-q4"
}
```

### Example

```bash
curl -X POST http://localhost:11435/v1/app/models/download \
  -H "Content-Type: application/json" \
  -d '{"modelID": "llama-3.1-8b-q4"}'
```

---

## Unload Model

```
POST /v1/app/models/unload
```

Unload the currently loaded model from GPU memory.

### Authentication

Optional. Required when `allow_network_access` is enabled.

### Request Body

None required.

### Response

```json
{
  "status": "unloaded"
}
```

### Example

```bash
curl -X POST http://localhost:11435/v1/app/models/unload
```
