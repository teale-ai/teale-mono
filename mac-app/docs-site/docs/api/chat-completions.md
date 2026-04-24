# POST /v1/chat/completions

This is the main OpenAI-compatible inference endpoint exposed by the released apps.

## Local example

```bash
curl http://127.0.0.1:11435/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "teale-auto",
    "messages": [
      { "role": "user", "content": "Say hello from Teale." }
    ],
    "stream": true
  }'
```

## Network example

```bash
curl https://gateway.teale.com/v1/chat/completions \
  -H "Authorization: Bearer $TEALE_BEARER" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "qwen/qwen3.6-35b-a3b",
    "messages": [
      { "role": "user", "content": "Say hello from the Teale Network." }
    ],
    "stream": true
  }'
```

## Notes

- `teale-auto` lets the macOS app choose the best currently available route.
- If you pick a specific model in the app UI, the same model ID can be sent here.
- In-app network chat already uses the device bearer automatically. You only need to supply the bearer for external clients.
- Streaming responses are sent as SSE with `data: ...` lines followed by `data: [DONE]`.
