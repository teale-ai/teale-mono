# Device Earnings Cards — Mac Configs as OpenRouter Inference Supply

_Generated 2026-04-18. Pricing pulled live from `https://openrouter.ai/api/v1/models` and `…/models/<id>/endpoints`. Throughput estimates derived from `mac-fleet-configurations.md` × `device-model-matrix.md`. **All earnings figures are estimates** — see Methodology._

This document maps the OpenRouter open-weight model leaderboard onto every common Mac configuration so a prospective supplier can answer: *"is there demand for the models my Mac can run, and does the realistic earnings number make sense for me?"*

The honest answer for many configs is **no**. We say so where that's the case. The pitch is the truth, not optimism.

---

## Methodology

For each candidate `(config, model)` pair:

```
tokens_per_second   = bandwidth ÷ active_weight_size  (decode-only; bandwidth-derived)
uptime_hours_per_day:
    laptop, plugged-in overnight only       →  6
    laptop, clamshelled to a dock           → 12
    desktop (Mac mini / iMac / Mac Studio)  → 20
utilization_fraction:
    pessimistic                              → 0.05
    central (realistic competitive provider) → 0.25
    optimistic                               → 0.50
tokens_per_day  = tokens_per_second × 3600 × uptime × utilization
gross_$/day     = tokens_per_day / 1e6 × output_$/M
provider_take   = 0.85   (OpenRouter's cut is ~5–15% across tiers; 85% is a central assumption)
net_$/day       = gross_$/day × provider_take
net_$/month     = net_$/day × 30
```

**Output-bound proxy**: consumer chat workloads are heavily output-token-dominated (typically 70–95%), so we use the OR `pricing.completion` figure as a single rate. Real revenue is `0.7 × output_$ + 0.3 × input_$` give-or-take; we ignore input revenue — adds 5–15% upside, not material to the decision.

**Demand**: OpenRouter does not publish per-model token volumes. We use the `top-weekly` rank from the catalog as a *qualitative* proxy: rank 1–50 = "high", 51–150 = "moderate", 151+ = "niche". Competition counts come from the live `/endpoints` API (number of providers currently serving each model + median completion price across them).

**Throughput is bandwidth-derived, not measured.** Real numbers vary ±25% with quant, runtime (llama.cpp vs MLX), and context length. The Phase 2 fleet-benchmarks pass will replace these with measured t/s.

---

## How to read a card

Each card has five parts:

1. **Specs** — chip, RAM, peak unified-memory bandwidth, reference 8B Q4_K_M decode estimate.
2. **Best-paying models you could serve** — top 4–6 candidates ranked by realistic central earnings. Columns:
   - **Model** — OpenRouter slug.
   - **OR $/M out** — what OpenRouter pays providers per million output tokens (rounded to cents-per-M).
   - **Competition** — `# providers / median $/M out` from the live endpoints API. Lower numbers = more pricing power; higher = commoditized race.
   - **Est. t/s** — bandwidth-derived decode throughput on this Mac.
   - **Realistic $/day (central)** — net at 0.25 utilization × the appropriate uptime × 0.85 provider take.
   - **$/mo range** — pessimistic (0.05 util) → central (0.25) → optimistic (0.50).
3. **Realistic monthly earnings range** — bolded one-liner: total net-$/month if the device runs the best-paying mix at central utilization.
4. **Competition reality check** — 2–4 sentences saying whether this config wins, ties, or loses.
5. **On-demand swap** — does the config benefit from keeping multiple GGUFs on disk and swapping?

---

## MacBook Air 16GB (M2 / M3 / M4)

**Specs.** M2 / M3 base = 102 GB/s; M4 base = 120 GB/s. 8B Q4_K_M ~22 t/s decode. Lid-open laptop, plugged in overnight only ⇒ 6h/day uptime assumed.

### Best-paying models you could serve

| Model | OR $/M out | Competition | Est. t/s | Realistic $/day (central) | $/mo (pess → central → opt) |
|---|---:|---|---:|---:|---|
| `qwen/qwen3-8b` | $0.40 | 2 providers, $0.46 median | 22 | $0.04 | $0.24 → $1.21 → $2.42 |
| `thedrummer/rocinante-12b` | $0.43 | 2 providers, $0.50 median | 14 | $0.03 | $0.17 → $0.83 → $1.66 |
| `ibm-granite/granite-4.0-h-micro` | $0.11 | 1 provider, $0.11 | 50 | $0.03 | $0.15 → $0.76 → $1.51 |
| `google/gemma-3-4b-it` | $0.08 | 1 provider, $0.08 | 40 | $0.01 | $0.09 → $0.44 → $0.88 |
| `meta-llama/llama-3.1-8b-instruct` | $0.05 | 8 providers, $0.10 median (race-to-bottom) | 22 | $0.01 | $0.03 → $0.15 → $0.30 |

