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

## Network curl

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
- released app-control endpoints under `/v1/app`

## Next steps

- [API Reference](../api/index.md)
- [Quickstart: Chat](quickstart-chat.md)
- [Manage models](../guides/manage-models.md)
