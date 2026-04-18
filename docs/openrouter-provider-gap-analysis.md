# OpenRouter Provider Requirements — Gap Analysis vs teale-node

_Generated 2026-04-18 against `taylorhou/openrouter-supply` branch._

## Methodology

Requirements pulled from OpenRouter's public docs, primarily `https://openrouter.ai/docs/guides/get-started/for-providers` (the "for providers" guide), with cross-references from `/docs/guides/routing/provider-selection`, `/docs/guides/features/zdr`, `/docs/guides/privacy/provider-logging`, `/docs/guides/features/tool-calling`, `/docs/guides/features/structured-outputs`, `/docs/api/reference/streaming`, `/docs/guides/best-practices/uptime-optimization`, `/docs/guides/best-practices/latency-and-performance`, and the application form (`https://openrouter.ai/how-to-list` → Notion page). Every quoted phrase comes from those pages; bullets that I had to infer are flagged **(inferred)**.

Each requirement is scored against the teale-node codebase at `/Users/thou48/conductor/workspaces/teale-node/los-angeles-v1`. Status meanings:

- **DONE** — implemented and reachable today.
- **PARTIAL** — implemented for the supply node but missing the OpenRouter-facing surface.
- **MISSING** — no code exists for this.
- **UNCLEAR** — OpenRouter does not specify a numeric/qualitative threshold and we need to ask.

The planned `gateway.teale.com` service from `/Users/thou48/.claude/plans/system-instruction-you-are-working-adaptive-kay.md` is treated as **not built**. Anything that lives only in that plan is MISSING.

## Summary table