### Realistic monthly earnings range

**$2 → $4 → $8 net per month** if you serve the top 2–3 candidates at central utilization. **The Air 16GB does not make meaningful money.**

### Competition reality check

This config's pricing-power story is brutal. The largest opportunity (`llama-3.1-8b-instruct`) has 8 providers driving the median below $0.10/M — undercutting that on a battery-constrained laptop with 6h uptime is a losing trade. The only models with thin competition (`qwen3-8b` at 2 providers, `rocinante-12b` at 2) are also models with low absolute demand. **Be honest with yourself: an Air 16GB plugged in nightly is great for the network's geographic redundancy and for tool-calling/draft-decoding traffic, but it is not an income source.** Plug it in if you want to support the project; do not plug it in expecting it to pay your phone bill.

### On-demand swap

Marginal benefit. With ~10 GB of usable RAM after macOS overhead, you can keep 4–6 small GGUFs on disk and swap, but cold-load latency on a single 8 GB model is 2–4s and the throughput floor doesn't change. Stick to one default and one tool-calling sidecar (Llama-Guard-3-8B at $0.03/M output for content moderation).

---

## MacBook Air 8GB (M1 long-tail)

**Specs.** M1 base = 68.3 GB/s, 8 GB unified RAM. ~5 GB usable after macOS. 3B Q4_K_M ~34 t/s; 1B ~85 t/s. Laptop, 6h/day overnight only.

### Best-paying models you could serve

| Model | OR $/M out | Competition | Est. t/s | Realistic $/day (central) | $/mo (pess → central → opt) |
|---|---:|---|---:|---:|---|
| `meta-llama/llama-3.2-1b-instruct` | $0.20 | 1 provider, $0.20 | 85 | $0.08 | $0.47 → $2.34 → $4.68 |
| `meta-llama/llama-3.2-3b-instruct` | $0.34 | 1 provider, $0.34 | 34 | $0.05 | $0.32 → $1.59 → $3.18 |
| `ibm-granite/granite-4.0-h-micro` | $0.11 | 1 provider, $0.11 | 36 | $0.02 | $0.11 → $0.55 → $1.10 |
| `liquid/lfm-2.5-1.2b-instruct` | $0.10 | 0 OR endpoints | 45 | $0.02 | $0.12 → $0.62 → $1.24 |
| `google/gemma-3-4b-it` | $0.08 | 1 provider, $0.08 | 27 | $0.01 | $0.06 → $0.30 → $0.60 |

### Realistic monthly earnings range

**$1 → $4 → $8 net per month**, dominated by Llama-3.2-1B traffic. Honestly, **this config exists to demonstrate the network can swarm cheap traffic at the edge — not to earn**.

### Competition reality check

The 1B/3B tier has thin competition (1 provider on each), which is the only reason any pricing power exists at all. But the absolute demand for sub-3B models on OpenRouter is also small — most consumers asking for "a tiny fast model" go to free Gemma or Llama hosts. The cleanest story for an M1 Air is **draft-decoding and Llama-Guard-3-8B sidecar duty** for the rest of the fleet, where the value is system-level (lowering 70B latency on Ultra nodes) rather than per-token revenue.

### On-demand swap

Not useful. RAM is so tight that one model + KV is your full budget. Pin a single default and don't move it.

---

## MacBook Pro M-Pro 16–32GB (M2/M3/M4 Pro)

**Specs.** M2 Pro = 204 GB/s; M3 Pro = 153 GB/s; M4 Pro = 273 GB/s. Average ~210 GB/s. 8B Q4_K_M ~40 t/s. Laptop assumed clamshelled to a dock ⇒ 12h/day uptime.

### Best-paying models you could serve

| Model | OR $/M out | Competition | Est. t/s | Realistic $/day (central) | $/mo (pess → central → opt) |
|---|---:|---|---:|---:|---|
| `qwen/qwen3-30b-a3b-instruct-2507` (MoE 30B/3B) | $0.30 | 5 providers, $0.30 median | 100 | $0.28 | $1.65 → $8.26 → $16.52 |
| `qwen/qwen3-8b` | $0.40 | 2 providers, $0.46 median | 40 | $0.15 | $0.88 → $4.41 → $8.81 |
| `openai/gpt-oss-20b` (MoE 20B/3.6B) | $0.14 | 12 providers, $0.20 median | 90 | $0.12 | $0.69 → $3.47 → $6.94 |
| `qwen/qwq-32b` | $0.58 | 1 provider, $0.58 | 10 | $0.05 | $0.32 → $1.60 → $3.20 |
| `mistralai/mistral-small-3.2-24b-instruct` | $0.20 | 4 providers, $0.30 median | 14 | $0.03 | $0.15 → $0.77 → $1.54 |

