# Use with Conductor

Route OpenAI-compatible tools running inside Conductor workspaces to Teale's hosted gateway. This is the right setup when you want Conductor workspace tools to use the Teale fleet, including cluster-only models such as Kimi.

This guide is for **workspace tools and OpenAI-compatible clients inside Conductor**, not Conductor's native Codex provider picker.

---

## Recommended setup

Use the hosted gateway as the default OpenAI-compatible endpoint:

```bash
OPENAI_BASE_URL=https://gateway.teale.com/v1
OPENAI_API_KEY=<your-teale-gateway-token>
```

Once Kimi is visible on the gateway, the client-facing default model is:

```text
kimi2.6
```

Canonical fallback:

```text
moonshotai/kimi-k2
```

## Step 1: Add the env vars in Conductor

In Conductor:

1. Open `Settings`.
2. Open `Env`.
3. Add:

```bash
OPENAI_BASE_URL=https://gateway.teale.com/v1
OPENAI_API_KEY=<your-teale-gateway-token>
```

New workspace terminals and tools launched from Conductor will inherit these values.

## Step 2: Verify the gateway exposes Kimi

From a Conductor workspace terminal:

```bash
curl -sS https://gateway.teale.com/v1/models \
  -H "Authorization: Bearer $OPENAI_API_KEY" | jq
```

Look for:

- `id: "moonshotai/kimi-k2"`
- alias support for `kimi2.6`

If the model is missing, the cluster is either not yet healthy enough for the gateway's supply-floor logic or the catalog entry has not been deployed yet.

## Step 3: Use the alias from OpenAI-compatible clients

### Python

```python
from openai import OpenAI

client = OpenAI(
    base_url="https://gateway.teale.com/v1",
    api_key="your-teale-gateway-token",
)

response = client.chat.completions.create(
    model="kimi2.6",
    messages=[{"role": "user", "content": "Write a tiny Rust retry helper."}],
)

print(response.choices[0].message.content)
```

### Node.js

```javascript
import OpenAI from "openai";

const client = new OpenAI({
  baseURL: "https://gateway.teale.com/v1",
  apiKey: process.env.OPENAI_API_KEY,
});

const response = await client.chat.completions.create({
  model: "kimi2.6",
  messages: [{ role: "user", content: "Write a tiny Rust retry helper." }],
});

console.log(response.choices[0].message.content);
```

### curl

```bash
curl -sS https://gateway.teale.com/v1/chat/completions \
  -H "Authorization: Bearer $OPENAI_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"model":"kimi2.6","messages":[{"role":"user","content":"Reply with the word ready."}],"stream":false}'
```

## Supported usage in Conductor

This setup is intended for:

- OpenAI SDK scripts run from the workspace terminal
- editor integrations launched inside the workspace
- any tool that honors `OPENAI_BASE_URL` and `OPENAI_API_KEY`
- custom run scripts that call an OpenAI-compatible endpoint

This guide does **not** reconfigure Conductor's built-in Codex tab.

## Failure modes

| Symptom | Likely cause |
|---|---|
| `401 unauthorized` | Wrong or missing Teale gateway token |
| `404` / `model_not_found` | Kimi catalog row or alias not deployed |
| Kimi absent from `/v1/models` | Cluster is not healthy enough, or the gateway supply floor filtered it out |
| Canonical model works but `kimi2.6` fails | Alias missing from the gateway catalog |

## Local fallback for debugging only

If the hosted gateway is unavailable and you need a quick local smoke check, point the client back at your local Teale node:

```bash
OPENAI_BASE_URL=http://localhost:11435/v1
OPENAI_API_KEY=not-needed
```

Then use:

```text
model = teale-auto
```

Keep this as a debug fallback only. For Kimi in Conductor, the primary path is the hosted gateway.

## Next steps

- [Use with OpenAI SDK](use-with-openai-sdk.md) --- generic OpenAI-compatible integration
- [IDE Integration](use-with-continue-dev.md) --- Continue, Cursor, Open WebUI, and Zed
- [LAN Cluster Setup](lan-cluster.md) --- local multi-Mac networking basics
