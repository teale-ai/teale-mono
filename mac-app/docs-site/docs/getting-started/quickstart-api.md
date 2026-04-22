# Quickstart: API

Use Teale as a drop-in replacement for the OpenAI API. The local server runs at `localhost:11435` and supports the `/v1/chat/completions` endpoint with streaming.

---

## Prerequisites

Teale must be running with a model loaded. If you haven't set it up yet, see [Install on Mac](install-mac.md) or [Install the CLI](install-cli.md).

```bash
teale up
teale status  # Confirm a model is loaded
```

## curl

```bash
curl http://localhost:11435/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "llama-3.1-8b-instruct-4bit",
    "messages": [{"role": "user", "content": "Hello!"}],
    "stream": true
  }'
```

No API key is required. The `model` field should match a model you have downloaded. Run `teale models list` to see available models.

## Python

Install the OpenAI Python library if you don't have it:

```bash
pip install openai
```

Point it at your local Teale server:

```python
from openai import OpenAI

client = OpenAI(
    base_url="http://localhost:11435/v1",
    api_key="not-needed",
)

response = client.chat.completions.create(
    model="llama-3.1-8b-instruct-4bit",
    messages=[{"role": "user", "content": "Hello!"}],
)

print(response.choices[0].message.content)
```

With streaming:

```python
stream = client.chat.completions.create(
    model="llama-3.1-8b-instruct-4bit",
    messages=[{"role": "user", "content": "Explain how transformers work"}],
    stream=True,
)

for chunk in stream:
    if chunk.choices[0].delta.content:
        print(chunk.choices[0].delta.content, end="")
```

## Node.js

Install the OpenAI Node library:

```bash
npm install openai
```

```javascript
import OpenAI from "openai";

const client = new OpenAI({
  baseURL: "http://localhost:11435/v1",
  apiKey: "not-needed",
});

const response = await client.chat.completions.create({
  model: "llama-3.1-8b-instruct-4bit",
  messages: [{ role: "user", content: "Hello!" }],
});

console.log(response.choices[0].message.content);
```

## Framework compatibility

Teale works with any tool or framework that supports the OpenAI API format. Tested integrations include:

- **LangChain** --- set `base_url` to `http://localhost:11435/v1`
- **LlamaIndex** --- use the OpenAI LLM class with a custom `api_base`
- **Continue.dev** --- add Teale as an OpenAI-compatible provider in `config.json`
- **Open WebUI** --- point the OpenAI API URL to `http://localhost:11435`
- **Any OpenAI SDK** --- change the base URL, no other modifications needed

## Supported endpoints

| Endpoint | Description |
|----------|-------------|
| `GET /v1/models` | List available models |
| `POST /v1/chat/completions` | Chat completion (streaming and non-streaming) |

## Conductor workspace setup

If you want tools inside Conductor workspaces to use the hosted Teale fleet instead of your local node, use:

```bash
OPENAI_BASE_URL=https://gateway.teale.com/v1
OPENAI_API_KEY=<your-teale-gateway-token>
```

Preferred model once Kimi is exposed on the gateway:

```text
kimi2.6
```

Canonical fallback:

```text
moonshotai/kimi-k2
```

Full setup guide:

- [Use with Conductor](../guides/use-with-conductor.md)

---

## Next steps

- [Quickstart: Earn](quickstart-earn.md) --- share compute and earn USDC
- [Quickstart: Chat](quickstart-chat.md) --- use the built-in chat interface
- [Use with Conductor](../guides/use-with-conductor.md) --- route Conductor workspace tools to the hosted gateway