### Realistic monthly earnings range

**$3 → $15 → $30 net per month** running Qwen3-30B-A3B as the primary load with Qwen3-8B and gpt-oss-20b as fillers. The 32GB config lifts the floor because Qwen3-30B-A3B fits; the 16GB config can't load it and earns roughly half.

### Competition reality check

The MoE story (`qwen3-30b-a3b-instruct-2507` at 3B-active) is what makes this config viable — you ship 30B-quality output at 3B speed and the price is reasonable ($0.30/M with only 5 competing providers). `gpt-oss-20b` is already commoditized (12 providers, race-to-bottom) so it's a backup, not a hero. The Pro tier wins by **always loading a small MoE**, never by competing on dense 32B+ models where slow decode kills throughput economics.

### On-demand swap

Useful. With 32GB you can keep ~5 GGUFs on disk (Qwen3-30B-A3B, gpt-oss-20b, Mistral-Small-24B base, Qwen3-8B, Gemma-3-12B) and swap in seconds. Lets you bid on whichever model has the best spot price at any moment.

---

## Mac mini M2 Pro 32GB

**Specs.** 204 GB/s, 32 GB unified RAM. 8B Q4 ~40 t/s; 30B-A3B (3B active) ~110 t/s. Desktop ⇒ 20h/day uptime.

### Best-paying models you could serve

| Model | OR $/M out | Competition | Est. t/s | Realistic $/day (central) | $/mo (pess → central → opt) |
|---|---:|---|---:|---:|---|
| `qwen/qwen3-30b-a3b-instruct-2507` | $0.30 | 5 providers, $0.30 median | 110 | $0.50 | $3.03 → $15.15 → $30.30 |
| `qwen/qwen3-coder-30b-a3b-instruct` | $0.27 | 4 providers, $0.60 median | 110 | $0.45 | $2.73 → $13.63 → $27.27 |
| `openai/gpt-oss-20b` | $0.14 | 12 providers, $0.20 median | 100 | $0.21 | $1.29 → $6.43 → $12.85 |
| `mistralai/mistral-small-3.2-24b-instruct` | $0.20 | 4 providers, $0.30 median | 15 | $0.05 | $0.28 → $1.38 → $2.75 |
| `google/gemma-3-27b-it` | $0.16 | 5 providers, $0.30 median | 13 | $0.03 | $0.19 → $0.95 → $1.91 |

### Realistic monthly earnings range

**$5 → $25 → $50 net per month** running Qwen3-30B-A3B-Instruct as default with the Coder variant swapped in for code traffic.

### Competition reality check

The Mac mini M2 Pro 32GB is the **first config where the math starts to work**: 20h uptime + the Qwen3-30B-A3B MoE running fast enough to be price-competitive. `qwen3-coder-30b-a3b-instruct` has a $0.60 median across 4 providers — the cheapest is at $0.27, and we can sit at $0.27 because we share the GGUF with the Instruct variant (one disk slot, two slugs). This is a real $25/mo machine if you keep it plugged in. Not life-changing, but it pays its electricity (~$3–5/mo) and clears a small surplus.

### On-demand swap

Strongly useful. The Qwen3-30B-A3B family shares one ~18 GB GGUF across Instruct/Coder/Thinking — preload once, advertise three slugs. Add Gemma-3-12B and Mistral-Small-24B as cold standbys.

---

## Mac mini M4 Pro 64GB

**Specs.** 273 GB/s, 64 GB unified RAM. 8B Q4 ~55 t/s; 30B-A3B ~150 t/s; 70B Q4 ~6 t/s (slow). Desktop ⇒ 20h/day. The cult-favorite homelab config.

### Best-paying models you could serve

| Model | OR $/M out | Competition | Est. t/s | Realistic $/day (central) | $/mo (pess → central → opt) |
|---|---:|---|---:|---:|---|
| `qwen/qwen3-30b-a3b-instruct-2507` | $0.30 | 5 providers, $0.30 median | 150 | $0.69 | $4.13 → $20.66 → $41.31 |
| `qwen/qwen3-coder-30b-a3b-instruct` | $0.27 | 4 providers, $0.60 median | 150 | $0.62 | $3.72 → $18.59 → $37.18 |
| `openai/gpt-oss-20b` | $0.14 | 12 providers, $0.20 median | 130 | $0.28 | $1.67 → $8.35 → $16.71 |
| `mistralai/mistral-small-3.2-24b-instruct` | $0.20 | 4 providers, $0.30 median | 19 | $0.06 | $0.35 → $1.74 → $3.49 |
| `qwen/qwen3-32b` | $0.24 | 8 providers, $0.45 median | 14 | $0.05 | $0.31 → $1.54 → $3.08 |
| `meta-llama/llama-3.3-70b-instruct` | $0.32 | 16 providers, $0.72 median | 6 | $0.03 | $0.18 → $0.88 → $1.76 |

