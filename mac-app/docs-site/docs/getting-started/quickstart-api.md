# Quickstart: API

Use the released apps as OpenAI-compatible local clients and as a gateway entry point for live Teale Network models.

---

## Prerequisites

- [Install on Mac](install-mac.md)
- [Install on Windows](install-windows.md)
- [Install on Linux](install-linux.md)

Teale must be running with a local model loaded if you want local inference.

## Local base URLs

- macOS app: `http://127.0.0.1:11435/v1`
- Windows local model server: use the **Demand** tab or `GET /v1/app` on `http://127.0.0.1:11437`
- Linux local model server: use the **Demand** tab or `GET /v1/app` on `http://127.0.0.1:11437`

## Claude Desktop Cowork on 3P

Create a revocable API key from **Account > direct gateway api keys**, then configure Claude Desktop with Teale as an LLM gateway:

```json
{
  "inferenceProvider": "gateway",
  "inferenceGatewayBaseUrl": "https://gateway.teale.com",
  "inferenceGatewayApiKey": "<TEALE_API_KEY>",
  "inferenceGatewayAuthScheme": "bearer",
  "inferenceGatewayHeaders": "[\"X-Teale-Prefer-Linked-Device: true\"]",
  "disabledBuiltinTools": "[\"WebSearch\"]",
  "coworkEgressAllowedHosts": "[\"*\"]"
}
```

Leave `inferenceModels` unset for Teale model auto-discovery from `GET /v1/models`. The linked-device header makes Teale try your account-linked serving device first when it is healthy, then fall back to the network fleet.

For Claude Code or the Claude Desktop Code tab, use `ANTHROPIC_BASE_URL=https://gateway.teale.com` without `/v1`; Claude adds `/v1/messages`.

## Anthropic Messages curl

```bash
curl https://gateway.teale.com/v1/messages \
  -H "Authorization: Bearer $TEALE_API_KEY" \
  -H "anthropic-version: 2023-06-01" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "teale/auto",
    "max_tokens": 256,
    "messages": [{"role": "user", "content": "Hello from the Teale Network"}]
  }'
```

`teale/auto` lets Teale pick the best currently available route. The endpoint also accepts `x-api-key: $TEALE_API_KEY` for clients that follow the Anthropic SDK auth shape.

## Local curl

```bash
curl http://127.0.0.1:11435/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "teale-auto",
    "messages": [{"role": "user", "content": "Hello!"}],
    "stream": true
  }'
```

`teale-auto` lets the app choose the best immediately available model. You can also pass a specific loaded model ID.

## Network curl (OpenAI-compatible)

For direct demand clients, create a revocable API key from **Account > direct gateway api keys** and use that key against the gateway. The app still uses its device bearer automatically for in-app network chat, but that device token rotates and is not the recommended long-lived credential for external scripts or tools.

```bash
curl https://gateway.teale.com/v1/chat/completions \
  -H "Authorization: Bearer $TEALE_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "moonshotai/kimi-k2.6",
    "messages": [{"role": "user", "content": "Hello from the Teale Network"}],
    "stream": true
  }'
```

## Python

Install the OpenAI Python library if you don't have it:

```bash
pip install openai
```

Point it at the app's local base URL:

```python
from openai import OpenAI

client = OpenAI(
    base_url="http://127.0.0.1:11435/v1",
    api_key="not-needed",
)

response = client.chat.completions.create(
    model="teale-auto",
    messages=[{"role": "user", "content": "Hello!"}],
)

print(response.choices[0].message.content)
```

To hit the gateway directly instead of your local node:

```python
gateway = OpenAI(
    base_url="https://gateway.teale.com/v1",
    api_key="<account api key>",
)

response = gateway.chat.completions.create(
    model="qwen/qwen3.6-35b-a3b",
    messages=[{"role": "user", "content": "Summarize this release"}],
)
```

## Find the live endpoints inside the apps

- macOS app state and demand metadata: `GET http://127.0.0.1:11435/v1/app`
- Windows companion state and demand metadata: `GET http://127.0.0.1:11437/v1/app`
- Linux companion state and demand metadata: `GET http://127.0.0.1:11437/v1/app`

The demand snapshot includes:

- `local_base_url`
- `local_model_id`
- `network_base_url`
- `network_bearer_token` for the app's rotating device-bearer transport, not for persistent external demand clients

## What is documented here

The released docs only cover the surfaces that ship in the macOS, Windows, and Linux apps:

- `GET /health`
- `GET /v1/models`
- `POST /v1/chat/completions`
- `POST /v1/messages` on `gateway.teale.com` for Anthropic Messages API clients
- released app-control endpoints under `/v1/app`

## Next steps

- [API Reference](../api/index.md)
- [Quickstart: Chat](quickstart-chat.md)
- [Manage models](../guides/manage-models.md)
