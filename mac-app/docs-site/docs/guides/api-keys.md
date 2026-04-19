# API Key Management

Generate and manage API keys to secure access to your Teale node when it is exposed beyond localhost.

---

## Prerequisites

- Teale installed and running

## When you need API keys

By default, Teale only listens on `localhost` and requires no authentication. API keys become necessary when you enable network access, allowing remote clients to reach your node:

```bash
teale config set allow_network_access true
```

With network access enabled, all requests must include a valid API key. Without one, the request is rejected with a 401 error.

## Step 1: Generate a key

```bash
teale apikeys generate "my-app"
```

The label ("my-app") is a human-readable name to help you identify the key later. The command outputs the full API key. Save it immediately --- it is only shown once.

```
API key created: tl_k_abc123def456...
Label: my-app
```

## Step 2: Use the key

Include the API key as a Bearer token in the `Authorization` header:

```bash
curl -H "Authorization: Bearer tl_k_abc123def456..." \
     http://your-mac:11435/v1/chat/completions \
     -d '{"model":"llama-3.1-8b-instruct-4bit","messages":[{"role":"user","content":"Hello"}]}'
```

With the OpenAI SDK:

```python
from openai import OpenAI

client = OpenAI(
    base_url="http://your-mac:11435/v1",
    api_key="tl_k_abc123def456...",
)
```

## Step 3: List keys

View all active API keys:

```bash
teale apikeys list
```

This shows each key's ID, label, creation date, and last used timestamp. The full key value is not shown after creation.

## Step 4: Revoke a key

Revoke a key by its ID:

```bash
teale apikeys revoke <id>
```

Revoked keys are rejected immediately. Any client using the revoked key will receive a 401 error.

## Localhost access without keys

When network access is disabled (the default), the API is bound to `127.0.0.1` only. No authentication is required for localhost requests. This is the recommended setup for personal use and local IDE integrations.

```bash
# Check current setting
teale config get allow_network_access
```

---

## Next steps

- [Use Teale with OpenAI SDK](use-with-openai-sdk.md) --- connect applications to the API
- [Headless Server Mode](headless-server.md) --- expose Teale as a remote service
- [Chat Completions API](../api/chat-completions.md) --- full API reference