### Realistic monthly earnings range

**$10 → $40 → $80 net per month** running Qwen3-30B-A3B as default with the Coder variant for code-tagged traffic and gpt-oss-20b as overflow.

### Competition reality check

This is **the supply-side reference node**, and the math is the cleanest of any sub-Ultra config. 273 GB/s × 3B active params on the Qwen3-30B-A3B MoE = ~150 t/s decode at $0.30/M output, with only 4 other providers in that price band. The 70B-class is technically loadable but the throughput is bad enough (6 t/s) that you'd lose money serving it against the 16 competing providers at $0.32/M. **Stay in MoE-30B land.** Realistic pretax earnings of $30–50/mo make this the first config we'd actually recommend to a hobbyist as "yes, plug it in, it'll cover its own cost and a little more."

### On-demand swap

Strongly useful. Disk budget ~100 GB easily fits the full Qwen3-30B-A3B family + gpt-oss-20b + Mistral-Small-24B base + 70B as a cold spillover. Spec it with a 1–2 TB internal SSD.

---

## MacBook Pro M-Pro 36–48GB (M3/M4 Pro)

**Specs.** M3 Pro = 153 GB/s, M4 Pro = 273 GB/s. RAM 36 or 48 GB. 30B-A3B ~80–150 t/s; 32B dense ~10–14 t/s. Laptop, clamshelled ⇒ 12h/day uptime.

### Best-paying models you could serve

| Model | OR $/M out | Competition | Est. t/s | Realistic $/day (central) | $/mo (pess → central → opt) |
|---|---:|---|---:|---:|---|
| `qwen/qwen3-30b-a3b-instruct-2507` | $0.30 | 5 providers, $0.30 median | 120 | $0.33 | $1.98 → $9.92 → $19.83 |
| `qwen/qwen3-coder-30b-a3b-instruct` | $0.27 | 4 providers, $0.60 median | 120 | $0.30 | $1.79 → $8.93 → $17.85 |
| `mistralai/mixtral-8x7b-instruct` (48GB only) | $0.54 | 1 provider, $0.54 | 50 | $0.25 | $1.49 → $7.43 → $14.86 |
| `nvidia/llama-3.3-nemotron-super-49b-v1.5` (48GB only) | $0.40 | 1 provider, $0.40 | 9 | $0.03 | $0.20 → $0.99 → $1.98 |
| `openai/gpt-oss-20b` | $0.14 | 12 providers, $0.20 median | 100 | $0.13 | $0.77 → $3.86 → $7.71 |

### Realistic monthly earnings range

**$5 → $20 → $40 net per month** for the 36GB; **$10 → $25 → $50** for the 48GB (gains the Mixtral-8x7B and Nemotron-49B options).

### Competition reality check

This config is bandwidth-limited compared to the M-Pro mini equivalents, and uptime is half (clamshelled vs always-on). It still works because the MoE-30B class is profitable everywhere it loads. The 48GB sub-tier earns a small premium because Mixtral-8x7B at $0.54/M with literally 1 other provider is genuine pricing power — but only one provider for a model usually means low absolute demand. **Net: similar shape to the Mac mini M2 Pro card, slightly less revenue because of the laptop uptime penalty.**

### On-demand swap

Useful. 36GB fits Qwen3-30B-A3B + gpt-oss-20b warm; 48GB additionally fits Nemotron-49B Q4 cold for spot bidding.

---

## MacBook Pro M-Max 64GB (M1/M2/M3/M4 Max)

**Specs.** 410–546 GB/s. 8B Q4 ~80–110 t/s; 70B Q4 ~10–13 t/s (acceptable streaming); 30B-A3B ~250 t/s. Laptop, clamshelled ⇒ 12h/day.

### Best-paying models you could serve

| Model | OR $/M out | Competition | Est. t/s | Realistic $/day (central) | $/mo (pess → central → opt) |
|---|---:|---|---:|---:|---|
| `qwen/qwen3-30b-a3b-instruct-2507` | $0.30 | 5 providers, $0.30 median | 250 | $0.69 | $4.13 → $20.66 → $41.31 |
| `qwen/qwen3-coder-30b-a3b-instruct` | $0.27 | 4 providers, $0.60 median | 250 | $0.62 | $3.72 → $18.59 → $37.18 |
| `openai/gpt-oss-20b` | $0.14 | 12 providers, $0.20 median | 200 | $0.26 | $1.54 → $7.71 → $15.42 |
| `nousresearch/hermes-4-70b` | $0.40 | 1 provider, $0.40 | 11 | $0.04 | $0.24 → $1.21 → $2.42 |
| `meta-llama/llama-3.3-70b-instruct` | $0.32 | 16 providers, $0.72 median | 11 | $0.03 | $0.19 → $0.97 → $1.93 |
| `mistralai/mistral-small-3.2-24b-instruct` | $0.20 | 4 providers, $0.30 median | 32 | $0.06 | $0.35 → $1.76 → $3.52 |

