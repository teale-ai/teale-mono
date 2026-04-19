# OpenRouter Provider Application — Rehearsal Draft

_Last updated 2026-04-18. Aligned against the live "How to list on OpenRouter"
Notion form; questions and constraints captured verbatim from the form at
`openrouter.notion.site/15a2fd57c4dc8067bc61ecd5263b31fd`. This is a draft to
paste from, not a finished submission — double-check every answer the day of._

## Hard constraints from the form (read first)

These are the non-negotiables OpenRouter states explicitly. Every other
answer must stay consistent with them:

- **OpenRouter sends only streaming requests to providers.** Our
  non-streaming path exists for internal use but is not what OR will exercise.
- **Every response must include a `usage` block**, both for streaming and
  non-streaming. Today the gateway emits `usage` on non-streaming responses
  but **not** on streaming — this is a pre-submission gap (see checklist).
- `/completions` and `/chat/completions` must be **OpenAI-compliant**.
- `/models` schema should resemble `https://openrouter.ai/api/v1/models`
  and must include **max output tokens per model** alongside `context_length`.
  Our `models.yaml` currently carries `context_length` only — see checklist.
- Never submit sensitive personal data through Notion Forms (per form footer).

## Pre-submission checklist

Do **not** submit until every box is green:

**Build / deploy:**
- [ ] `cargo build --workspace --release` clean
- [x] `teale-gateway` deployed at `gateway.teale.com` with HTTPS + Fly-managed cert (Let's Encrypt via Fly, status Issued 2026-04-18)
- [ ] At least 5 Mac supply nodes online with pinned models covering every entry in `models.yaml`

**API completeness:**
- [ ] `/v1/chat/completions` streaming emits `usage` in the final SSE event (currently only in the non-stream path — must fix for OR)
- [ ] `/v1/completions` route exists (currently only `/v1/chat/completions` — confirm whether OR will accept chat-only before submitting; if not, stub the `/v1/completions` route or note as limitation)
- [ ] `/v1/models` response includes a `max_output_tokens` field per model (add to `models.yaml` + catalog.rs before submitting)
- [ ] `/v1/models` response schema cross-checked against `https://openrouter.ai/api/v1/models` field-by-field
- [ ] Streaming chunks carry the canonical OpenRouter `model` id (today they sometimes pass through the backing GGUF filename)
- [ ] `finish_reason` values documented (only `stop` / `length` emitted today — confirm what OR expects)
- [ ] Mid-stream cancel path tested: abort the client connection mid-completion and confirm we stop charging / free the slot cleanly
- [ ] Error-state paths documented: engine crash, model-not-loaded, queue-full, no-supply, upstream timeout

**Reliability:**
- [ ] `stress/scenarios/steady_state.toml` — 30 min run clean (success ≥ 99.5 %, p95 TTFT within budget)
- [ ] `stress/scenarios/fault_kill_backend.toml` — recovery TTR ≤ 30 s
- [ ] `stress/scenarios/soak_24h.toml` — 24 h unattended pass
- [ ] Prometheus metrics live at `/metrics` and queryable
- [ ] External testers ran the gateway for ≥ 30 min without reporting issues
- [ ] Per-model floor restored to `large = 3, small = 2` in `gateway/gateway.toml` (was lowered to 1/1 during bring-up)

**Docs / policy:**
- [ ] Privacy policy published at a public URL we can paste into the form
- [ ] Data policy answer drafted (prompt/completion retention, training opt-out)
- [ ] `.context/openrouter-provider-gap-analysis.md` — every ✗ / ◐ row flipped to ✓ or knowingly accepted as "defer"

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
> request to the best available device. Per-model fleet-floors prevent us
> from listing a model when supply is thin. MVP target: stable `llama-3.1-8b`
> through `gpt-oss-120b` with single-region latency matching major providers;
> Phase C expands to multi-region and Gemma-3 multimodal.

### Volume Discount (free-form)

> Yes. We can offer a tiered volume discount on per-token pricing starting
> at 10 % off list at 10 M prompt-tokens/month, negotiable beyond that.
> Willing to align the discount curve with OR's other open-weight providers
> during onboarding.

### Rate limits (free-form)

> Initial ceiling: **10 concurrent streams**, **2 RPS aggregate**. Easily
> raised — per-model fleet-floor (currently 3 for ≥ 50 B, 2 for smaller)
> is the true scaling signal; adding a supply node raises the floor for
> the models it advertises. Rate-limit changes are a `gateway.toml` edit
> + `flyctl deploy`; expect < 5 min lead time. Usage headers / 429s match
> OpenAI shape.

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

> `https://gateway.teale.com/v1/completions` — **NOTE (pre-submission):
> this route is not yet implemented.** Today only `/v1/chat/completions`
> is live; OR's form asks for both. Decide before submitting: (a) stub
> `/v1/completions` as a legacy alias, or (b) answer "chat-only" and
> confirm it's acceptable. Most modern providers are chat-only.

### URL to /chat/completions API

`https://gateway.teale.com/v1/chat/completions` — OpenAI-compliant,
streaming SSE (the mode OR will use), `usage` in trailing event (once
the streaming-usage gap is closed — see checklist).

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

`https://gateway.teale.com/v1/models` — schema close to
`openrouter.ai/api/v1/models`: `{"object":"list","data":[{"id",
"object":"model","created","owned_by","context_length","pricing",
"supported_parameters","quantization","description"}]}`. **Pre-submission
gap:** add `max_output_tokens` per entry (OR explicitly requires this);
fix in `gateway/models.yaml` + `catalog.rs` before pointing OR at the
URL.

### URL to Privacy Policy

`https://teale.com/privacy` — **to publish before submission**. Draft
points: no long-term logging of prompts or completions, no training on
customer traffic, metadata-only retention (model, latency, status) for
≤ 90 days, incident disclosure via OR Slack channel.

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
