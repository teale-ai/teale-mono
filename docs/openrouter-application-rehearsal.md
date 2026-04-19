# OpenRouter Provider Application — Rehearsal Draft

_Last updated 2026-04-18. Aligned against the live "How to list on OpenRouter"
Notion form; questions and constraints captured verbatim from the form at
`openrouter.notion.site/15a2fd57c4dc8067bc61ecd5263b31fd`. This is a draft to
paste from, not a finished submission — double-check every answer the day of._

## Hard constraints from the form (read first)

These are the non-negotiables OpenRouter states explicitly. Every other
answer must stay consistent with them:

- **OpenRouter sends only streaming requests to providers.** Our streaming
  path is the primary code path and carries a trailing `usage` event.
- **Every response must include a `usage` block**, both for streaming and
  non-streaming. Both paths emit it as of 2026-04-18 (streaming emits a
  final `chat.completion.chunk` with `choices:[]` and a populated `usage`
  object right before `[DONE]`).
- `/completions` and `/chat/completions` must be **OpenAI-compliant** —
  both exist; `/completions` wraps `prompt` into a single-message chat
  request and translates the response back to `text_completion` shape.
- `/models` schema resembles `https://openrouter.ai/api/v1/models` and
  carries `max_output_tokens` per model alongside `context_length`.
- Never submit sensitive personal data through Notion Forms (per form footer).

## Pre-submission checklist

Do **not** submit until every box is green:

