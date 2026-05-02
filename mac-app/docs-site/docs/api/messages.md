# POST /v1/messages

Anthropic Messages API compatibility for Claude Desktop Cowork on third-party inference and Claude Code gateway clients.

This endpoint is exposed on the Teale Network gateway:

```text
https://gateway.teale.com/v1/messages
```

Use a revocable human-account API key from **Account > direct gateway api keys**. Teale accepts either `Authorization: Bearer <key>` or `x-api-key: <key>`.

## Claude Desktop Cowork on 3P

Configure Claude Desktop with these managed keys:

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

Leave `inferenceModels` unset unless you want to override auto-discovery. Claude will read the live Teale catalog from `GET /v1/models`; `teale/auto` remains the recommended default.

`X-Teale-Prefer-Linked-Device: true` asks the gateway to route to one of your account-linked Teale devices first when it is healthy for the requested model. If none is available, Teale falls back to the normal fleet.

Claude's Code tab may need separate Claude Code managed settings. For direct Claude Code gateway setup, use:

```bash
export ANTHROPIC_BASE_URL=https://gateway.teale.com
export ANTHROPIC_AUTH_TOKEN="$TEALE_API_KEY"
```

Do not include `/v1` in `ANTHROPIC_BASE_URL`; Claude adds `/v1/messages`.

## Curl

```bash
curl https://gateway.teale.com/v1/messages \
  -H "Authorization: Bearer $TEALE_API_KEY" \
  -H "anthropic-version: 2023-06-01" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "teale/auto",
    "max_tokens": 256,
    "messages": [
      { "role": "user", "content": "Say hello from Teale." }
    ]
  }'
```

## Supported request fields

- `model`
- `system`
- `messages` with text, `tool_use`, and `tool_result` blocks
- `max_tokens`
- `temperature`
- `top_p`
- `stop_sequences`
- `stream`
- custom `tools` and `tool_choice`

Built-in Anthropic server tools such as `web_search` are not implemented by Teale V1. Disable `WebSearch` in Claude Desktop, or provide web access through MCP.

## Streaming

Set `"stream": true` to receive Anthropic SSE events:

- `message_start`
- `content_block_start`
- `content_block_delta`
- `content_block_stop`
- `message_delta`
- `message_stop`
- `error`