### Realistic monthly earnings range

**$15 → $40 → $80 net per month** if you run the MoE-30B family as the default. The 70B class is finally fast enough here (11 t/s) that it's a usable spillover for niche finetune traffic (Hermes-4-70B, Euryale-70B), but those are low-volume.

### Competition reality check

The M-Max 64GB is genuinely competitive on the MoE-30B tier — your 250 t/s on a 3B-active model is faster than a Mac mini M4 Pro, and matches well against many cloud providers at the median price. The 70B story doesn't help much: 16 providers serving Llama-3.3-70B at $0.72 median means you'd need to undercut to ~$0.32 (the cheapest), and at 11 t/s × 12h × 0.25 util you make ~$1/mo from it. Don't chase 70B revenue here. **The pitch for M-Max 64GB: $40/mo from MoE traffic, your machine is also faster on every other workload you do, and you signal-boost the network by hosting Hermes/Euryale finetunes that nobody else does.**

### On-demand swap

Strongly useful. ~38 GB headroom holds Qwen3-30B-A3B + gpt-oss-20b warm with ~7 GB free for an 8B sidecar. Keep 70B + Hermes-4-70B as cold swaps.

---

## Mac Studio M1 Ultra 64–128GB

**Specs.** 819 GB/s (the Ultra-tier inflection). 70B Q4 ~19 t/s; gpt-oss-120b (5.1B active) ~250 t/s; 30B-A3B ~270 t/s. Desktop ⇒ 20h/day.

### Best-paying models you could serve (128 GB variant)

| Model | OR $/M out | Competition | Est. t/s | Realistic $/day (central) | $/mo (pess → central → opt) |
|---|---:|---|---:|---:|---|
| `z-ai/glm-4.5-air` (MoE 106B/12B, 128GB only) | $0.85 | 3 providers, $0.86 median | 110 | $1.43 | $8.58 → $42.92 → $85.85 |
| `qwen/qwen3-30b-a3b-instruct-2507` | $0.30 | 5 providers, $0.30 median | 270 | $1.24 | $7.44 → $37.18 → $74.36 |
| `openai/gpt-oss-120b` (128GB only) | $0.19 | 18 providers, $0.60 median | 250 | $0.73 | $4.36 → $21.80 → $43.61 |
| `nousresearch/hermes-4-70b` | $0.40 | 1 provider, $0.40 | 19 | $0.12 | $0.70 → $3.49 → $6.97 |
| `qwen/qwen-2.5-72b-instruct` | $0.39 | 2 providers, $0.40 median | 17 | $0.10 | $0.61 → $3.04 → $6.07 |
| `meta-llama/llama-3.3-70b-instruct` | $0.32 | 16 providers, $0.72 median | 19 | $0.09 | $0.56 → $2.79 → $5.59 |

### Realistic monthly earnings range

**128GB variant: $25 → $100 → $200 net per month** if you can capture meaningful GLM-4.5-Air traffic. **64GB variant: $15 → $50 → $100** (loses the 120B and the GLM-Air, but keeps the MoE-30B and 70B revenue).

### Competition reality check

The 128GB variant has its first genuine high-margin play: **`z-ai/glm-4.5-air` at $0.85/M output with only 3 other OR providers.** That's a frontier-quality model (competes with Claude-Sonnet on agentic work) at a price 3–5× higher than the commodity 70B tier, with thin competition. `gpt-oss-120b` at 18 providers is a race-to-bottom we won't win, but at $0.19/M and 250 t/s decode it's still a small earner. **The Ultra tier is the first place where `realistic monthly earnings range` clears $50 for a typical owner.**

### On-demand swap

Essential. 128GB lets you keep 1 large default warm + 4–5 mid-size as cold swaps. Disk budget ~250 GB; spec a 2 TB+ SSD.

---

## Mac Studio M2 Ultra 128GB

**Specs.** 819 GB/s, 128 GB. Same Ultra-class throughput as M1 Ultra, slightly newer NPU. Desktop ⇒ 20h/day.

### Best-paying models you could serve

