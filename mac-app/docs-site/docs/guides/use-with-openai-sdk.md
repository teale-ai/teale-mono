# Use Teale with OpenAI SDK

Teale exposes an OpenAI-compatible API at `http://localhost:11435/v1`. Any application or library that works with the OpenAI API works with Teale --- no code changes beyond the base URL.

---

## Prerequisites

- Teale running with a model loaded (`teale up`)
- The OpenAI SDK for your language installed

## Python

Install the OpenAI Python package:

```bash
pip install openai
```

### Streaming completion

```python
from openai import OpenAI

client = OpenAI(
    base_url="http://localhost:11435/v1",
    api_key="not-needed",
)

response = client.chat.completions.create(
    model="llama-3.1-8b-instruct-4bit",
    messages=[{"role": "user", "content": "Hello!"}],
    stream=True,
)

for chunk in response:
    print(chunk.choices[0].delta.content or "", end="")
```

### Non-streaming completion

```python
response = client.chat.completions.create(
    model="llama-3.1-8b-instruct-4bit",
    messages=[{"role": "user", "content": "Explain quicksort in two sentences."}],
)

print(response.choices[0].message.content)
```

## Node.js

Install the OpenAI Node package:

```bash
npm install openai
```

### Streaming completion

```javascript
import OpenAI from 'openai';

const client = new OpenAI({
    baseURL: 'http://localhost:11435/v1',
    apiKey: 'not-needed',
});

const stream = await client.chat.completions.create({
    model: 'llama-3.1-8b-instruct-4bit',
    messages: [{ role: 'user', content: 'Hello!' }],
    stream: true,
});

for await (const chunk of stream) {
    process.stdout.write(chunk.choices[0]?.delta?.content || '');
}
```

### Non-streaming completion

```javascript
const response = await client.chat.completions.create({
    model: 'llama-3.1-8b-instruct-4bit',
    messages: [{ role: 'user', content: 'Explain quicksort in two sentences.' }],
});

console.log(response.choices[0].message.content);
```

## List available models

Use the standard models endpoint to see what is loaded:

```bash
curl http://localhost:11435/v1/models | jq
```

Or via the SDK:

```python
models = client.models.list()
for model in models:
    print(model.id)
```

## Use the hosted gateway

When you want workspace tools inside Conductor to use the Teale fleet instead of your local node, point the SDK at `https://gateway.teale.com/v1` and pass your gateway bearer token:

```python
client = OpenAI(
    base_url="https://gateway.teale.com/v1",
    api_key="your-teale-gateway-token",
)

response = client.chat.completions.create(
    model="kimi2.6",
    messages=[{"role": "user", "content": "Write a tiny Rust retry helper."}],
)
```

Canonical fallback:

```text
moonshotai/kimi-k2
```

See [Use with Conductor](use-with-conductor.md) for the Conductor-specific environment setup.

## Compatible libraries and tools

Teale's OpenAI-compatible API works with any client that supports custom base URLs:

| Tool / Library | Configuration                                      |
|----------------|---------------------------------------------------|
| LangChain      | Set `openai_api_base="http://localhost:11435/v1"` |
| LlamaIndex     | Set `api_base="http://localhost:11435/v1"`        |
| Open WebUI     | Add connection with URL `http://localhost:11435`   |
| Vercel AI SDK  | Use `createOpenAI({ baseURL: "http://localhost:11435/v1" })` |

See [IDE Integration](use-with-continue-dev.md) for editor-specific setup.

## Authentication

When Teale runs locally with network access disabled (the default), no API key is needed. Pass any string as `api_key` to satisfy SDK requirements.

If you have enabled network access and generated API keys, pass the key as a Bearer token:

```python
client = OpenAI(
    base_url="http://localhost:11435/v1",
    api_key="your-api-key-here",
)
```

See [API Key Management](api-keys.md) for details.

---

## Next steps

- [Use with Conductor](use-with-conductor.md) --- route Conductor workspace tools to the hosted gateway
- [IDE Integration](use-with-continue-dev.md) --- use Teale with Continue.dev, Cursor, and other editors
- [Chat Completions API](../api/chat-completions.md) --- full API reference
- [Manage Models](manage-models.md) --- download and load different models
