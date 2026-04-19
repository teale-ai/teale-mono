# Chat Completions

```
POST /v1/chat/completions
```

Generate a chat completion. This endpoint is fully OpenAI-compatible and supports both streaming and non-streaming responses.

## Authentication

Optional. Required when `allow_network_access` is enabled.

```
Authorization: Bearer <your-api-key>
```

## Request Body

| Field | Type | Required | Default | Description |
|---|---|---|---|---|
| `model` | string | Yes | | Model ID to use for completion |
| `messages` | array | Yes | | Array of message objects |
| `temperature` | number | No | 1.0 | Sampling temperature, between 0 and 2 |
| `top_p` | number | No | 1.0 | Nucleus sampling threshold |
| `max_tokens` | integer | No | Model default | Maximum number of tokens to generate |
| `stream` | boolean | No | false | Enable streaming via Server-Sent Events |

### Message Object

| Field | Type | Required | Description |
|---|---|---|---|
| `role` | string | Yes | One of `system`, `user`, or `assistant` |
| `content` | string | Yes | The message content |

## Non-Streaming Response

```json
{
  "id": "chatcmpl-abc123",
  "object": "chat.completion",
  "created": 1713100800,
  "model": "llama-3.1-8b-q4",
  "choices": [
    {
      "index": 0,
      "message": {
        "role": "assistant",
        "content": "Hello! How can I help you today?"
      },
      "finish_reason": "stop"
    }
  ],
  "usage": {
    "prompt_tokens": 12,
    "completion_tokens": 9,
    "total_tokens": 21
  }
}
```

## Streaming Response

When `stream: true`, the response is delivered as Server-Sent Events. Each event is a `data:` line containing a JSON chunk, terminated by `data: [DONE]`.

```
data: {"id":"chatcmpl-abc123","object":"chat.completion.chunk","created":1713100800,"model":"llama-3.1-8b-q4","choices":[{"index":0,"delta":{"role":"assistant","content":""},"finish_reason":null}]}

data: {"id":"chatcmpl-abc123","object":"chat.completion.chunk","created":1713100800,"model":"llama-3.1-8b-q4","choices":[{"index":0,"delta":{"content":"Hello"},"finish_reason":null}]}

data: {"id":"chatcmpl-abc123","object":"chat.completion.chunk","created":1713100800,"model":"llama-3.1-8b-q4","choices":[{"index":0,"delta":{"content":"!"},"finish_reason":null}]}

data: {"id":"chatcmpl-abc123","object":"chat.completion.chunk","created":1713100800,"model":"llama-3.1-8b-q4","choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}

data: [DONE]
```

### Streaming Chunk Object

| Field | Type | Description |
|---|---|---|
| `id` | string | Completion ID (same across all chunks) |
| `object` | string | Always `chat.completion.chunk` |
| `created` | integer | Unix timestamp |
| `model` | string | Model ID used |
| `choices` | array | Array with one choice object |
| `choices[].index` | integer | Choice index |
| `choices[].delta` | object | Incremental content (`role` and/or `content`) |
| `choices[].finish_reason` | string or null | `stop` on final chunk, `null` otherwise |

## Examples

### Non-streaming request

```bash
curl http://localhost:11435/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "llama-3.1-8b-q4",
    "messages": [
      {"role": "system", "content": "You are a helpful assistant."},
      {"role": "user", "content": "What is the capital of France?"}
    ],
    "temperature": 0.7,
    "max_tokens": 256
  }'
```

### Streaming request

```bash
curl http://localhost:11435/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "llama-3.1-8b-q4",
    "messages": [
      {"role": "user", "content": "Write a haiku about computers."}
    ],
    "stream": true
  }'
```

### Using the OpenAI Python SDK

```python
from openai import OpenAI

client = OpenAI(
    base_url="http://localhost:11435/v1",
    api_key="not-needed"
)

response = client.chat.completions.create(
    model="llama-3.1-8b-q4",
    messages=[
        {"role": "user", "content": "Explain quantum computing in one sentence."}
    ]
)

print(response.choices[0].message.content)
```

### Streaming with the OpenAI Python SDK

```python
from openai import OpenAI

client = OpenAI(
    base_url="http://localhost:11435/v1",
    api_key="not-needed"
)

stream = client.chat.completions.create(
    model="llama-3.1-8b-q4",
    messages=[
        {"role": "user", "content": "Tell me a joke."}
    ],
    stream=True
)

for chunk in stream:
    if chunk.choices[0].delta.content:
        print(chunk.choices[0].delta.content, end="")
```

## Error Responses

| Status | Error Type | Description |
|---|---|---|
| 400 | `invalid_request` | Missing or invalid parameters |
| 401 | `authentication_error` | Invalid or missing API key |
| 404 | `not_found` | Requested model not available |
| 503 | `service_unavailable` | No model loaded or node is busy |