| Model | OR $/M out | Competition | Est. t/s | Realistic $/day (central) | $/mo (pess → central → opt) |
|---|---:|---|---:|---:|---|
| `prime-intellect/intellect-3` (MoE 106B/12B) | $1.10 | 1 provider, $1.10 | 120 | $2.02 | $12.12 → $60.59 → $121.18 |
| `z-ai/glm-4.5-air` | $0.85 | 3 providers, $0.86 median | 120 | $1.56 | $9.36 → $46.82 → $93.64 |
| `qwen/qwen3-30b-a3b-instruct-2507` | $0.30 | 5 providers, $0.30 median | 270 | $1.24 | $7.44 → $37.18 → $74.36 |
| `openai/gpt-oss-120b` | $0.19 | 18 providers, $0.60 median | 270 | $0.78 | $4.71 → $23.55 → $47.10 |
| `meta-llama/llama-3.3-70b-instruct` | $0.32 | 16 providers, $0.72 median | 19 | $0.09 | $0.56 → $2.79 → $5.59 |
| `qwen/qwen-2.5-72b-instruct` | $0.39 | 2 providers, $0.40 median | 17 | $0.10 | $0.61 → $3.04 → $6.07 |

### Realistic monthly earnings range

**$30 → $120 → $250 net per month** with a heavy GLM-4.5-Air / Intellect-3 mix. **This is the first config where the supplier's mental model shifts from "covers electricity" to "small but real side income."**

### Competition reality check

`prime-intellect/intellect-3` is a GLM-4.5-Air finetune at $1.10/M with literally 1 other provider — both competition and demand are unknown, treat as upside not base case. `z-ai/glm-4.5-air` is the realistic anchor: 3 competitors, $0.85/M, frontier-grade quality, 12B-active throughput perfectly matched to Ultra bandwidth. The 120B / 70B classes are commoditized and will fill spare cycles cheaply. **An M2 Ultra 128GB with a serious owner who keeps it warm and accepts queue depth can plausibly clear $100/mo.**

### On-demand swap

Essential. Recommended load-out: GLM-4.5-Air warm (73 GB), Qwen3-30B-A3B warm (18.6 GB), and gpt-oss-120b / 70B / Mixtral-8x7B as cold swaps. ~205 GB disk budget.

---

## Mac Studio M2 Ultra 192GB

**Specs.** 819 GB/s, 192 GB. Headroom 115 GB. Can fit Qwen3-235B-A22B at Q4 (tight). Desktop ⇒ 20h/day.

### Best-paying models you could serve

| Model | OR $/M out | Competition | Est. t/s | Realistic $/day (central) | $/mo (pess → central → opt) |
|---|---:|---|---:|---:|---|
| `mistralai/mixtral-8x22b-instruct` | $6.00 | 1 provider, $6.00 | 25 | $2.29 | $13.77 → $68.85 → $137.70 |
| `z-ai/glm-4.5-air` | $0.85 | 3 providers, $0.86 median | 120 | $1.56 | $9.36 → $46.82 → $93.64 |
| `openai/gpt-oss-120b` | $0.19 | 18 providers, $0.60 median | 270 | $0.78 | $4.71 → $23.55 → $47.10 |
| `qwen/qwen3-235b-a22b-thinking-2507` | $0.60 | 5 providers, $2.30 median | 60 | $0.55 | $3.30 → $16.52 → $33.05 |
| `qwen/qwen3-235b-a22b-2507` | $0.10 | 13 providers, $0.60 median | 60 | $0.09 | $0.55 → $2.75 → $5.51 |

### Realistic monthly earnings range

**$30 → $130 → $260 net per month**. The Mixtral-8x22B at $6/M is a curiosity (1 provider, low absolute demand — likely roleplay specialists) but if any of it lands, it's outsized revenue.

### Competition reality check

192GB is the awkward in-between of the Ultra family — too small for the 256-GB-only 235B-A22B-Instruct *default* slot (would need Q3_K_M) and too much for the 128GB sweet spot. The realistic anchor remains GLM-4.5-Air. The Mixtral-8x22B at $6/M is a "if even 1% lands here" upside — there's only 1 OR provider left because most of the demand has migrated to better 24B-class Mistral models. **Useful if you already own one — don't buy this config specifically for supply.**

### On-demand swap

Essential. Default = gpt-oss-120b (62.8 GB), with Qwen3-235B-A22B (142 GB) and GLM-4.5-Air (73 GB) as cold swaps. Disk ~430 GB; spec 2 TB+.

---

## Mac Studio M3 Ultra 256GB

**Specs.** 819 GB/s, 256 GB unified RAM (headroom 154 GB). Fits Qwen3-235B-A22B at Q4 default and GLM-4.6 at Q3. Desktop ⇒ 20h/day.

### Best-paying models you could serve

