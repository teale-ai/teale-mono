# API Reference

Teale exposes a local HTTP API for controlling the node, running inference, and managing network resources. The API is OpenAI-compatible for chat completions and model listing, making it a drop-in replacement for applications that already target the OpenAI API.

## Base URL

```
http://localhost:11435
```

The port is configurable via the `--port` flag when starting the node.

## Authentication

Authentication is **optional by default**. When `allow_network_access` is enabled in settings, an API key is required for all requests except `GET /health`.

Pass the API key via the `Authorization` header:

```
Authorization: Bearer <your-api-key>
```

Generate API keys using the `POST /v1/app/apikeys` endpoint or the `teale apikeys generate` CLI command.

## Response Format

All responses are JSON. Successful responses return the relevant resource object directly. Errors return a standard error envelope:

```json
{
  "error": {
    "message": "Model not found: invalid-model-id",
    "type": "not_found"
  }
}
```

## OpenAI Compatibility

The following endpoints are fully OpenAI-compatible:

| Endpoint | Description |
|---|---|
| `POST /v1/chat/completions` | Chat completions (streaming and non-streaming) |
| `GET /v1/models` | List available models |

This means you can point any OpenAI SDK client at your Teale node by setting the base URL:

```python
from openai import OpenAI

client = OpenAI(
    base_url="http://localhost:11435/v1",
    api_key="your-api-key"  # or "not-needed" if auth is disabled
)
```

## Endpoint Overview

### OpenAI-Compatible

| Method | Path | Description |
|---|---|---|
| `POST` | `/v1/chat/completions` | Chat completions |
| `GET` | `/v1/models` | List available models |

### Health

| Method | Path | Description |
|---|---|---|
| `GET` | `/health` | Health check |

### App State

| Method | Path | Description |
|---|---|---|
| `GET` | `/v1/app` | Full app state snapshot |
| `PATCH` | `/v1/app/settings` | Update settings |

### Models

| Method | Path | Description |
|---|---|---|
| `POST` | `/v1/app/models/load` | Load model into GPU |
| `POST` | `/v1/app/models/download` | Download a model |
| `POST` | `/v1/app/models/unload` | Unload current model |

### Peers

| Method | Path | Description |
|---|---|---|
| `GET` | `/v1/app/peers` | List connected peers |

### Private TealeNet (PTN)

| Method | Path | Description |
|---|---|---|
| `GET` | `/v1/app/ptn` | List PTN memberships |
| `POST` | `/v1/app/ptn/create` | Create a PTN |
| `POST` | `/v1/app/ptn/invite` | Generate invite code |
| `POST` | `/v1/app/ptn/issue-cert` | Issue membership certificate |
| `POST` | `/v1/app/ptn/join-with-cert` | Join PTN with certificate |
| `POST` | `/v1/app/ptn/leave` | Leave a PTN |
| `POST` | `/v1/app/ptn/promote-admin` | Promote member to admin |
| `POST` | `/v1/app/ptn/import-ca-key` | Import CA signing key |
| `POST` | `/v1/app/ptn/recover` | Recover PTN membership |

### Wallet

| Method | Path | Description |
|---|---|---|
| `GET` | `/v1/app/wallet` | Wallet balance |
| `GET` | `/v1/app/wallet/transactions` | Transaction history |
| `POST` | `/v1/app/wallet/send` | Send credits to a peer |
| `GET` | `/v1/app/wallet/solana` | Solana wallet status |

### Agent

| Method | Path | Description |
|---|---|---|
| `GET` | `/v1/app/agent/profile` | Agent profile |
| `GET` | `/v1/app/agent/directory` | Agent directory |
| `GET` | `/v1/app/agent/conversations` | Agent conversations |

### API Keys

| Method | Path | Description |
|---|---|---|
| `GET` | `/v1/app/apikeys` | List API keys |
| `POST` | `/v1/app/apikeys` | Generate a new API key |
| `POST` | `/v1/app/apikeys/revoke` | Revoke an API key |
