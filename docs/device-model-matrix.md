# Device → Model Matrix (routing source of truth)

_Generated 2026-04-18. Inputs: `openrouter-open-weight-catalog.md` (162 open-weight models filtered by demand) and `mac-fleet-configurations.md` (top-10 supply-side Mac configs)._

This matrix is the source of truth for the gateway's routing decisions and for fleet-side disk pre-population.

## How to read it

For each Mac config row × model column, the cell is one of:

- **D** — `default`. The model is preloaded into RAM at boot. Routing prefers `D` matches first (zero swap latency).
- **S** — `swap-eligible`. Model GGUF is kept on disk. Gateway can issue a `loadModel` ClusterMessage to swap it in (eviction + mmap, ~3–30s depending on size and SSD speed).
- **—** — `unsupported`. Model exceeds 60% of the device's unified RAM budget. Never route here.

Only Q4_K_M sizing is shown; same model at Q5_K_M or Q8_0 needs ~1.2× / ~1.7× the RAM and may demote a cell from S to —.

Throughput estimates (decode tokens/sec) come from `bandwidth ÷ active_weight_size`. MoE models use *active* parameter count for throughput but *total* for the RAM check. Numbers are rounded planning figures; real numbers vary ±25% with quant, runtime, and context length.

## Mac configs in this matrix

| Code | Config | RAM | UMA BW | Headroom (×0.6 RAM) |
|---|---|---|---|---|
| **A** | Mac mini M4 Pro 64 GB | 64 | 273 GB/s | 38 GB |
| **B** | MBP 14"/16" M4 Max 64 GB | 64 | 410–546 GB/s | 38 GB |
| **C** | Mac Studio M2 Ultra 128 GB | 128 | 819 GB/s | 77 GB |
| **D-cfg** | MBP M1/M2 Max 32–64 GB | 32–64 | 410 GB/s | 19–38 GB |
| **E** | Mac Studio M1 Ultra 64–128 GB | 64–128 | 819 GB/s | 38–77 GB |
| **F** | Mac Studio M3 Ultra 256 GB | 256 | 819 GB/s | 154 GB |
| **G** | Mac mini M2 Pro 32 GB | 32 | 204 GB/s | 19 GB |
| **H** | MBP M3/M4 Pro 36–48 GB | 36–48 | 153–273 GB/s | 22–29 GB |
| **I** | Mac Studio M3 Ultra 512 GB | 512 | 819 GB/s | 307 GB |
| **J** | Mac Studio M2 Ultra 192 GB | 192 | 819 GB/s | 115 GB |
| _K_ | _MacBook Air base 8–24 GB (long tail)_ | 8–24 | 68–150 GB/s | 5–14 GB |

(K is excluded from the main matrix — see "Air long tail" section at the bottom.)

## The matrix

