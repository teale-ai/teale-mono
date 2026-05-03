# Provider Marketplace

Teale's gateway is a two-sided OpenAI-compatible network: **users** send
chat-completion requests; **suppliers** serve them. Two kinds of suppliers
share the same demand:

- **Distributed fleet** — Macs, phones, and other devices running
  `teale-node` that join via the relay. Settled `70 / 25 / 5` (direct earner
  / availability pool / Teale ops).
- **Centralized providers** — 3rd-party inference vendors (OpenRouter-style)
  that expose an OpenAI-compatible HTTP endpoint. Settled `95 / 5`
  (provider / Teale ops). No availability pool — there's no idle co-serving
  fleet to share with.

Both paths sum to **95% supplier / 5% Teale**. Credits are pegged 1 :
$0.000001 USD; payouts are internal-only ledger entries in v1 (no on-chain
off-ramp wired yet).

## Becoming a provider

1. Operator registers your provider with `POST /v1/admin/providers` (admin
   bearer required):
   ```json
   {
     "slug": "acme-inference",
     "displayName": "ACME Inference",
     "baseURL": "https://api.acme.example/v1",
     "wireFormat": "openai",
     "authHeaderName": "Authorization",
     "authSecretRef": "ACME_INFERENCE_KEY",
     "dataCollection": "deny",
     "zdr": true,
     "quantization": "bf16"
   }
   ```
   `authSecretRef` is the **env var name** that holds your API key — never
   the key itself. The operator sets `ACME_INFERENCE_KEY=sk-...` on the
   gateway process; the DB only stores the pointer. Mirrors the existing
   `GATEWAY_TOKENS` posture.

2. Declare your model menu — same JSON shape OpenRouter accepts:
   ```bash
   curl -X POST $GATEWAY/v1/admin/providers/$PROVIDER_ID/models \
     -H "authorization: Bearer $ADMIN_TOKEN" \
     -d '{
       "data": [{
         "id": "openai/gpt-oss-120b",
         "pricing": { "prompt": "0.000001", "completion": "0.000003" },
         "context_length": 131072,
         "max_output_tokens": 32768,
         "supported_features": ["tools", "json_mode"],
         "input_modalities": ["text"]
       }]
     }'
   ```
   - Pricing is **per token in USD**, encoded as a string (no
     floating-point drift).
   - `supported_features` gates `provider.require_parameters` semantics —
     if the user request has `tools` and you didn't advertise them, your
     provider is dropped from the candidate list.
   - `min_context` lets you express OpenRouter's two-tier pricing: short
     prompts use the base row; longer prompts that exceed `min_context`
     pull the next row.

3. Health is tracked automatically against your endpoint following
   OpenRouter's classification:

   | HTTP status     | Counts against uptime? |
   | --------------- | ---------------------- |
   | 401 / 402 / 404 | yes                    |
   | 500+            | yes                    |
   | mid-stream drop | yes                    |
   | 400 / 413       | no (user error)        |
   | 403             | no (geo / policy)      |
   | 429             | no (rate limit)        |

   Tiers: ≥ 95% = normal routing, 80–94% = degraded, < 80% = fallback-only,
   < 100 samples = untracked. Surfaced on `GET /v1/providers`.

## Inference contract

The gateway forwards the user's request body **verbatim** to
`{base_url}/chat/completions` with two adjustments:

- The `model` field is rewritten to the provider-advertised model id (so
  Teale's catalog slug and the provider's slug can differ).
- Streaming requests get `stream_options.include_usage: true` set — Teale
  needs the final `usage` chunk for settlement. Do not strip it.

Stream tokens as soon as they're available. Send SSE comments
(`:keepalive`) for long pauses (reasoning models). Return early `429`
under load rather than queueing — the load balancer treats queued requests
as latency.

Anthropic-shaped providers (`POST /v1/messages`) are reserved (stub
returning `Unavailable` in v1); reuse the OpenAI/Anthropic converter from
`gateway/src/handlers/messages.rs` when wiring it.

## Routing & user preferences

The gateway picks a candidate per request. The user can steer with
OpenRouter-shaped preferences in the request body:

```json
{
  "model": "openai/gpt-oss-120b",
  "messages": [...],
  "provider": {
    "order": ["acme-inference", "teale-distributed"],
    "allow_fallbacks": true,
    "only": ["acme-inference", "globex-llm"],
    "ignore": ["expensive-vendor"],
    "sort": "price",
    "max_price": { "prompt": 1.0, "completion": 2.0 },
    "preferred_min_throughput": { "p50": 100 },
    "preferred_max_latency": { "p50": 1, "p90": 3 },
    "quantizations": ["bf16", "fp8"],
    "data_collection": "deny",
    "zdr": true,
    "require_parameters": true
  }
}
```

Slug shortcuts on the model id: append `:nitro` for `sort: throughput`,
`:floor` for `sort: price`. The slug `teale-distributed` represents the
local fleet as a single peer — use it in `order` / `only` / `ignore` to
include or exclude the distributed network alongside centralized vendors.

Default behavior (no `sort`, no `order`): drop providers that had a counted
error in the last 30s, then weight remaining candidates by inverse-square
of their per-token price (cheapest serves the most traffic, mirroring
OpenRouter's default).

`allow_fallbacks` (default `true`) walks the candidate list on failure;
`false` returns the first error verbatim.

## Settlement

Per request:

- **Distributed earner**: `70 / 25 / 5` — 70 to the device that served, 25
  pro-rata to other eligible online devices, 5 to ops.
- **Centralized earner**: `95 / 5` — 95 to `provider_wallets.balance_credits`,
  5 to ops. No availability pool.

Non-negative invariant holds across both paths: if the consumer can't cover
the cost, all earner shares scale proportionally and the shortfall is noted
on the `SPENT` row.

Provider balances are visible to operators via the `provider_wallets` table
and the per-provider audit trail in `provider_ledger`. Off-ramp is manual
in v1: `POST /v1/admin/providers/:id/payout` writes a `PROVIDER_PAYOUT` row
and debits the wallet; the actual USDC settlement happens out-of-band.

## Public surface

`GET /v1/providers` (unauthenticated) — full marketplace listing with
prices, advertised features, and per-(provider, model) health snapshot.
Feeds the `teale.com/providers` catalog page.

## Admin surface

| Route                                            | Purpose                          |
| ------------------------------------------------ | -------------------------------- |
| `POST   /v1/admin/providers`                     | Create / upsert provider         |
| `POST   /v1/admin/providers/:id/models`          | Bulk upsert model menu           |
| `POST   /v1/admin/providers/:id/enable`          | Mark active                      |
| `POST   /v1/admin/providers/:id/disable`         | Stop routing to this provider    |
| `POST   /v1/admin/providers/:id/payout`          | Record a manual payout           |

All admin routes require a `Static` bearer scope (same gate as
`/v1/admin/mint`); device, account, and share-key bearers are rejected.

## Related code

- `gateway/src/db.rs` migration 009 — provider tables.
- `gateway/src/providers/` — registry, health, OpenAI-compat outbound client.
- `gateway/src/router.rs` — preference parsing, candidate ranking,
  inverse-square load balancing.
- `gateway/src/handlers/centralized.rs` — pre-dispatch hook on
  `/v1/chat/completions`.
- `gateway/src/handlers/admin_providers.rs` — admin endpoints.
- `gateway/src/handlers/providers_public.rs` — public listing.
- `gateway/src/ledger.rs` — `settle_provider_request` (95/5),
  `record_provider_payout`, `get_provider_wallet`.