| # | Requirement (source) | Status | Where in code today | Effort to close |
|---|---|---|---|---|
| 1 | OpenAI-compatible `/v1/chat/completions` endpoint exposed to OpenRouter | MISSING | N/A — only WebSocket inbound (`src/relay.rs:153`); the OpenAI-shaped request schema exists in `src/cluster.rs:90-101` but only inside relayed `inferenceRequest` payloads | 2–4 weeks (gateway service) |
| 2 | `/v1/models` (or equivalent) "List Models Endpoint" returning `id`, `name`, `created`, `input_modalities`, `output_modalities`, `context_length`, `max_output_length`, `pricing` (prompt, completion, image, request, input_cache_read), optionally `description`, `deprecation_date`, `datacenters` | MISSING | N/A — node only advertises a single `loadedModels` string list (`src/hardware.rs:33`, `src/main.rs:230`); no pricing, no context_length, no modalities | 1–2 weeks once we pick the catalog |
| 3 | SSE streaming (`data: {...}\n\n`, `data: [DONE]`, keep-alive comments like `: OPENROUTER PROCESSING`) | PARTIAL | Supply node already consumes SSE from llama-server (`src/inference.rs:91-127`) and re-emits chunks as `inferenceChunk` ClusterMessages (`src/cluster.rs:188-206`). What is missing is re-serialising those chunks as outbound SSE on a public HTTPS endpoint. | 2–3 days inside the gateway |
| 4 | "Stream tokens as soon as they're available" | PARTIAL | llama-server flush is fine, but the relay path adds two encode/decode hops (`src/cluster.rs:188`, `src/relay.rs:289-300`). Need TTFT measurement before claiming this. | days (instrumentation), weeks (optimisation if needed) |
| 5 | "Return early 429s if under load, rather than queueing requests" | MISSING | Backend has no concurrency limit, no queue, no 429 path (`src/inference.rs:64`); a busy node just blocks the request. `heartbeat` advertises `queueDepth` but it's hard-coded to 0 (`src/cluster.rs:158`). | 1 week (queue + 429 + real queueDepth wiring) |
| 6 | For reasoning models: "send SSE comments as keep-alives so we know you're still working on the request" | MISSING | No keep-alive emission anywhere on the SSE path. | days (gateway-side timer that emits `: keepalive`) |
| 7 | Tool / function calling — schema `{type:"function", function:{name, description, parameters}}` with the OpenAI-style request/response cycle | MISSING | `ChatCompletionRequest` (`src/cluster.rs:90-101`) has no `tools` / `tool_choice` / `tool_calls` fields; `ApiMessage` (`src/cluster.rs:103-107`) only carries `role` + `content` (string, not parts), so `tool_call_id` and assistant `tool_calls` are dropped. | 1 week to plumb fields end-to-end + verify llama-server tool support per model |
| 8 | Structured outputs / JSON mode (`response_format`, JSON Schema) | MISSING | Not in `ChatCompletionRequest`; not advertised. | days once tools land — same plumbing problem |
| 9 | Vision / multimodal inputs (declared via `input_modalities`) | MISSING | `ApiMessage.content` is a `String`, not OpenAI's content-parts array, so image_url parts can't be carried. llama-server multimodal needs separate llama-mtmd/mllama backend. | 2+ weeks — can be deferred (we can ship text-only first) |
| 10 | `supported_parameters` per endpoint — list of which sampling params (`temperature`, `top_p`, `top_k`, `min_p`, `top_a`, `frequency_penalty`, `presence_penalty`, `repetition_penalty`, `stop`, `seed`, `max_tokens`, `logit_bias`) we support so OpenRouter's `require_parameters: true` works | PARTIAL | `ChatCompletionRequest` has 7 of 12 (`temperature`, `top_p`, `max_tokens`, `stream`, `stop`, `presence_penalty`, `frequency_penalty` at `src/cluster.rs:91-101`). Missing: `top_k`, `min_p`, `top_a`, `repetition_penalty`, `seed`, `logit_bias`. Even the present ones aren't declared in any models-list response. | days (add fields + declare them in the models endpoint) |
| 11 | `quantization` declared per endpoint (one of `int4`, `int8`, `fp4`, `fp6`, `fp8`, `fp16`, `bf16`, `fp32`, `unknown`) | MISSING | Quant is implicit in the GGUF filename (`unsloth/...-Q4_K_M.gguf`); not parsed, not declared. | days (parse from filename / config + emit) |
| 12 | "Features" advertised per endpoint: `tools`, `json_mode`, `structured_outputs`, `logprobs`, `web_search`, `reasoning` | MISSING | Nothing emitted today. Must wait on requirements 7–8 to be honest. | days once 7–8 land |
| 13 | "100+ requests required before uptime calculation begins" — i.e. the node has to actually receive traffic | (informational) | N/A | N/A |
| 14 | 95%+ uptime for normal routing; 80–94% degraded; <80% fallback-only ("successful requests ÷ total requests") | UNCLEAR for fleet, MISSING for gateway | Per-node availability is `is_available` boolean (`src/hardware.rs:37`) and the heartbeat loop (`src/cluster.rs:149-162`); but uptime as OpenRouter measures it is at the **endpoint** layer and we don't have one. With a fleet this depends on (a) gateway reliability, (b) failover correctness. **Plan 3c lists the failover design but it's not built.** | weeks — needs gateway + failover + dashboards |
| 15 | Latency / TTFT — "Stream tokens as soon as they're available", OpenRouter publishes per-endpoint latency and uses it for Auto Exacto routing | UNCLEAR threshold, MISSING measurement | No TTFT/throughput metrics emitted anywhere. Hardware proxies exist (`memoryBandwidthGBs` at `src/hardware.rs:18`) but no wall-clock measurement. | days (instrumentation) + ongoing tuning |
| 16 | Payment: "auto top up or invoicing" — provider must be able to receive automated payments from OpenRouter | MISSING | No billing/payouts at all in this repo. Lives outside teale-node entirely. | weeks (corporate setup, banking, invoicing) |
| 17 | Authentication: OpenRouter must be able to authenticate to our endpoint | MISSING | No auth on the inbound side because there is no inbound HTTP side. Outbound auth to llama-server is unauthenticated localhost. | days inside gateway (bearer token check on `/v1`) |
| 18 | TLS for inbound traffic from OpenRouter | MISSING | Outbound TLS is fine (`Cargo.toml:9,16` use `rustls-tls`). Inbound TLS does not exist because there's no inbound HTTP server. | days once gateway exists (terminate at gateway or LB) |
| 19 | Data policy / retention disclosure (training-on-prompts, retention window, geo) — OpenRouter exposes per-provider data policies in the UI and routes around them. ZDR endpoints must "not store your data for any period of time" beyond in-memory caching. | UNCLEAR (we need to commit + document) | No prompt logging anywhere in the relayed path (`src/cluster.rs:179-219` doesn't write request/response to disk). llama-server logs may persist depending on its flags. | days to write the policy + ensure no logs are persisted; weeks if we want a formal "ZDR-eligible" attestation |
| 20 | `id` namespace conformance — "anthropic/claude-sonnet-4" style `<vendor>/<model>` IDs OpenRouter recognises (so users can route to us by the same id they already use) | PARTIAL | We pass through whatever string llama-server reports (`src/inference.rs:35`, `src/cluster.rs:312-316` of LiteRT). Our existing nodes use values like `Qwen/Qwen3-8B-GGUF` — close but not identical to OpenRouter's `qwen/qwen3-8b`. Need a normalisation layer. | days — table in `.context/openrouter-open-weight-catalog.md` already lists OpenRouter IDs |
| 21 | Pricing model — strings in USD, supports up to 2 tiers via `min_context` thresholds, with `prompt`, `completion`, `image`, `request`, `input_cache_read` rates | MISSING | No pricing data anywhere in the codebase. | days once we pick numbers; the numbers themselves are a business decision |
| 22 | Onboarding: "fill out our form" at `https://openrouter.ai/how-to-list` (redirects to a Notion application form) | MISSING (action item) | N/A | hours — fill the form |
| 23 | Contact / company info on the application form | MISSING (action item) | N/A | hours |
| 24 | Reliability — automatic failover when a node dies mid-stream **(inferred from "we route based on … error rates")** | MISSING | Single attempt today; on `inferenceError` (`src/cluster.rs:208-217`) the supply node just emits the error back to the requester. No retry. Plan 3c lists this. | 1 week inside gateway |
| 25 | Rate-limiting / abuse protection on the public endpoint **(inferred — every public LLM API has this)** | MISSING | N/A | days inside gateway (per-key + global) |
| 26 | Stable model availability — once we list a model, traffic will be routed to it; we must not silently change behaviour. **(inferred from how OpenRouter publishes per-endpoint stats)** | PARTIAL | Each node pins a single model at boot via config (`src/config.rs:25-76`). The plan introduces `loadedModels` + `swappableModels` + `loadModel` ClusterMessage but none of that exists yet. | weeks — full model-swap protocol per Plan 3b |
| 27 | Downtime communication / status page **(inferred — providers in OpenRouter's UI link to a status page)** | MISSING | No status page, no incident comms. | days (statuspage.io or equivalent) |
| 28 | Logging that we *can* surface to OpenRouter's "Activity"/"Generations" so they can debug failed requests **(inferred from `/api/api-reference/generations/get-generation` and OpenRouter's debugging story)** | MISSING | No request log persisted. | days inside gateway |
| 29 | Support contact / on-call channel for OpenRouter to reach us when we break **(inferred — every B2B provider needs this)** | MISSING (action item) | N/A | hours |

29 requirements: **0 DONE / 5 PARTIAL / 19 MISSING / 5 UNCLEAR**.
(Three rows are tagged "action item" — they're trivially closeable by filling a form, not engineering work.)

---

## Per-requirement detail

### 1. OpenAI-compatible `/v1/chat/completions` endpoint
- **OpenRouter asks:** OpenRouter's docs centre on the OpenAI-shaped request/response (`messages`, `model`, `stream`, etc. — `https://openrouter.ai/docs/guides/community/openai-sdk`). Providers that don't expose this surface can't be routed to.
- **Today:** We accept inference requests **only** over the relay WebSocket as `inferenceRequest` ClusterMessages (`src/cluster.rs:164-167`, `src/main.rs:188-189`). The OpenAI request schema is mirrored inside that envelope (`ChatCompletionRequest` at `src/cluster.rs:90-101`), but no public HTTP listener exists in the binary — `Cargo.toml` has no axum/actix/warp/hyper-server dependency.
- **Gap:** Need a public HTTPS service that accepts OpenAI-style requests, dispatches them across the fleet, and streams back SSE.
- **Plan:** This is exactly Plan 3a (`gateway.teale.com`). Marked planned-but-not-built.

### 2. List Models Endpoint
- **OpenRouter asks:** _"You must implement an endpoint that returns all models that should be served by OpenRouter."_ Required fields per model: `id`, `name`, `created`, `input_modalities`, `output_modalities`, `context_length`, `max_output_length`, `pricing` (prompt, completion, image, request, input_cache_read). Pricing values are strings in USD; up to two tiers via `min_context`.
- **Today:** Each node advertises one string in `loadedModels` (`src/hardware.rs:33`, populated from `model_id` in `src/main.rs:97/106-118`). No pricing, no `context_length`, no `max_output_length`, no modalities, no `created` timestamp.
- **Gap:** Build the catalog (mostly already enumerated in `.context/openrouter-open-weight-catalog.md`) and serve it from the gateway. Pricing has to be a business decision before this can ship.
- **Plan:** Not in the gateway plan as a separate work item. **New scope.**

### 3. SSE streaming format
- **OpenRouter asks:** SSE with `data: {...}\n\n`-style frames, terminated by `data: [DONE]`. Comments like `: OPENROUTER PROCESSING` may be sent to keep connections alive and clients should ignore them.
- **Today:** `InferenceProxy::stream_completion` (`src/inference.rs:64-127`) reads SSE from llama-server and parses chunks. `handle_inference_request` (`src/cluster.rs:179-219`) re-encodes them inside `inferenceChunk` ClusterMessages. There is no code that writes SSE *outwards* on a public HTTP endpoint.
- **Gap:** Gateway has to translate `inferenceChunk` → SSE on the OpenRouter-facing socket.
- **Plan:** Implicit in Plan 3a but not called out as its own task.

### 4. Token-flush latency
- **OpenRouter asks:** _"Stream tokens as soon as they're available."_
- **Today:** llama-server flushes per token. The relay round-trip adds: `data` base64 encode (`src/relay.rs:289-300`), JSON re-serialise on the far side, possibly Noise encryption, then base64 again on the gateway → SSE. Each hop is fast individually but un-measured.
- **Gap:** Add TTFT/throughput measurement; profile relay overhead.
- **Plan:** Not specifically scoped.

### 5. Early 429s on overload
- **OpenRouter asks:** _"Return early 429s if under load, rather than queueing requests."_
- **Today:** No queue, no concurrency cap. `handle_inference_request` calls `inference.stream_completion` directly (`src/cluster.rs:188`), which posts straight to llama-server. `queueDepth` in heartbeat is hard-coded to `0` (`src/cluster.rs:158`).
- **Gap:** Need both per-node concurrency limit (returns "node busy" cluster error) **and** gateway-level 429 emission.
- **Plan:** Not in 3a–3d.

### 6. Reasoning-model keep-alives
- **OpenRouter asks:** _"send SSE comments as keep-alives so we know you're still working on the request"_ for reasoning models that may pause.
- **Today:** Nothing emits SSE comments.
- **Gap:** Trivial timer in the gateway SSE writer.

### 7. Tool / function calling
- **OpenRouter asks:** OpenAI-compatible tool format `{type:"function", function:{name, description, parameters}}`; provider must accept `tools`/`tool_choice` on requests and emit `tool_calls` on responses. Standardised across providers.
- **Today:** `ChatCompletionRequest` (`src/cluster.rs:90-101`) carries no tool fields. `ApiMessage` (`src/cluster.rs:103-107`) is `{role, content: String}` — there is no slot for `tool_calls` on assistant messages or `tool_call_id` on tool responses, so even passing through llama-server's tool output would lose data.
- **Gap:** Wire `tools`, `tool_choice`, `tool_calls`, `tool_call_id` end to end. Confirm each declared model's chat template actually supports tools (Qwen3, Llama 3.1, Mistral-Small ≥3.1, gpt-oss do; Gemma 2 does not).
- **Plan:** Not mentioned in adaptive-kay plan.

### 8. Structured outputs / JSON mode
- **OpenRouter asks:** `response_format: {type: "json_object"}` and `response_format: {type: "json_schema", schema: ...}` per OpenAI's spec; declared per endpoint via the `json_mode` / `structured_outputs` features.
- **Today:** Not in `ChatCompletionRequest`. llama-server has GBNF-grammar/JSON-mode flags but we don't pipe them.
- **Gap:** Same plumbing fix as #7.

### 9. Multimodal input
- **OpenRouter asks:** Endpoints declare `input_modalities` (`text`, `image`, `file`). To support `image`, the request must accept OpenAI-style content parts (`{type:"image_url", image_url:{url}}` or `{type:"input_image", ...}`).
- **Today:** `ApiMessage.content: String` (`src/cluster.rs:106`). llama-server vision support requires the multimodal binary + mmproj. Neither plumbed.
- **Gap:** Significant — schema change + runtime + per-model switching. Recommend launching text-only.

### 10. supported_parameters declaration
- **OpenRouter asks:** Per-endpoint `supported_parameters` list. Valid values listed in the docs: `temperature`, `top_p`, `top_k`, `min_p`, `top_a`, `frequency_penalty`, `presence_penalty`, `repetition_penalty`, `stop`, `seed`, `max_tokens`, `logit_bias`. Users can set `require_parameters: true` and we get filtered out if we don't support a requested one.
- **Today:** `ChatCompletionRequest` has 7 of 12 (see `src/cluster.rs:91-101`). Missing: `top_k`, `min_p`, `top_a`, `repetition_penalty`, `seed`, `logit_bias`. We also don't *declare* the supported set anywhere because there's no models endpoint.
- **Gap:** Add the missing fields and pass through to llama-server (which supports all of them); declare on the gateway.

### 11. Quantization declaration
- **OpenRouter asks:** Each endpoint can declare a quantization from `int4`, `int8`, `fp4`, `fp6`, `fp8`, `fp16`, `bf16`, `fp32`, `unknown`.
- **Today:** Implicit in the GGUF filename (e.g. `Qwen3-8B-Q4_K_M.gguf`). Not parsed, not surfaced.
- **Gap:** Map `Q4_K_M` → `int4`, `Q5_K_M`/`Q6_K` → `int4`-ish (or `unknown` to be honest), `Q8_0` → `int8`, etc. Declare in the models response.

### 12. Feature flags
- **OpenRouter asks:** Endpoint declares which of `tools`, `json_mode`, `structured_outputs`, `logprobs`, `web_search`, `reasoning` it supports.
- **Today:** Nothing.
- **Gap:** Honest answer right now is "none." Will improve as #7 and #8 land. `web_search` is OpenRouter-side; `reasoning` is per-model (gpt-oss, deepseek-r1, qwen3-thinking).

### 13. Minimum 100 requests for uptime measurement
- **OpenRouter asks:** _"Minimum data: 100+ requests required before uptime calculation begins."_
- **Today:** Informational — no work to do, just budget for a quiet ramp-up window where we have no rating yet.

### 14. Uptime threshold (95%+/80–94%/<80%)
- **OpenRouter asks:** Uptime = `successful requests ÷ total requests`. ≥95% = normal; 80–94% = degraded; <80% = fallback-only.
- **Today:** Per-node `is_available` flag (`src/hardware.rs:37`) and heartbeat acks (`src/cluster.rs:149-162`). Per-endpoint uptime, as OpenRouter measures it, is a function of (a) the gateway being up, (b) at least one fleet node serving each declared model, (c) failover correctness. None of those exist.
- **Gap:** Gateway uptime + per-model fleet-floor + the failover logic (Plan 3c).
- **Plan:** Plan 3c describes this; not built.

### 15. Latency / throughput
- **OpenRouter asks:** OpenRouter publishes TTFT and tokens/sec per endpoint and uses them in Auto Exacto routing; latency-sort routing exposes it directly. No specific minimum threshold is published.
- **Today:** No measurement code. Hardware capabilities advertise `memoryBandwidthGBs` (`src/hardware.rs:18`) which is a *predictor* of throughput, not a measurement.
- **Gap:** Instrument TTFT, total latency, tokens generated; expose via gateway logs.

### 16. Payment: auto top-up or invoicing
- **OpenRouter asks:** _"For OpenRouter to use the provider we must be able to pay for inference automatically. This can be done via auto top up or invoicing."_
- **Today:** Out of scope of this repo entirely.
- **Gap:** Corporate plumbing — bank account, invoicing system, ACH/wire ability. Not engineering on this codebase but blocks the application.

### 17. Authentication on inbound endpoint
- **OpenRouter asks:** Not explicitly quoted in the for-providers page, but OpenRouter has to authenticate to whatever endpoint we expose (per `https://openrouter.ai/docs/guides/community/openai-sdk` they use bearer tokens to all providers).
- **Today:** No inbound HTTP, no auth.
- **Gap:** Bearer-token auth on the gateway, with key rotation. Plan 3a says "Authenticates inbound OpenRouter calls with bearer tokens issued by us" but isn't built.

### 18. TLS on the public surface
- **OpenRouter asks:** Implicitly — they call HTTPS endpoints. **(inferred but obvious.)**
- **Today:** Outbound TLS via `rustls` is configured (`Cargo.toml:9,16`). No inbound TLS because no inbound HTTP server.
- **Gap:** Standard — terminate TLS at the gateway or in front of it (Cloudflare/ALB/Caddy). Use a real cert, HSTS, etc.

### 19. Data retention / training disclosure
- **OpenRouter asks:** Each provider declares its data policy; ZDR providers must "not store your data for any period of time" except in-memory caching, and must not train on user data. Users can restrict routing to ZDR endpoints.
- **Today:** The relayed inference path doesn't persist requests/responses to disk (`src/cluster.rs:179-219`). llama-server defaults may log prompts to stderr (we capture into tracing at `src/inference.rs:166-169` — this is a real ZDR concern). Models are open-weight and we don't train on prompts.
- **Gap:** Decide policy (likely: ZDR-eligible, no training); audit llama-server flags to suppress prompt logs in production; document; submit to OpenRouter for the per-endpoint policy field.

### 20. Model ID namespace
- **OpenRouter asks:** Models use `<vendor>/<model>` IDs that match what OpenRouter already lists (e.g. `qwen/qwen3-8b`). Routing to us only works if we accept the same IDs.
- **Today:** Whatever string llama-server / config returns is shipped through. Existing fixtures in `docs/protocol.md:258` show `Qwen/Qwen3-8B-GGUF` — close but the case and the `-GGUF` suffix don't match OpenRouter's `qwen/qwen3-8b`.
- **Gap:** Normalise IDs in the gateway. Source of truth is `.context/openrouter-open-weight-catalog.md`.

### 21. Pricing
- **OpenRouter asks:** Required pricing fields: `prompt`, `completion`, `image`, `request`, `input_cache_read`. Strings in USD. Two tiers max via `min_context`.
- **Today:** Nothing.
- **Gap:** Business decision (cost-per-token target across the Mac fleet) → static config in the gateway's models response.

### 22. Onboarding form
- **OpenRouter asks:** _"If you'd like to be a model provider and sell inference on OpenRouter, fill out our form to get started."_ Form is at `https://openrouter.ai/how-to-list` → Notion. Page content was not extractable through WebFetch (Notion pages render client-side); see Caveats.
- **Today:** Not submitted.
- **Gap:** Fill the form.

### 23. Contact / company info on the form
- **OpenRouter asks:** Standard application form fields **(inferred from typical Notion application forms — content not extractable)**.
- **Today:** Not submitted.
- **Gap:** Same as #22.

### 24. Failover
- **OpenRouter asks:** Implicitly — _"We track response times, error rates, and availability across all providers in real-time, and route based on this feedback."_ A provider that 5xxs everything just gets routed around. **(inferred standard.)**
- **Today:** No retry. On `inferenceError` the supply node forwards the error to the requester (`src/cluster.rs:208-217`). The relay/cluster has no notion of "another node could serve this."
- **Gap:** Plan 3c describes loaded-model assertion, heartbeat health, thermal awareness, in-flight retry-once, and loaded-model-desync handling — none built.

### 25. Rate limiting on the public endpoint
- **OpenRouter asks:** Not explicitly. **(inferred — required to defend the fleet.)**
- **Today:** N/A.
- **Gap:** Per-key + global RPS limits in the gateway.

### 26. Stable per-endpoint behaviour
- **OpenRouter asks:** Once a model is listed, OpenRouter publishes uptime/latency/price per endpoint and routes to it. We can't silently swap behaviour.
- **Today:** Each node pins one model at boot via TOML config (`src/config.rs:25-76`); the network's set of "models we offer" is the union of every node's `loadedModels` at any instant — which fluctuates as nodes come and go. Plan 3b introduces `swappableModels` + `loadModel` ClusterMessage but not built.
- **Gap:** Per-model fleet floor enforcement — gateway should refuse to advertise a model it can't keep at least N nodes warm for. Implies either a model-swap protocol (Plan 3b) or a static partitioning of the fleet per model.

### 27. Downtime / status communication
- **OpenRouter asks:** **(inferred — providers in OpenRouter's UI typically link to a status page.)**
- **Today:** None.
- **Gap:** statuspage.io or similar; an incident-comms playbook.

### 28. Per-request logging surfaced for debugging
- **OpenRouter asks:** OpenRouter's `/api/api-reference/generations/get-generation` lets users fetch details of a past generation. **(inferred — for that to work we need to log enough to identify generations.)**
- **Today:** No request log persisted.
- **Gap:** Gateway log of `request_id ↔ chosen device, model, latency, outcome` (Plan 3d covers this, not built).

### 29. Support contact / on-call channel
- **OpenRouter asks:** **(inferred — every B2B integration requires a contact channel.)**
- **Today:** None defined.
- **Gap:** Shared inbox + on-call rotation (PagerDuty/OpsGenie/Slack).

---

## "Ready-to-apply" checklist

Top blockers to even submit the application credibly. In priority order:

1. **Stand up the gateway service (`gateway.teale.com`)** with HTTPS, OpenAI-compatible `/v1/chat/completions` (streaming + non-streaming) and `/v1/models`, bearer-token auth. Without this, every other engineering item is moot. (Requirements 1, 2, 3, 17, 18.)
2. **Pricing + payment plumbing.** Pick per-token rates for the catalog, set up invoicing/auto-top-up, give OpenRouter someone to pay. (Requirements 16, 21.)
3. **Per-endpoint model declaration done honestly** — context length, supported parameters, quantization, feature flags (`tools` etc.), modalities, ID matching OpenRouter's catalog. Even if many features are `false`, declaring honestly avoids being penalised by `require_parameters`. (Requirements 2, 10, 11, 12, 20.)
4. **Failover + 429 + queue.** A single dead Mac mid-stream cannot 5xx the user. Need at least one retry on a different node and the ability to reject load early. (Requirements 5, 14, 24.)
5. **TTFT / throughput / outcome instrumentation** end to end, persisted somewhere queryable. We will be measured on these from request 1 onward. (Requirements 4, 15, 28.)
6. **Data policy committed and documented** (recommend ZDR-eligible: no logging of prompts/responses in production, no training). Audit llama-server flags. Submit policy with the application. (Requirement 19.)
7. **Tool/function calling end-to-end** — most coding agents on OpenRouter (Cline, Roo, Claude Code) will not route to us if we don't declare `tools`. (Requirement 7.)

Defer until after approval / first traffic:

- Multimodal / vision (#9).
- Reasoning-model keep-alive comments (#6) — only matters once we list a reasoning model.
- Status page (#27) — manual incident comms is OK to start.
- Model-swap protocol (#26 via Plan 3b) — can ship with statically-partitioned fleet first.

---

## Unknowns / questions for OpenRouter

1. **Numeric SLA expectations.** Docs publish 95%/80% routing tiers but no contractual minimum to *be a provider*. What uptime do you expect day 1? Is there a probation window where low traffic doesn't count against us?
2. **Minimum model catalog.** Is there a floor on the number of models, or can we launch with one (e.g. Qwen3-8B) and add over time?
3. **Latency thresholds.** Do you reject providers below a TTFT/throughput floor for a given model class, or is everything routing-weighted?
4. **Approval criteria** beyond the stated requirements — security review? SOC 2? Reference customers? Insurance?
5. **Rate limit defaults** OpenRouter expects providers to support before falling back to 429.
6. **Pricing tier mechanics.** Two tiers via `min_context` — is that the only tiering supported, or can we also tier on `tools`/`reasoning`?
7. **Quantization labelling for K-quants.** Q4_K_M / Q5_K_M / Q6_K aren't in the listed enum. Do you want us to declare those as `int4` / `unknown`, or is there an extension?
8. **Geographic / data-residency requirements.** EU in-region routing exists for buyers; is there a corresponding obligation on providers (e.g. "EU buyers can't be routed to a US-located Mac")?
9. **Logs API.** What does OpenRouter need from us so the `/generations/{id}` lookup works for a request that landed on us? Do we POST anything back, or is it derived from your routing-side logs only?
10. **The application form itself.** The Notion page at `https://openrouter.ai/how-to-list` did not render through WebFetch (client-side only). What fields does it actually ask for? (Probably best answered by just opening it in a browser.)
11. **Exclusivity / OpenRouter-only ID prefixing.** If we want to ship a model that's not in the public OpenRouter catalog (e.g. a fine-tune), what ID convention do you use?
12. **Reasoning-token billing.** OpenRouter has a `reasoning` feature and reasoning-tokens accounting. Does the provider declare reasoning pricing separately, or is it folded into completion?

---

## Caveats about the source docs

- The `for-providers` page (`https://openrouter.ai/docs/guides/get-started/for-providers`) is the single concrete source for provider-facing requirements, and it is intentionally short. Most numeric thresholds (latency, minimum model count, approval bar) are not specified — hence the five UNCLEAR rows.
- `/docs/use-cases/for-providers` returns 404; the canonical path is `/docs/guides/get-started/for-providers`.
- The application form at `https://openrouter.ai/how-to-list` redirects to a Notion page (`openrouter.notion.site/15a2fd57c4dc8067bc61ecd5263b31fd`). Notion renders client-side, so WebFetch returned no content. We do not know the application form's actual fields. Recommend opening it in a browser before claiming to have a complete picture.
- `/docs/api-reference/streaming` and `/docs/api/reference/streaming` return content via different paths; the streaming format quotes (SSE, `: OPENROUTER PROCESSING`, `data: [DONE]`) are reliable.
- OpenRouter's docs treat "supported parameters" / "feature flags" / "quantization" as user-side filtering primitives; they don't say "you must declare these to be approved", but if we don't, `require_parameters: true` traffic will skip us silently. So they're effectively required for any meaningful share of traffic.
- The plan file (`/Users/thou48/.claude/plans/system-instruction-you-are-working-adaptive-kay.md`) and the open-weight catalog (`.context/openrouter-open-weight-catalog.md`) treat the gateway and the model catalog as **planned but not yet built**. This analysis matches that assumption.

If any of the UNCLEAR rows resolve to a hard threshold during the application call, this analysis should be re-scored — particularly #14 (uptime), #15 (latency floor), and #19 (data policy), since those are where "approve" vs "wait list" probably gets decided.