Models are grouped by size class. Within each class they share GGUF disk space (you preload one, get the others' weights for free if they share a base — see "shared-base packs" below).

### Tier 0 — small (≤ 5 GB Q4_K_M, fits anywhere with ≥16 GB RAM)

| Model (OR id) | Q4 GB | A 64 | B 64 | C 128 | D 32–64 | E 64–128 | F 256 | G 32 | H 36–48 | I 512 | J 192 |
|---|---:|:-:|:-:|:-:|:-:|:-:|:-:|:-:|:-:|:-:|:-:|
| `meta-llama/llama-3.1-8b-instruct` | 4.9 | S | S | S | S | S | S | S | S | S | S |
| `qwen/qwen3-8b` | 5.0 | S | S | S | S | S | S | S | S | S | S |
| `google/gemma-3-4b-it` | 2.5 | S | S | S | S | S | S | S | S | S | S |
| `google/gemma-3-12b-it` | 7.3 | S | S | S | S | S | S | S | S | S | S |
| `mistralai/mistral-7b-instruct-v0.3` | 4.4 | S | S | S | S | S | S | S | S | S | S |
| `microsoft/phi-4` | 8.9 | S | S | S | S | S | S | S | S | S | S |
| `qwen/qwen3-4b` | 2.5 | S | S | S | S | S | S | S | S | S | S |
| `meta-llama/llama-3.2-3b-instruct` | 2.0 | S | S | S | S | S | S | S | S | S | S |
| `qwen/qwen3-vl-8b-instruct` | 5.0 | S | S | S | S | S | S | S | S | S | S |
| `meta-llama/llama-guard-3-8b`† | ~5 | S | S | S | S | S | S | S | S | S | S |

† safety classifier — recommend running as a local sidecar on every node for content moderation.

Tokens/sec ballpark for an 8B Q4 (~5 GB):
- A (273 GB/s): ~50 t/s
- B (410–546): ~80–110 t/s
- C/E/F/I/J (819): ~165 t/s
- D (410): ~80 t/s
- G (204): ~40 t/s
- H (153–273): ~30–55 t/s

### Tier 1 — workhorse (10–25 GB Q4_K_M, needs ≥24 GB RAM headroom)

| Model | Q4 GB | A 64 | B 64 | C 128 | D 32–64 | E 64–128 | F 256 | G 32 | H 36–48 | I 512 | J 192 |
|---|---:|:-:|:-:|:-:|:-:|:-:|:-:|:-:|:-:|:-:|:-:|
| `qwen/qwen3-30b-a3b-instruct-2507` (MoE 30B/3B)★ | 18.6 | **D** | **D** | S | S | S | S | S | S | S | S |
| `qwen/qwen3-coder-30b-a3b-instruct` (MoE)★ | 18.6 | S | S | S | S | S | S | S | S | S | S |
| `openai/gpt-oss-20b` (MoE 20B/3.6B) | 11.6 | S | S | S | S | S | S | S | S | S | S |
| `mistralai/mistral-small-3.2-24b-instruct`☆ | 14.3 | S | S | S | S | S | S | S | S | S | S |
| `google/gemma-3-27b-it` (multimodal) | 16.5 | S | S | S | S | S | S | S | S | S | S |
| `qwen/qwen3-32b` | 19.8 | S | S | S | S | S | S | — | S | S | S |
| `qwen/qwq-32b` (reasoning) | 19.9 | S | S | S | S | S | S | — | S | S | S |
| `qwen/qwen-2.5-coder-32b-instruct` | 19.9 | S | S | S | S | S | S | — | S | S | S |
| `deepseek/deepseek-r1-distill-qwen-32b` | 19.9 | S | S | S | S | S | S | — | S | S | S |
| `mistralai/mixtral-8x7b-instruct` (MoE 8x7B) | 28.4 | S | S | S | S (only ≥48) | S | S | — | S (only 48) | S | S |
| `baidu/ernie-4.5-21b-a3b` (MoE 21B/3B) | 13.3 | S | S | S | S | S | S | S | S | S | S |

★ shares weights with `qwen3-coder-30b-a3b-instruct` and `qwen3-30b-a3b-thinking-2507` — load one Qwen-3-30B-A3B GGUF, serve all three OpenRouter slugs.
☆ shares the Mistral-Small-24B base with `mistral-small-3.1-24b-instruct`, `mistral-small-24b-instruct-2501`, `devstral-small`, `cydonia-24b-v4.1` — one disk slot covers 5 slugs.

8B-active throughput ballpark (the active-param count is what gets streamed):
- A (273): ~90 t/s on a 3B-active MoE
- B (410–546): ~140–180 t/s on 3B-active MoE
- C/E/F/I/J (819): ~270 t/s on 3B-active MoE — Qwen3-30B-A3B on an Ultra is the throughput champion

### Tier 2 — flagship 70B class (40–50 GB Q4_K_M, needs ≥64 GB RAM)

| Model | Q4 GB | A 64 | B 64 | C 128 | D 32–64 | E 64–128 | F 256 | G 32 | H 36–48 | I 512 | J 192 |
|---|---:|:-:|:-:|:-:|:-:|:-:|:-:|:-:|:-:|:-:|:-:|
| `meta-llama/llama-3.3-70b-instruct`✦ | 42.5 | S (tight) | **D** | **D** | S (only 64) | **D** | **D** | — | — | **D** | **D** |
| `meta-llama/llama-3.1-70b-instruct` | 42.5 | S (tight) | S | S | S (only 64) | S | S | — | — | S | S |
| `qwen/qwen-2.5-72b-instruct` | 47.4 | — | S (tight) | S | — | S | S | — | — | S | S |
| `nousresearch/hermes-4-70b` | 42.5 | S (tight) | S | S | S (only 64) | S | S | — | — | S | S |
| `nvidia/llama-3.3-nemotron-super-49b-v1.5` | 30.2 | S | S | S | S (only ≥48) | S | S | — | S (only 48) | S | S |
| `deepseek/deepseek-r1-distill-llama-70b` | 42.5 | S (tight) | S | S | S (only 64) | S | S | — | — | S | S |
| `qwen/qwen3-next-80b-a3b-instruct` (MoE 80B/3B) | 48.5 | — | S (tight) | S | — | S | S | — | — | S | S |
| `tencent/hunyuan-a13b-instruct` (MoE 80B/13B) | 49.3 | — | S (tight) | S | — | S | S | — | — | S | S |
| `meta-llama/llama-4-scout` (MoE 17Bx16E, 109B total) | 65.4 | — | — | S | — | S (only 128) | S | — | — | S | S |
| `mistralai/mixtral-8x22b-instruct` (MoE 8x22B) | 85.6 | — | — | S (tight) | — | — | S | — | — | S | S |
| `microsoft/wizardlm-2-8x22b` (Mixtral) | 85.6 | — | — | S (tight) | — | — | S | — | — | S | S |

✦ The single most-asked-for self-hosted model. Make this Default on every config that can hold it.

70B Q4 throughput (~42 GB):
- A (273) — fits but slow: ~6 t/s. Decent for batch, painful for streaming UX.
- B (410–546): ~10–13 t/s. Acceptable streaming.
- C/E/F/I/J (819): ~19 t/s. Good streaming.

### Tier 3 — gpt-oss-120b / glm-4.5-air class (60–80 GB Q4_K_M, needs ≥128 GB RAM)

| Model | Q4 GB | A 64 | B 64 | C 128 | D 32–64 | E 64–128 | F 256 | G 32 | H 36–48 | I 512 | J 192 |
|---|---:|:-:|:-:|:-:|:-:|:-:|:-:|:-:|:-:|:-:|:-:|
| `openai/gpt-oss-120b` (MoE 117B/5.1B) | 62.8 | — | — | **D** | — | S (only 128) | **D** | — | — | **D** | **D** |
| `z-ai/glm-4.5-air` (MoE 106B/12B) | 73.0 | — | — | S (tight) | — | S (only 128) | **D** | — | — | **D** | **D** |
| `prime-intellect/intellect-3` (MoE 106B/12B) | 71.4 | — | — | S | — | S (only 128) | S | — | — | S | S |
| `alpindale/goliath-120b` (dense) | 70.6 | — | — | S | — | S (only 128) | S | — | — | S | S |
| `nousresearch/hermes-3-llama-3.1-70b` | 42.5 | S (tight) | S | S | S | S | S | — | — | S | S |

`gpt-oss-120b` on an Ultra: ~5.1B active × 819 GB/s ≈ ~250 t/s decode, with a 117B-quality model. **This is the single most compelling "flagship-on-one-Mac" combination we have.**

### Tier 4 — frontier (140–250 GB Q4_K_M, needs Ultra-class RAM, often single-Studio territory)

| Model | Q4 GB | A 64 | B 64 | C 128 | D | E | F 256 | G | H | I 512 | J 192 |
|---|---:|:-:|:-:|:-:|:-:|:-:|:-:|:-:|:-:|:-:|:-:|
| `qwen/qwen3-235b-a22b-2507` (MoE 235B/22B) | 142.2 | — | — | — | — | — | **D** | — | — | **D** | S (tight) |
| `qwen/qwen3-235b-a22b-thinking-2507` | 142.2 | — | — | — | — | — | S | — | — | S | S (tight) |
| `qwen/qwen3-235b-a22b` | 142.2 | — | — | — | — | — | S | — | — | S | S (tight) |
| `nvidia/llama-3.1-nemotron-ultra-253b-v1` (dense 253B) | 150.9 | — | — | — | — | — | S | — | — | S | — |
| `deepseek/deepseek-chat-v2.5` (MoE 236B/21B) | 142.5 | — | — | — | — | — | S | — | — | S | S (tight) |
| `qwen/qwen3-coder` (MoE 480B/35B) | 290.1 | — | — | — | — | — | — | — | — | **D** | — |
| `z-ai/glm-4.6` (MoE 355B/32B) | 215.6 | — | — | — | — | — | S | — | — | **D** | — |
| `z-ai/glm-4.5` (MoE 355B/32B) | 216.5 | — | — | — | — | — | S | — | — | S | — |
| `meta-llama/llama-4-maverick` (MoE 17Bx128E, 400B total) | 242.8 | — | — | — | — | — | S | — | — | S | — |

Throughput: 22B-active × 819 GB/s ≈ ~37 t/s for Qwen3-235B-A22B. Excellent for a frontier-quality model.

### Tier 5 — cluster only (>192 GB Q4_K_M, requires multi-node sharding)

| Model | Q4 GB | Notes |
|---|---:|---|
| `meta-llama/llama-3.1-405b-instruct` | 245.7 | dense; fits on F (256) tight, comfortable on I (512) |
| `nousresearch/hermes-4-405b` | 243.1 | dense; same RAM class as 405B |
| `deepseek/deepseek-chat-v3-0324` (MoE 671B/37B) | 404.4 | needs F or I; comfortable on I (512) — single Studio possible |
| `deepseek/deepseek-chat-v3.1` | 405.4 | same |
| `deepseek/deepseek-v3.1-terminus` | 405.4 | same |
| `deepseek/deepseek-r1` | 404.4 | same |
| `deepseek/deepseek-r1-0528` | 404.9 | same |
| `tngtech/deepseek-r1t2-chimera` | 404.9 | same |
| `moonshotai/kimi-k2` (MoE 1T/32B) | 620.8 | requires sharding across multiple Macs (mesh-llm / exo / llama.cpp RPC) |
| `moonshotai/kimi-k2-thinking` | 621.2 | same |
| `baidu/ernie-4.5-300b-a47b` | 180.2 | fits on F or I |

For Tier 5, the F (M3 Ultra 256) and I (M3 Ultra 512) configs are the only single-Mac options. **DeepSeek-V3 family at Q4 fits on a single 512 GB Studio with KV headroom — this is a genuine differentiator.** Anything bigger (Kimi K2, Hermes-4-405B at Q8) needs cluster mode and goes back to the Phase 4 mesh-llm follow-up plan.

## Recommended fleet load-out per config

This is what each device's `teale-node.toml` should declare for `default_model` (loaded at boot) and `swappable_models` (kept on disk). Disk budget is the sum of the GGUF files; size each device's free SSD to ≥1.5× the budget for headroom.

### A — Mac mini M4 Pro 64 GB
- **Default**: `qwen/qwen3-30b-a3b-instruct-2507` (18.6 GB) — best throughput-per-byte.
- **On-disk swap**: `meta-llama/llama-3.3-70b-instruct` (42.5 GB), `meta-llama/llama-3.1-8b-instruct` (4.9 GB), `qwen/qwen3-8b` (5.0 GB), `mistralai/mistral-small-3.2-24b-instruct` (14.3 GB), `google/gemma-3-27b-it` (16.5 GB).
- **Disk budget**: ~102 GB.
- **Notes**: 70B Q4 fits but is slow (~6 t/s); only route 70B here when no Max/Ultra is available.

### B — MBP 14"/16" M4 Max 64 GB
- **Default**: `meta-llama/llama-3.3-70b-instruct` (42.5 GB) — sweet spot for this bandwidth.
- **On-disk swap**: `qwen/qwen3-30b-a3b-instruct-2507` (18.6 GB), `meta-llama/llama-3.1-8b-instruct` (4.9 GB), `qwen/qwen-2.5-72b-instruct` (47.4 GB), `mistralai/mistral-small-3.2-24b-instruct` (14.3 GB), `nousresearch/hermes-4-70b` (42.5 GB).
- **Disk budget**: ~170 GB.

### C — Mac Studio M2 Ultra 128 GB
- **Default**: `openai/gpt-oss-120b` (62.8 GB) — flagship, ~250 t/s decode.
- **On-disk swap**: `meta-llama/llama-3.3-70b-instruct` (42.5 GB), `qwen/qwen3-30b-a3b-instruct-2507` (18.6 GB), `meta-llama/llama-3.1-8b-instruct` (4.9 GB), `mistralai/mixtral-8x7b-instruct` (28.4 GB), `qwen/qwen-2.5-72b-instruct` (47.4 GB).
- **Disk budget**: ~205 GB.

### D — MBP M1/M2 Max 32–64 GB
- **Default (32 GB)**: `qwen/qwen3-30b-a3b-instruct-2507` (18.6 GB).
- **Default (64 GB)**: `meta-llama/llama-3.3-70b-instruct` (42.5 GB).
- **On-disk swap**: `meta-llama/llama-3.1-8b-instruct` (4.9 GB), `mistralai/mistral-small-3.2-24b-instruct` (14.3 GB), `google/gemma-3-27b-it` (16.5 GB).
- **Disk budget (32 GB variant)**: ~55 GB. **(64 GB variant)**: ~80 GB.

### E — Mac Studio M1 Ultra 64–128 GB
- **Default (64 GB)**: `meta-llama/llama-3.3-70b-instruct` (42.5 GB).
- **Default (128 GB)**: `openai/gpt-oss-120b` (62.8 GB).
- **On-disk swap**: same as B for 64 GB; same as C for 128 GB. Add `mistralai/mixtral-8x22b-instruct` (85.6 GB) at 128 GB.
- **Disk budget (128 GB variant)**: ~250 GB.

### F — Mac Studio M3 Ultra 256 GB
- **Default**: `qwen/qwen3-235b-a22b-2507` (142.2 GB) — frontier quality, 22B active = fast.
- **On-disk swap**: `openai/gpt-oss-120b` (62.8 GB), `z-ai/glm-4.5-air` (73.0 GB), `meta-llama/llama-3.3-70b-instruct` (42.5 GB), `qwen/qwen3-30b-a3b-instruct-2507` (18.6 GB), `meta-llama/llama-3.1-8b-instruct` (4.9 GB), `nvidia/llama-3.1-nemotron-ultra-253b-v1` (150.9 GB).
- **Disk budget**: ~495 GB.

### G — Mac mini M2 Pro 32 GB
- **Default**: `qwen/qwen3-30b-a3b-instruct-2507` (18.6 GB).
- **On-disk swap**: `meta-llama/llama-3.1-8b-instruct` (4.9 GB), `qwen/qwen3-8b` (5.0 GB), `mistralai/mistral-small-3.2-24b-instruct` (14.3 GB), `openai/gpt-oss-20b` (11.6 GB), `google/gemma-3-12b-it` (7.3 GB).
- **Disk budget**: ~62 GB.
- **Notes**: This is the smallest config we route nontrivial traffic to. No 32B dense and no 70B.

### H — MBP M3/M4 Pro 36–48 GB
- **Default (36 GB)**: `qwen/qwen3-30b-a3b-instruct-2507` (18.6 GB).
- **Default (48 GB)**: `mistralai/mixtral-8x7b-instruct` (28.4 GB) **or** `qwen/qwen3-32b` (19.8 GB).
- **On-disk swap**: `meta-llama/llama-3.1-8b-instruct` (4.9 GB), `mistralai/mistral-small-3.2-24b-instruct` (14.3 GB), `google/gemma-3-27b-it` (16.5 GB), `nvidia/llama-3.3-nemotron-super-49b-v1.5` (30.2 GB) at 48 GB only.
- **Disk budget**: ~55 GB (36) / ~95 GB (48).

### I — Mac Studio M3 Ultra 512 GB
- **Default**: `deepseek/deepseek-chat-v3.1` (405.4 GB) — single-Mac DeepSeek-V3 is the moat.
- **On-disk swap**: `qwen/qwen3-coder` (290.1 GB), `z-ai/glm-4.6` (215.6 GB), `qwen/qwen3-235b-a22b-2507` (142.2 GB), `meta-llama/llama-3.1-405b-instruct` (245.7 GB), `openai/gpt-oss-120b` (62.8 GB), `meta-llama/llama-3.3-70b-instruct` (42.5 GB), `meta-llama/llama-3.1-8b-instruct` (4.9 GB).
- **Disk budget**: ~1.41 TB. Spec these with a 4 TB internal SSD.
- **Notes**: This config is rare and *uniquely valuable*. Reserve it for Tier 4–5 traffic; route smaller models here only when load-balancing demands.

### J — Mac Studio M2 Ultra 192 GB
- **Default**: `openai/gpt-oss-120b` (62.8 GB).
- **On-disk swap**: `qwen/qwen3-235b-a22b-2507` (142.2 GB), `z-ai/glm-4.5-air` (73.0 GB), `meta-llama/llama-3.3-70b-instruct` (42.5 GB), `qwen/qwen3-30b-a3b-instruct-2507` (18.6 GB), `meta-llama/llama-3.1-8b-instruct` (4.9 GB), `mistralai/mixtral-8x22b-instruct` (85.6 GB).
- **Disk budget**: ~430 GB.
- **Notes**: 192 GB tight on Qwen3-235B Q4 — leave very little KV headroom; consider Q3_K_M instead.

## Air long tail (config K)

8–24 GB MacBook Airs self-register but get routed only the smallest, cheapest traffic. Recommended load-out:
- 8 GB: `meta-llama/llama-3.2-1b-instruct` (0.8 GB) only. Lid open required.
- 16 GB: `meta-llama/llama-3.2-3b-instruct` (2.0 GB) default; swap to `qwen/qwen3-4b` (2.5 GB) or `google/gemma-3-4b-it` (2.5 GB).
- 24 GB: `meta-llama/llama-3.1-8b-instruct` (4.9 GB) default; swap to `qwen/qwen3-8b` (5.0 GB).

Use Air supply for: draft decoding, content classification (Llama-Guard), short tool-calling completions, prefix prefetch. Never route 30B+ here.

## Shared-base packs (disk-saving load-outs)

These slugs share GGUF weights — preload one, advertise multiple:

- **Qwen-3-30B-A3B base** (~18.6 GB): serves `qwen3-30b-a3b-instruct-2507`, `qwen3-coder-30b-a3b-instruct`, `qwen3-30b-a3b-thinking-2507`, `qwen3-30b-a3b`, `tongyi-deepresearch-30b-a3b`.
- **Mistral-Small-24B base** (~14.3 GB): serves `mistral-small-3.2-24b-instruct`, `mistral-small-3.1-24b-instruct`, `mistral-small-24b-instruct-2501`, `devstral-small`, `devstral-small-2505`, `cydonia-24b-v4.1`.
- **Llama-3.x-70B base** (~42.5 GB): serves `llama-3.3-70b-instruct`, `llama-3.1-70b-instruct`, `llama-3-70b-instruct`. Hermes-4-70B / Euryale-70B / Nemotron-70B are *finetunes* — different weights.
- **DeepSeek-V3 base** (~405 GB MoE): one disk slot covers `deepseek-chat-v3-0324`, `deepseek-chat-v3.1`, `deepseek-v3.1-terminus`, `deepseek-r1`, `deepseek-r1-0528`, `deepseek-r1t2-chimera`, `deepseek-prover-v2`, `deepseek-chat`. Massive savings on I-class nodes.

## Routing scoring formula (proposed, for the gateway scheduler)

For each request `(model_id, est_tokens)`:

1. Filter eligible devices: `model_id ∈ device.loadedModels ∪ device.swappableModels`, `device.thermalLevel ∈ {nominal, fair}`, `device.lastHeartbeat < 3× interval`.
2. Score each candidate:
   ```
   score = throughput_tps × (1 − queueDepth / max_queue) × throttleLevel/100
                          × (1.0 if model in loadedModels else 0.3)
   ```
   The 0.3 penalty for swap-eligible-only candidates accounts for cold-load latency (model swap budget ~30s; gateway prefers a warm device unless none exists).
3. Send `inferenceRequest` to argmax. On `inferenceError` or session death, demote the device's score and retry once on the next-best.

## Gaps and TODOs

- **Real benchmarks** — every t/s number in this matrix is bandwidth-derived, not measured. Phase 2's `fleet-benchmarks.csv` is still TODO; a follow-up should run `llama.cpp -p 256 -n 256` across each unique config × top-default-model and replace the estimates here.
- **MoE active-set behavior** — KV cache cost grows with active experts × ctx; need to validate that 235B-A22B at 32K ctx actually fits in 256 GB headroom. Suspect Q3_K_M will be necessary for full ctx on F.
- **Vision models** — Gemma 3, Qwen3-VL series fit into Tier 0/1; gateway needs to advertise modality in `/v1/models` and route image-bearing requests only to vision-capable replicas.
- **`swappableModels` field** — does not exist yet in `NodeCapabilities`. Additive change to `src/hardware.rs`; coordinate with relay-server schema.
- **`loadModel` ClusterMessage** — does not exist yet in `src/cluster.rs`. Need to design swap protocol + timeout/error semantics.
- **Disk pre-population** — installer / first-boot flow needs to fetch the per-config GGUF set from a CDN. Bundling multi-hundred-GB defaults in the installer is impractical; ship the agent first, let it download model files in the background, then mark itself eligible once the defaults are warm.
