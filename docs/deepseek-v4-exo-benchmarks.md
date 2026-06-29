# DeepSeek V4 DS4 split benchmark

Use this runbook to compare two single-machine DS4 deployments on separate
`M3 Ultra 512 GB` Mac Studios:

- Machine A: `DeepSeek-V4-Flash` DS4 Q4
- Machine B: `DeepSeek-V4-Pro` DS4 Q2

The goal is to pick the better production Teale supply model. After testing,
move the losing machine to match the winning model.

## Current stance

- `DeepSeek-V4-Flash` is the stability baseline.
  - It should fit comfortably on one `512 GB` Ultra.
  - It is the default candidate for 1M-context DS4 serving.
- `DeepSeek-V4-Pro` is the quality lane.
  - Start with the DS4 `pro-q2-imatrix` GGUF on one `512 GB` Ultra.
  - Promote it only if quality gains justify lower decode speed.
  - Current local smoke tests showed cold/long-prefill TTFT around `110-117 s`,
    so do not make it the default unless that latency is acceptable.
- Do not use the old GLM-5.2 exo path for this test.
  - GLM-5.2 was removed as a paired-cluster target because it was not stable
    enough on the 512 GB machines.

## Benchmark matrix

Run both cases with the same prompts and generation limits:

| Case | Endpoint | Model | Promotion rule |
|---|---|---|---|
| `Flash DS4` | Machine A `ds4-server` | `deepseek-v4-flash` | Must be stable and establish the warm TTFT/decode baseline |
| `Pro DS4` | Machine B `ds4-server` | `deepseek-v4-pro` | Keep only if quality is materially better without unacceptable latency |

## Acceptance thresholds

Treat a case as `good` only if all of these hold under steady-state load:

- Warm `p95 TTFT <= 5 s`
- Warm decode `p50 >= 15 tok/s` for Flash
- Warm decode `p50 >= 8 tok/s` for Pro
- No crashes over `10` consecutive requests
- Peak resident memory leaves enough headroom to avoid swap or OS pressure
- Effective context reported by Teale matches the advertised 1M catalog tier

If Pro has better answers but misses the latency bar, classify it as
`quality fallback`, not the default production model.

## How to run

Start `ds4-server` on each machine, then run the OpenAI-compatible benchmark
against each endpoint.

Example:

```bash
BASE_URL=http://flash-host:11438 \
MODEL=deepseek-v4-flash \
REQUESTS=10 \
MAX_TOKENS=512 \
bash scripts/bench-ds4-openai.sh

BASE_URL=http://pro-host:11438 \
MODEL=deepseek-v4-pro \
REQUESTS=10 \
MAX_TOKENS=512 \
bash scripts/bench-ds4-openai.sh
```

The script emits:

- `results.jsonl` — one JSON record per request
- `summary.json` — median TTFT, total latency, and streamed chunk TPS

## Interpretation

- If Flash is more stable and Pro is not clearly better, run Flash on both
  machines.
- If Pro gives materially better coding/agent answers and stays interactive,
  move the Flash machine to Pro.
- If both are unstable at 1M, retest at lower DS4 context tiers before exposing
  either as the advertised 1M model.