| Model | OR $/M out | Competition | Est. t/s | Realistic $/day (central) | $/mo (pess → central → opt) |
|---|---:|---|---:|---:|---|
| `z-ai/glm-4.5-air` | $0.85 | 3 providers, $0.86 median | 120 | $1.56 | $9.36 → $46.82 → $93.64 |
| `openai/gpt-oss-120b` | $0.19 | 18 providers, $0.60 median | 280 | $0.81 | $4.88 → $24.42 → $48.85 |
| `z-ai/glm-4.6` (MoE 355B/32B at Q3) | $1.74 | 5 providers, $2.20 median | 22 | $0.59 | $3.51 → $17.57 → $35.13 |
| `qwen/qwen3-235b-a22b-2507` | $0.10 | 13 providers, $0.60 median | 65 | $0.10 | $0.60 → $2.98 → $5.97 |
| `nvidia/llama-3.1-nemotron-ultra-253b-v1` (dense 253B) | $1.20 | 0 OR endpoints | 6 | $0.11 | $0.66 → $3.30 → $6.60 |
| `meta-llama/llama-3.3-70b-instruct` | $0.32 | 16 providers, $0.72 median | 19 | $0.09 | $0.56 → $2.79 → $5.59 |

### Realistic monthly earnings range

**$30 → $100 → $200 net per month** anchored on GLM-4.5-Air with GLM-4.6 spillover. **Note: Qwen3-235B-A22B-Instruct's $0.10/M output price is collapse-tier — 13 providers competing, race to zero. Stay in the 12B-active GLM-Air lane.**

### Competition reality check

256GB doesn't unlock as much new revenue over 128GB as you'd hope. The Qwen3-235B family it can finally hold has been *aggressively* commoditized on OR ($0.10/M for Instruct, with 13 providers — that's "Google providing it for free as a loss-leader" pricing). GLM-4.6 with 5 providers and $1.74–$2.20/M is the real upside, and its 32B active params at 819 GB/s decode at ~22 t/s — slow but acceptable. **Best for owners who already have one and want to add high-margin 200B+ slugs.**

### On-demand swap

Essential. Disk budget ~495 GB; spec 4 TB internal. Default Qwen3-235B-A22B is debatable — consider GLM-4.5-Air warm + 235B cold given the price collapse.

---

## Mac Studio M3 Ultra 512GB

**Specs.** 819 GB/s, 512 GB (headroom 307 GB). The only single-Mac DeepSeek-V3 host. Desktop ⇒ 20h/day. Rare and disproportionately valuable per node.

### Best-paying models you could serve

| Model | OR $/M out | Competition | Est. t/s | Realistic $/day (central) | $/mo (pess → central → opt) |
|---|---:|---|---:|---:|---|
| `deepseek/deepseek-r1-0528` (MoE 671B/37B) | $2.15 | 5 providers, $2.18 median | 18 | $0.59 | $3.55 → $17.76 → $35.51 |
| `z-ai/glm-4.6` (MoE 355B/32B, full Q4 fits) | $1.74 | 5 providers, $2.20 median | 22 | $0.59 | $3.51 → $17.57 → $35.13 |
| `qwen/qwen3-coder` (MoE 480B/35B) | $1.00 | 10 providers, $1.60 median | 19 | $0.29 | $1.74 → $8.72 → $17.45 |
| `deepseek/deepseek-chat-v3.1` (MoE 671B/37B) | $0.75 | 11 providers, $1.00 median | 18 | $0.21 | $1.24 → $6.20 → $12.40 |
| `openai/gpt-oss-120b` | $0.19 | 18 providers, $0.60 median | 280 | $0.81 | $4.88 → $24.42 → $48.85 |
| `z-ai/glm-4.5-air` | $0.85 | 3 providers, $0.86 median | 120 | $1.56 | $9.36 → $46.82 → $93.64 |
| `qwen/qwen3-235b-a22b-2507` | $0.10 | 13 providers, $0.60 median | 65 | $0.10 | $0.60 → $2.98 → $5.97 |

### Realistic monthly earnings range

**$50 → $150 → $300 net per month** running GLM-4.5-Air warm, DeepSeek-R1-0528 / GLM-4.6 / Qwen3-Coder as rotating cold-swap heroes for high-margin requests. **This is the highest single-node ceiling in the consumer Mac fleet.**

### Competition reality check

The 512GB Studio is the **only single-Mac config that can serve the DeepSeek-V3-class moat models without sharding** — and that scarcity matters. But: DeepSeek-Chat-V3.1 has 11 providers driving the median to $1.00, and DeepSeek-R1-0528 has 5 providers at $2.15. Throughput is the real bottleneck at this tier (18 t/s on a 37B-active model is OK but not fast), so absolute revenue per node is *less* than you'd hope for the price of the machine. **The economic case for buying one specifically for supply is borderline; the case for running one you already own is unambiguous.** Kimi K2 (621 GB Q4) does NOT fit on a single 512 — it requires 2-node mesh-llm sharding, which is a Phase 4 unlock.

### On-demand swap

Essential. Default GLM-4.5-Air warm (73 GB, biggest realistic earner per t/s) + 4 TB SSD holding DeepSeek-V3 base, GLM-4.6, Qwen3-Coder, Llama-405B, Qwen3-235B, gpt-oss-120b. Total disk budget ~1.4 TB.

---

## Fleet economics summary

If we recruited **100 of each top supply config** at the central-utilization estimates above:

| Config | Per-node $/mo (central) | × 100 nodes | Notes |
|---|---:|---:|---|
| Mac Studio M3 Ultra 512GB | $150 | $15,000 | Rare; we'd be lucky to land 10–20. |
| Mac Studio M2 Ultra 192GB | $130 | $13,000 | Also rare. |
| Mac Studio M2 Ultra 128GB | $120 | $12,000 | Achievable target. |
| Mac Studio M3 Ultra 256GB | $100 | $10,000 | Achievable. |
| Mac Studio M1 Ultra 128GB | $100 | $10,000 | Older but plentiful in homelabs. |
| MacBook Pro M-Max 64GB | $40 | $4,000 | Lots of these clamshelled. |
| Mac mini M4 Pro 64GB | $40 | $4,000 | The "reference node" — easiest to recruit. |
| Mac mini M2 Pro 32GB | $25 | $2,500 | Common cult-favorite. |
| MacBook Pro M-Pro 36–48GB | $20 | $2,000 | |
| MacBook Pro M-Pro 16–32GB | $15 | $1,500 | |
| MacBook Air 16GB | $4 | $400 | Token contributors. |
| MacBook Air 8GB | $3 | $300 | System-value role only. |

**Aggregate central-case fleet revenue if we hit 100-node targets across the board: ~$75,000/mo gross supply-side income.** OpenRouter's own gateway take + our gateway margin layer on top.

The realistic fleet shape over the first year: one or two dozen Ultras (the heroes), 50–100 Mac mini / M-Max owners (the workhorses), and a long tail of Air / Pro contributors that exists more for geographic redundancy and PR optics than revenue. Plan economics around the Ultra + mini-Pro tier — that's where 80% of supply-side $ comes from with 20% of the nodes.

---

## Who should actually plug in

**Plug in — the math works:**

- Mac Studio M1/M2/M3 Ultra (any RAM tier ≥64GB) — $50–$300/mo realistic, frontier model coverage, you're a hero of the fleet.
- Mac mini M4 Pro 64GB — $30–$50/mo, covers electricity + small surplus, easiest install path.
- MacBook Pro M-Max 64–128GB clamshelled — $30–$80/mo, doubles as your daily driver.
- Mac mini M2 Pro 32GB — $15–$30/mo, runs Qwen3-30B-A3B beautifully.

**Plug in if you want to support the network — don't expect material income:**

- MacBook Pro M-Pro 16–48GB — $10–$25/mo, a reasonable side amount but won't impress you.
- MacBook Air 16GB plugged in nightly — $2–$8/mo. Useful for redundancy and small-model traffic; not income.

**Don't bother (we love you, but the math doesn't):**