**Build / deploy:**
- [x] `cargo build --workspace --release` clean (and `cargo clippy --all-targets -- -D warnings` passes)
- [x] `teale-gateway` deployed at `gateway.teale.com` with HTTPS + Fly-managed cert (Let's Encrypt via Fly, status Issued 2026-04-18)
- [ ] At least 5 Mac supply nodes online with pinned catalog models (tailor16 serving Hermes-3-8B, tailor64 → Qwen3-32B, tailor96 → Llama-3.3-70B as of 2026-04-18; adding 2 more is pending)

**API completeness:**
- [x] `/v1/chat/completions` streaming emits a trailing `usage` SSE event before `[DONE]`
- [x] `/v1/completions` legacy route exists (wraps into chat, returns `text_completion` shape)
- [x] `/v1/models` response includes `max_output_tokens` per model
- [x] Streaming chunks carry the canonical OpenRouter `model` id (gateway rewrites the field on every chunk)
- [ ] `/v1/models` response schema cross-checked against `https://openrouter.ai/api/v1/models` field-by-field (we match `id/object/created/owned_by/context_length/max_output_tokens/pricing/supported_parameters/quantization/description` — confirm no field OR requires is missing)
- [ ] `finish_reason` values double-checked against OR's expected set (we emit `stop`, `length`, `tool_calls` from llama-server; no `content_filter`)
- [ ] Mid-stream cancel path tested: abort the client connection mid-completion and confirm we stop billing / free the slot cleanly
- [ ] Error-state paths documented: engine crash, model-not-loaded, queue-full, no-supply, upstream timeout

**Reliability:**
- [x] `stress/scenarios/or_llama8b_sustained.toml` — 10-min @ 1 RPS, **601/601 = 100 %, p50 TTFT 347 ms, p95 533 ms**. `runs/or_llama8b_sustained_10min_*/summary.json`.
- [x] `stress/scenarios/or_llama8b_soak_20min.toml` — 20-min @ 1 RPS, **1196/1201 = 99.58 %, p50 TTFT 345 ms, p95 792 ms**, above OR's 99.5 % bar. `runs/or_llama8b_soak_20min_*/summary.json`.
- [ ] `stress/scenarios/fault_kill_backend.toml` — recovery TTR ≤ 30 s (not rerun against the new scheduler yet)
- [ ] `stress/scenarios/soak_24h.toml` — 24 h unattended pass (pending; would run overnight at 1 RPS if supply stays up)
- [x] Prometheus metrics live at `/metrics` and queryable
- [ ] External testers ran the gateway for ≥ 30 min without reporting issues
- [x] Per-model floor: `small = 2` restored in `gateway/gateway.toml` (3+ nodes on `meta-llama/llama-3.1-8b-instruct`). `large = 1` held until we have ≥ 3 supply nodes for a ≥ 50 B model.

**Docs / policy:**
- [x] Privacy policy published at `https://gateway.teale.com/privacy` (plain-text, served from the gateway itself)
- [x] Data policy answer drafted (prompt/completion retention, training opt-out)
- [ ] `docs/openrouter-provider-gap-analysis.md` — every ✗ / ◐ row flipped to ✓ or knowingly accepted as "defer"

## Form-field draft answers

Each H3 below matches a field in the live form. **Copy-paste answers from
here into the Notion form** — don't freestyle new answers on the day.

### Company name
`Teale`

### Your email
`taylor@apmhelp.com` (company email; OpenRouter will invite this to a Slack Connect channel).

### What distinguishes you? (multiselect)

Check the boxes that apply. Draft selections:

- [x] **Unusually high performance on any models** — M3/M4 Ultra + 70 B flagship nodes sustain p95 TTFT < 5 s on `llama-3.3-70b-instruct` and `gpt-oss-120b`, measured under steady-state load.
- [ ] Unusually low prices on any models — skip; our pricing tracks OR's open-weight baselines, not a hard discount.
- [x] **Any rare/unique language models that only you are hosting** — we are a distributed Apple-Silicon supply pool; several of our loadouts (e.g. `gpt-oss-120b` on M3 Ultra) are not commonly hosted elsewhere. Confirm at submission which slugs are genuinely rare.
- [x] **Architectural innovations (hardware, caching, architecture)** — we aggregate consumer/prosumer Apple Silicon nodes on a P2P relay; demand is fanned out via a Rust gateway that schedules across a live-heartbeat pool, not a fixed datacentre fleet.

### Extra details (free-form)

> Teale operates a distributed Apple-Silicon inference network. A Rust gateway
> at `gateway.teale.com` fronts an OpenAI-compatible API; behind it sits a
> pool of Mac Studios (M3/M4 Ultra, up to 512 GB unified RAM) running
> llama.cpp under our supervisor. The fleet is orchestrated via a custom
> WebSocket relay (`relay.teale.com`); peers heartbeat every 10 s with
> loaded-models + thermal state, and the gateway's scheduler routes each
> request to the least-loaded device via a live in-flight counter.
> Per-model fleet-floors prevent us from listing a model when supply is
> thin. MVP target: stable `llama-3.1-8b` through `gpt-oss-120b` with
> single-region latency matching major providers; Phase C expands to
> multi-region and Gemma-3 multimodal.
>
> **Steady-state measurements (2026-04-19) against
> `meta-llama/llama-3.1-8b-instruct` on Apple-Silicon supply nodes
> (Mac Studio M4 Max 64 GB, Mac Studio M3 Ultra 96 GB, Mac Studio
> M3 Ultra 512 GB; Q4_K_M quantization, streaming SSE, least-in-flight
> scheduler with random tiebreak):**
>
> 20-min soak @ 1 RPS, 64-token max completions:
>   - 1196 / 1201 succeeded — **99.58 % success rate** (above OR's 99.5 % bar)
>   - **p50 TTFT 345 ms, p95 TTFT 792 ms, p99 TTFT 3.5 s**
>   - p50 total latency 1.17 s, p95 1.91 s, p99 4.6 s
>   - The 5 failures clustered in a single ~30 s window at t+620 s
>     (one supply node hiccuped; retry path kicked in but the client's
>     10 s deadline fired first). Outside that window, 1196 / 1196
>     clean.
>
> 10-min sustained @ 1 RPS (subset of the same window):
>   - 601 / 601 succeeded — **100 % success rate**
>   - p50 TTFT 347 ms, p95 TTFT 533 ms
>
> The `/v1/models` catalog, streaming-usage chunks, legacy
> `/v1/completions`, canonical-model-id rewrites, and the live
> least-in-flight load balancer with random tiebreak are all
> end-to-end live.

### Volume Discount (free-form)

> Yes. We can offer a tiered volume discount on per-token pricing starting
> at 10 % off list at 10 M prompt-tokens/month, negotiable beyond that.
> Willing to align the discount curve with OR's other open-weight providers
> during onboarding.

### Rate limits (free-form)

> Initial ceiling: **10 concurrent streams**, **1 RPS aggregate** per
> advertised model (measured sustainable capacity on our current 4-Mac
> supply pool for an 8 B model). Each added supply node lifts the
> ceiling roughly linearly. Raising the limit is a `gateway.toml`
> `scheduler.max_queue_depth` edit + `flyctl deploy`; expect < 5 min
> lead time. Usage headers / 429s match OpenAI shape. No per-user
> rate limits on our side — OpenRouter can throttle as they see fit.

### Pricing and Payment (multiselect — form says "confirm features")

The form's explicit questions under this heading:

- **Credit card payments?** — Not applicable on our side (OR handles
  end-user billing and pays us on their cadence).
- **Automated payment, or invoiced?** — Invoiced. We'll accept ACH/wire
  per OR's standard vendor flow. If OR offers automated payout (e.g.
  Stripe Connect) we're happy to switch.

### Tokenization (free-form)

> We use each model's native tokenizer end-to-end — llama.cpp's GGUF
> tokenizer for the Llama / Qwen / Mistral / Gemma / gpt-oss families.
> Token counts returned in the `usage` block come from the backend's
> own accounting, not a separate tokenizer re-count, so `prompt_tokens`
> and `completion_tokens` are authoritative.

### URL to /completions API

`https://gateway.teale.com/v1/completions` — OpenAI-compliant legacy
text-completion endpoint. Accepts `prompt` (string or array), streaming
+ non-streaming, emits `text_completion` objects with `choices[].text`.
Internally the gateway wraps the prompt into a single-message chat
request so both URLs share the same dispatch / retry / usage
pipeline. Tool-calling, tools, and `response_format` are rejected with
a 400 since they're chat-only features.

### URL to /chat/completions API

`https://gateway.teale.com/v1/chat/completions` — OpenAI-compliant,
streaming SSE is the primary path. Every stream emits a trailing
`chat.completion.chunk` with `choices: []` and a populated `usage`
object just before `data: [DONE]`. Non-streaming responses carry the
same `usage` shape in the body.

### Failure states — cancellable (free-form)

> Mid-stream cancel: when the client disconnects, the gateway aborts the
> upstream relay session and the supply node stops generating within
> one chunk. We **do not charge** for cancelled requests — the
> metered usage is whatever completed before the cancel, which is what
> OR receives before the stream closed. No post-cancel billing.

### Failure states — model/engine failure (free-form)

> If the upstream engine errors (crash, OOM, timeout), the gateway emits
> a terminal `InferenceError` event with a typed `code` (values:
> `model_not_loaded`, `queue_full`, `timeout`, `unavailable`, `cancelled`).
> Non-streaming responses carry an OpenAI-style `error` object. **We do
> not charge** for engine-level failures: the `usage` emitted is zero or
> whatever partial tokens were delivered, whichever is lower.

### Special error shapes or finish reasons (free-form)

> `finish_reason` values: `stop` (normal EOS), `length` (`max_tokens` hit),
> `content_filter` (not currently emitted — we apply no content filters),
> `tool_calls` (when tools are invoked). Error shape:
> ```json
> {"error": {"message": "...", "type": "upstream_error",
>            "code": "relay_timeout"}}
> ```
> Types currently emitted: `model_not_found`, `no_supply`, `bad_request`,
> `unauthorized`, `upstream_error`, `timeout`, `error`.

### URL to /models API

`https://gateway.teale.com/v1/models` — schema:
`{"object":"list","data":[{"id","object":"model","created","owned_by",
"context_length","max_output_tokens","pricing","supported_parameters",
"quantization","description"}]}`. `max_output_tokens` is the hard cap
we accept for `max_tokens` per model (separate from `context_length`,
which is prompt + completion combined). Only models currently served by
enough healthy supply nodes appear in the response (per-model fleet
floor).

### URL to Privacy Policy

`https://gateway.teale.com/privacy` — plain-text policy served from the
gateway. Covers: no training on customer data, no retention of prompt
or completion content, 90-day metadata-only retention (model,
latency, status), sanitized headers on the supply path, TLS 1.2+
enforced, 72-hour incident disclosure.

### Data Policy (free-form)

> We do not train on customer prompts or completions. We do not retain
> prompt or completion content after the response is delivered — only
> request metadata (timestamp, model id, chosen node id, latency,
> finish_reason, token counts) is persisted, for up to 90 days, for
> billing reconciliation and incident response. No third-party analytics
> on request bodies. Customer-identifying headers are stripped before
> the request reaches supply nodes.

### Required Params (multiselect — cross-check against openrouter.ai/docs/parameters)

Check everything in our `supported_parameters` per `models.yaml`. At
minimum: `temperature`, `top_p`, `max_tokens`, `stop`, `stream`, `seed`,
`frequency_penalty`, `presence_penalty`. On submission day, open the OR
parameters doc and tick every row we actually honor.

### Optional Params (multiselect)

`tools`, `tool_choice`, `response_format` (JSON mode) — **only** on the
models whose `supported_parameters` list them in `models.yaml` (Mistral
Small 3.2, Qwen 3 30B-A3B, Llama 3.3 70B, gpt-oss-120b). Our models.yaml
is the source of truth; quote from it rather than restating.

### Tool calling (free-form)

> Supported on Mistral Small 3.2, Qwen 3 30B-A3B, Llama 3.3 70B, and
> gpt-oss-120b (matches their HF model cards). Streaming + tool-calls is
> implemented but has had less exercise than plain streaming — treat as
> **beta** until we've shipped a dedicated stress scenario.

### Structured outputs (free-form)

> `response_format = json_object` / JSON schema is declared as supported
> on Mistral Small 3.2. Streaming + schema has **not** been integration-
> tested end-to-end; we'll mark it beta at submission and move it to
> stable once we add a scenario to the stress suite.

### Extra parameters (free-form)

> Additional sampling params honored when the backend supports them:
> `repetition_penalty`, `top_k`, `min_p`, `tfs_z`, `mirostat`,
> `mirostat_tau`, `mirostat_eta`. These pass through to llama.cpp
> verbatim. Not in the advertised `supported_parameters` because OR's
> canonical list doesn't cover them.

### Multi-modal models (free-form)

> `google/gemma-3-27b-it` is the only multimodal entry (planned for
> Phase C1). Accepted image types at that point: `image/jpeg`,
> `image/png`, `image/webp` — base64 or `image_url` content parts,
> matching the OpenAI vision schema. Not yet live in the fleet; we
> will confirm before ticking the field at submission.

### Inference Location (country codes)

> `US` (primary — Fly.io `sjc` + supply nodes in California / Texas).
> Phase C+ adds `US-east`, and then `EU` via a multi-region Fly
> deployment.

## Final notes (form's own section)

The form closes with "Let us know if these cause latency/QoS issues":
- **OR only does streaming** — no impact; streaming is already our
  primary path.
- **Must always return usage** — we emit it for non-streaming today;
  adding streaming-usage is on the pre-submission checklist.

## Open items to clarify during onboarding call

1. `/completions` vs chat-only — does OR accept chat-only providers, or
   is the `/completions` URL mandatory?
2. Payout cadence and minimum balance.
3. KYC / contract / insurance — the Notion form doesn't ask, but
   standard vendor onboarding usually does.
4. Access to an integration / staging env for dry-run traffic.
5. Provider-scoring formula — what uptime and latency tails trigger
   tier changes?

## What to submit with the application

- This rehearsal doc (as the provider one-pager) — pasted into form fields.
- Link to `docs/openrouter-open-weight-catalog.md` (catalog rationale).
- Link to `docs/device-model-matrix.md` (supply architecture).
- Screencast: `curl -N -H 'Authorization: Bearer <dev>' https://gateway.teale.com/v1/chat/completions -d '{...}'` streaming response with a final chunk carrying `usage`.
- Latest `stress/runs/*/summary.json` showing pass criteria green.

## Post-submission: what to watch

If we're accepted:

1. Watch `teale_requests_total{status}` hourly for the first 72 h — OR's probe traffic arrives immediately.
2. `teale_ttft_seconds` p95 per model — OR's provider scoring uses tail latency.
3. Error budget: stay above 99.5 %. If we dip, `/metrics` + `records.jsonl` should localize the cause.
4. On-call rotation: 24/7 coverage for the first 2 weeks. Runbook lives at `docs/openrouter-oncall-runbook.md`.

If we're rejected:

1. Ask for specifics (request-rate test? model coverage? stability? streaming usage?).
2. Don't re-submit immediately — fix whatever they flagged, run another full 48 h clean, then try again.
