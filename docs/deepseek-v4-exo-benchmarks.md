# DeepSeek V4 on 2× 512 GB exo

Use this runbook to decide whether a two-node `M3 Ultra 512 GB` cluster should
serve `DeepSeek-V4-Flash`, `DeepSeek-V4-Pro`, or neither.

The core rule is simple: separate **capacity** from **interactive quality**.
Tensor parallelism can make a model fit, but that does not automatically make
it a good chat or coding endpoint.

## Current stance

- `DeepSeek-V4-Flash` is the realistic first candidate.
  - Current public MLX ports are roughly `151 GB` on disk.
  - It should fit on a single `512 GB` Ultra without cluster sharding.
- `DeepSeek-V4-Pro` is a later candidate.
  - Current public weights are roughly `865 GB`.
  - It requires 2-node sharding on `2× 512 GB`.
  - Promote it only after the current `exo + MLX` runtime proves it can load
    `model_type=deepseek_v4`.
- `Thunderbolt 5 RDMA` is the intended transport for tensor parallelism.
  - `10GbE` is a fallback for fit-driven sharding, not the optimistic TTFT
    path.

## Benchmark matrix

Run these cases in order:

| Case | Why it exists | Promotion rule |
|---|---|---|
| `V4-Flash single-node` | Baseline for Flash without inter-node traffic | Must establish the best warm TTFT control case |
| `V4-Flash 2-node tensor parallel` | Tests whether TP improves prompt/decode enough to justify the network tax | Keep only if warm TTFT and sustained decode are both materially better than single-node |
| `V4-Pro 2-node tensor parallel` | Capacity-only candidate | Keep only if the model loads reliably and stays interactive |

## Acceptance thresholds

Treat a case as `good` only if all of these hold under steady-state load:

- Warm `p95 TTFT <= 5 s`
- Warm decode `p50 >= 15 tok/s`
- No crashes or transport resets over `10` consecutive requests
- Peak resident memory leaves enough headroom to avoid swap or OS pressure

If a case fits but misses the latency bar, classify it as `possible but not
worth serving`.

## How to run

1. Stand up the topology you want to test.
2. Point the benchmark script at the resulting OpenAI-compatible endpoints.
3. Compare `Flash single-node` versus `Flash tensor parallel` before testing
   `Pro`.

Example:

```bash
FLASH_SINGLE_URL=http://127.0.0.1:52415 \
FLASH_SINGLE_MODEL=mlx-community/DeepSeek-V4-Flash-4bit \
FLASH_TP_URL=http://127.0.0.1:52416 \
FLASH_TP_MODEL=mlx-community/DeepSeek-V4-Flash-4bit \
PRO_TP_URL=http://127.0.0.1:52417 \
PRO_TP_MODEL=unsloth/DeepSeek-V4-Pro \
bash scripts/bench-deepseek-v4-exo.sh
```

The script emits:

- `results.jsonl` — one JSON record per request
- `summary.txt` — scan-friendly p50/p95 TTFT and p50 TPS
- `summary.json` — machine-readable aggregate output

## What the script measures

For every enabled case:

- `cold-chat` — one cold interactive request
- `warm-chat` — repeated short interactive requests
- `warm-prefill-8192`
- `warm-prefill-32768`

Each record includes:

- HTTP status
- success/failure
- prompt tokens
- completion tokens
- TTFT
- total latency
- sustained decode tok/s

## Interpretation

- If `Flash tensor parallel` does not beat `Flash single-node`, keep Flash on a
  single 512 GB node and save the second machine for another model.
- If `Pro tensor parallel` loads but cannot hold warm `TTFT <= 5 s`, do not
  expose it as an interactive coding model even if throughput looks acceptable
  once the stream starts.
- If the runtime cannot load `deepseek_v4` at all, stop and keep the cluster on
  the current `DeepSeek V3.x` or `Kimi` path until `exo` and its pinned `MLX`
  stack add clean support.