- MacBook Air 8GB M1 — $1–$4/mo. The 6h overnight budget × 1B-class throughput × commodity prices doesn't clear meaningful dollars. We'll route Llama-Guard sidecar traffic to it for system value, but as a personal income story, no.

The honest summary for the pitch: **the Ultra-class Mac Studio is where the fleet's revenue lives. Everything from mini-M4-Pro upward pays for itself. Anything M-Pro and below is a contribution, not a paycheck.**

---

## Data-quality caveats

- **Throughput is bandwidth-derived, not measured.** Real numbers ±25%. Phase 2 fleet benchmarks will replace these.
- **Demand volumes are NOT exposed by OpenRouter.** Rank and # of providers are the only public signal. A model with 1 provider could be a goldmine *or* dead — we can't tell from the API.
- **OR pricing API succeeded for all 343 cataloged models.** No missing prices. `mistralai/mistral-7b-instruct-v0.3` returned 0 endpoints — it's a v1-catalog "router-default" entry that delegates to other providers; treat as `n/a` for competition.
- **`nvidia/llama-3.1-nemotron-ultra-253b-v1` and `meta-llama/llama-3.1-405b-instruct` returned 0 endpoints.** OR has the model registered but no provider currently serves it. We list our own price guess based on similar-sized models — verify before quoting publicly.
- **Provider take of 85% is an assumption.** OpenRouter's actual cut varies by tier and negotiation. If it ends up 75%, scale all earnings by 0.88.
- **Output-only revenue model** ignores 5–15% input-token revenue upside.
- **Uptime assumptions** (laptop 6h / 12h, desktop 20h) are central guesses. A serious laptop owner clamshelling 18h/day shifts numbers up ~50%; a casual owner powering off overnight cuts them ~50%.
