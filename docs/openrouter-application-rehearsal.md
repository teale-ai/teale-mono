# OpenRouter Provider Application — Rehearsal Draft

_Last updated 2026-04-18. Generated alongside the MVP build. Final submission
must re-verify every field against the live Notion form at
`openrouter.ai/how-to-list` — the form renders client-side and WebFetch can't
dump it, so this draft is a **skeleton to fill, not a finished submission**._

## Pre-submission checklist

Do **not** submit until every box is green:

- [ ] `cargo build --workspace --release` clean (all crates, zero warnings if possible)
- [x] `teale-gateway` deployed at `gateway.teale.com` with HTTPS + Fly-managed cert (Let's Encrypt via Fly, status Issued 2026-04-18)
- [ ] At least 5 Mac supply nodes online with pinned models covering every entry in `models.yaml`
- [ ] `/v1/models` returns the expected catalog (all models pass per-model fleet floor)
- [ ] `/v1/chat/completions` streaming works end-to-end from an external curl
- [ ] `stress/scenarios/steady_state.toml` — 30 min run clean (success ≥ 99.5 %, p95 TTFT within budget)
- [ ] `stress/scenarios/fault_kill_backend.toml` — recovery TTR ≤ 30 s
- [ ] `stress/scenarios/soak_24h.toml` — 24 h unattended pass
- [ ] Prometheus metrics live at `/metrics` and queryable
- [ ] External testers ran the gateway for ≥ 30 min without reporting issues
- [ ] `.context/openrouter-provider-gap-analysis.md` — every ✗ / ◐ row flipped to ✓ or knowingly accepted as "defer"

## Form field draft answers

These are the answers we expect the form to ask for. Verify each against
the actual form before pasting.

### Company / contact

| Field | Answer |
|---|---|
| Company name | Teale |
| Primary contact | Taylor Hou (taylor@apmhelp.com) |
| Website | https://teale.com |
| GitHub org | https://github.com/teale-ai |

### Endpoint

| Field | Answer |
|---|---|
| OpenAI-compatible base URL | `https://gateway.teale.com/v1` |
| Supports `/v1/chat/completions` | Yes, streaming (SSE) + non-streaming |
| Supports `/v1/models` | Yes |
| Authentication | `Authorization: Bearer <token>` |
| API key issuance | We will issue a dedicated token to OpenRouter; rotation via `fly secrets set`, zero-downtime rolling restart |
| TLS | Fly.io managed cert |
| Status page | `https://gateway.teale.com/health` + `/metrics` |
| Public docs | TODO: publish a short README at docs.teale.com/providers |

### Supported models (catalog)

Copy from `gateway/models.yaml`. As of draft:

1. `meta-llama/llama-3.1-8b-instruct` — 16K ctx, $0.10/$0.20 per 1M
2. `qwen/qwen3-8b` — 40K ctx, $0.10/$0.20
3. `qwen/qwen3-30b-a3b-instruct-2507` — 262K ctx, MoE 30B/3B, $0.50/$1.00
4. `mistralai/mistral-small-3.2-24b-instruct` — 128K ctx, $0.40/$0.80
5. `meta-llama/llama-3.3-70b-instruct` — 65K ctx, $0.80/$1.60
6. `openai/gpt-oss-120b` — 128K ctx, MoE 117B/5.1B, $1.00/$2.00 (Ultra-class supply)
7. `google/gemma-3-27b-it` — 128K ctx, multimodal, $0.40/$0.80 (Phase C)

Phase C1 post-approval: may add `moonshotai/kimi-k2` (Ultra pair cluster).

### Supported parameters

All chat models: `temperature`, `top_p`, `max_tokens`, `stop`, `stream`, `seed`,
`frequency_penalty`, `presence_penalty`. Mistral Small, Qwen 30B-A3B, Llama
70B, and gpt-oss-120b additionally support `tools`, `tool_choice`, and
`response_format` (JSON mode) per their HF model cards.

### Reliability commitments

| Metric | Target |
|---|---|
| Success rate | ≥ 99.5 % (steady-state p95) |
| TTFT p95 | ≤ 2 s for models ≤ 30B; ≤ 5 s for 70B+ |
| Recovery TTR after single-node fault | ≤ 30 s |
| Gateway SPOF | ≥ 2 Fly.io machines always running, same region; multi-region in Phase C+ |
| Max concurrent requests | 2–4 per supply node; 8 on Ultras |
| Scheduled maintenance | Announced 24 h ahead via status page |

### Scale

| Metric | MVP | Phase B | Phase C+ |
|---|---|---|---|
| Supply nodes | 5–7 | 10–15 | 50+ |
| Peak RPS (aggregate) | 2 | 10 | 50+ |
| Peak concurrent streams | 10 | 40 | 200+ |
| Geographic coverage | Single region | Single region + edge | Multi-region |

### Security & data

- TLS 1.2+ only on inbound (Fly enforced)
- No request/response logging by default (only metadata: model, chosen_device, latency, status)
- No user content persisted to disk
- Ed25519-signed node registration; gateway validates relay peer identity
- Gateway token-based auth; tokens loaded from env, rotated via Fly secrets

### Open items to clarify during onboarding call

1. Does OpenRouter issue the bearer token, or do we? (Draft assumes we issue.)
2. What uptime / latency SLA triggers are used for the provider scoring tiers? (Public docs don't publish numeric thresholds.)
3. What's the payout cadence and minimum balance for first payment?
4. Are there KYC / contract / insurance requirements? (The Notion form may cover this — verify before submitting.)
5. Can we test against OR's integration env before going live?

## What to submit with the application

- This rehearsal doc (as the provider one-pager)
- Link to `.context/openrouter-open-weight-catalog.md` (catalog selection rationale)
- Link to `.context/device-model-matrix.md` (supply architecture)
- Screencast: `curl -N -H 'Authorization: Bearer <dev>' https://gateway.teale.com/v1/chat/completions -d '{...}'` streaming response
- Latest `stress/runs/*/summary.json` showing pass criteria green

## Post-submission: what to watch

If we're accepted:

1. Watch `gateway_requests_total{status}` hourly for the first 72 h — OR's probe traffic arrives immediately.
2. `gateway_ttft_seconds` p95 per model — OR's provider scoring uses tail latency.
3. Error budget: stay above 99.5 %. If we dip, `/metrics` + `records.jsonl` should localize the cause.
4. On-call rotation: 24/7 coverage for the first 2 weeks. Runbook lives at `.context/openrouter-oncall-runbook.md`.

If we're rejected:

1. Ask for specifics (request-rate test? model coverage? stability?).
2. Don't re-submit immediately — fix whatever they flagged, run another full 48 h clean, then try again.
