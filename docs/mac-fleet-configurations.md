# Mac Fleet Configurations — Research for LLM Supply Side

**Purpose:** Identify which Mac configurations (chip × unified RAM) actually exist in volume, so we know what to optimize our inference fleet for. We are building toward serving open-weight LLM inference on a fleet of Macs as an OpenRouter provider.

**Date of research:** 2026-04-18 (Apple's current lineup: M5 MacBook Air, M5 Pro/Max MacBook Pro, M4 Max / M3 Ultra Mac Studio).

---

## 1. Chip × Bandwidth Table (M1 → M5)

All bandwidth figures are Apple's official peak unified-memory bandwidth. When Apple quotes rounded marketing numbers (e.g. "120 GB/s", "410 GB/s") and Wikipedia has a precise spec-sheet number, the precise number is in parentheses.

| Chip | Year | GPU cores | Peak UMA BW | RAM SKUs offered | Mac products |
|---|---|---|---|---|---|
| **M1** | Nov 2020 | 7 / 8 | **68.3 GB/s** | 8, 16 | MBA, MBP 13", Mac mini, iMac 24" |
| **M1 Pro** | Oct 2021 | 14 / 16 | **204.8 GB/s** | 16, 32 | MBP 14"/16" |
| **M1 Max** | Oct 2021 | 24 / 32 | **409.6 GB/s** | 32, 64 | MBP 14"/16", Mac Studio |
| **M1 Ultra** | Mar 2022 | 48 / 64 | **819.2 GB/s** | 64, 128 | Mac Studio |
| **M2** | Jun 2022 | 8 / 10 | **102.4 GB/s** | 8, 16, 24 | MBA 13"/15", MBP 13", Mac mini |
| **M2 Pro** | Jan 2023 | 16 / 19 | **204.8 GB/s** | 16, 32 | MBP 14"/16", Mac mini |
| **M2 Max** | Jan 2023 | 30 / 38 | **409.6 GB/s** | 32, 64, 96 | MBP 14"/16", Mac Studio |
| **M2 Ultra** | Jun 2023 | 60 / 76 | **819.2 GB/s** | 64, 128, 192 | Mac Studio, Mac Pro |
| **M3** | Oct 2023 | 8 / 10 | **102.4 GB/s** | 8, 16, 24 (iMac/MBP also 36, 64 on 10-core MBP) | MBA 13"/15", MBP 14", iMac 24" |
| **M3 Pro** | Oct 2023 | 14 / 18 | **153.6 GB/s** | 18, 36 | MBP 14"/16" |
| **M3 Max** | Oct 2023 | 30 / 40 | **300 GB/s** (14-core CPU) / **409.6 GB/s** (16-core CPU) | 36, 48, 64, 96, 128 | MBP 14"/16" |
| **M3 Ultra** | Mar 2025 | 60 / 80 | **819 GB/s** | 96, 256, 512 | Mac Studio (2025) |
| **M4** | May 2024 | 8 / 10 | **120 GB/s** | 16, 24, 32 (base raised to 16 Oct 2024) | iMac, Mac mini, MBP 14", MBA (2025) |
| **M4 Pro** | Oct 2024 | 16 / 20 | **273 GB/s** | 24, 48, 64 | Mac mini, MBP 14"/16" |
| **M4 Max** | Oct 2024 | 32 / 40 | **410 GB/s** (32-core GPU) / **546 GB/s** (40-core GPU) | 36, 48, 64, 128 | MBP 14"/16", Mac Studio (2025) |
| **M4 Ultra** | — | — | — | — | **Never released.** Mac Studio 2025 uses M3 Ultra instead; reports say Apple skipped the M4 Ultra. |
| **M5** | Oct 2025 | 8 / 10 | **153 GB/s** | 16, 24, 32 (iPad starts 12) | MBP 14", MBA 13"/15" (2026), iPad Pro, Vision Pro |
| **M5 Pro** | Mar 2026 | 16 / 20 | **307 GB/s** | 24, 48, 64 | MBP 14"/16" (2026) |
| **M5 Max** | Mar 2026 | 32 / 40 | **460 GB/s** (32-core GPU) / **614 GB/s** (40-core GPU) | 36, 48, 64, 128 | MBP 14"/16" (2026) |
| **M5 Ultra** | — | — | — | — | Not yet released as of Apr 2026. |

Sources: [Wikipedia Apple M1](https://en.wikipedia.org/wiki/Apple_M1), [M2](https://en.wikipedia.org/wiki/Apple_M2), [M3](https://en.wikipedia.org/wiki/Apple_M3), [M4](https://en.wikipedia.org/wiki/Apple_M4), [M5](https://en.wikipedia.org/wiki/Apple_M5); [Apple Mac Studio 2025 newsroom](https://www.apple.com/newsroom/2025/03/apple-unveils-new-mac-studio-the-most-powerful-mac-ever/); [Apple MacBook Air M5 newsroom](https://www.apple.com/newsroom/2026/03/apple-introduces-the-new-macbook-air-with-m5/); [Apple MBP M5 Pro/Max newsroom](https://www.apple.com/newsroom/2026/03/apple-debuts-m5-pro-and-m5-max-to-supercharge-the-most-demanding-pro-workflows/).

**Key bandwidth tiers** (this is what dominates LLM token-generation throughput — it's ~linear with bandwidth for memory-bound decoding):

- **~70–150 GB/s** — entry tier (M1 base, M2 base, M3 base, M4 base, M5 base). Anemic for LLMs.
- **~200–310 GB/s** — Pro tier (M1/M2 Pro, M3 Pro, M4 Pro, M5 Pro). Usable for 7B–13B.
- **~400–615 GB/s** — Max tier. Good for 30B–70B.
- **~800+ GB/s** — Ultra tier (M1/M2/M3 Ultra). The only viable tier for 70B+ at interactive speeds. M3 Ultra 512 GB can hold 405B Q4 or 671B DeepSeek Q4.

---

## 2. Popular Configurations in the General Mac Population

### 2a. Mac product mix (unit share)

From [AppleInsider (Mar 2024)](https://appleinsider.com/articles/24/03/06/macbook-pro-and-macbook-air-overwhelmingly-drive-apple-mac-sales) and [MacRumors forum discussion](https://forums.macrumors.com/threads/mac-mini-and-studio-comprise-1-of-mac-sales.2422550/):

- **MacBook Pro:** ~53% of Mac unit sales (2024).
- **MacBook Air:** ~33%.
- **iMac:** ~6%.
- **Mac mini:** ~4–5%.
- **Mac Studio + Mac Pro:** combined **~1–4%**.

Laptops are ~85–90% of all Macs sold.

### 2b. Installed-base by model

From [TelemetryDeck's Mac model share (Mar 2026)](https://telemetrydeck.com/survey/apple/MacOS/models/) — biased toward apps that integrate TelemetryDeck, not a true census, but directional:

| Model | Share |
|---|---|
| MacBook Pro 14" (Nov 2024, M4 Pro/Max) | 13.5% |
| **MacBook Air M1 (2020)** | **13.3%** |
| MacBook Pro 16" (Nov 2024, M4 Pro/Max) | 12.8% |

The M1 Air's persistence in the installed base — five years after launch — tells us the long tail of cheap 8GB Airs is huge and still in active use.

### 2c. RAM SKU mix — best inferences (no hard data)

Apple does not publish per-SKU sales. Based on (a) Apple historically stocking 8GB base configs in retail and making higher RAM build-to-order, (b) BestBuy/retail channel SKUs, and (c) community discussion:

- **MacBook Air:** heavily skewed to **base RAM** (8GB on pre-Oct-2024 Airs, 16GB after). The Air is sold as a commodity laptop; most buyers do not upgrade RAM. **Estimate: ~70–80% of Airs ship at base RAM.**
- **MacBook Pro 14"/16":** mixed. Buyers who choose Pro are already self-selecting for more memory. **Estimate: 40–50% base, 40% mid-tier (32/36/48GB), 10–15% top (64–128GB).**
- **Mac Studio:** strongly skews high. Studio buyers are pros/prosumers who are specifically paying for RAM. **Estimate: base ~30%, mid (64/96GB) ~40%, top (128/192/256/512) ~30%.**
- **Mac mini M4 Pro:** a cult favorite with local-LLM hobbyists because of 64GB-for-$2K pricing. Skews higher RAM than the average mini buyer.

**Data-quality caveat:** the percentages above are **inferences**, not measurements. Apple does not disclose per-SKU sales and no public tracker (IDC, Gartner, Counterpoint) breaks out configurations.

---

## 3. Self-Selected Supply-Side Population

The population willing to volunteer a Mac for overnight LLM inference is **radically different** from the general Mac-buying population.

### Filters that apply

1. **Plugged-in, lid-open (or clamshell), on stable residential fiber.** Ruthlessly favors desktops (Mac mini, iMac, Mac Studio) over laptops. A MacBook Air sitting in a backpack all day is effectively zero supply.
2. **Owned by a developer, ML enthusiast, homelab hobbyist, or prosumer** — the kind of person who follows /r/LocalLLaMA, runs ollama/LM Studio today, is comfortable installing a node agent, and cares enough about open-weight models to donate compute.
3. **RAM ≥ 16GB** functionally required; 32GB+ strongly preferred because a 7–8B Q4 model needs ~5GB and macOS + apps + context eat another 10–20GB. 8GB Macs are effectively out.
4. **Probably has multiple Macs** — the "main" machine may be too busy during the day, but a secondary Mac mini / Studio / older MBP used as a homelab is highly-utilizable.

### Implications for the supply mix

- **Mac Studios are massively over-represented** vs their ~1% general-population share. A Studio Ultra with 128/192/256/512 GB of RAM, 800 GB/s bandwidth, already plugged in 24/7 in a home office is the single best supply node we can hope for. Our expectation: Mac Studios might be 1% of all Macs but **10–25% of our supply-side fleet** because their owners self-select hard into this niche.
- **Mac mini (especially M4 Pro 64GB / M2 Pro 32GB)** is the second big win. $1.5K–$2K, silent, often used as a homelab, and ML-Twitter loves it. Probably **20–30% of the supply fleet.**
- **MacBook Pro 14"/16" Max/Ultra-tier** with 64–128 GB is the next tier. Many are clamshelled into a dock overnight. Probably **25–35% of the supply.**
- **MacBook Air / base-chip / 8–16 GB** — the general-population majority — is **a tiny sliver** of the supply-side fleet, because (a) battery & thermal concerns, (b) people actually carry these around, (c) 16 GB limits you to ~7–8B Q4 models at best.

Evidence that Mac Studio Ultra is where the local-LLM community lives: the [r/LocalLLaMA-style HN thread on Mac Studios for LLMs](https://news.ycombinator.com/item?id=46907001) has users reporting 96/256/512 GB M3 Ultra Studios, 128 GB M1 Ultra, and 192 GB M2 Ultra configurations as default builds.

---

## 4. Top Configs to Optimize For

Ranked by expected share of the **supply-side fleet** (not general Mac population). Shares are estimates, not measurements.

Max model size uses the heuristic **usable RAM ≈ 0.6 × unified RAM** for a dedicated-inference node (OS + leaving VRAM headroom). At Q4_K_M, a model of N billion params takes roughly **N × 0.55 GB**, so max model size ≈ `(0.6 × RAM) / 0.55` billion parameters.

Tokens/sec for 7B Q4 is estimated from bandwidth: a 7B Q4 model is ~4 GB, and token generation is bandwidth-bound at roughly **BW / model_size** t/s. Real-world llama.cpp/MLX numbers roughly match this for decode. Prompt processing is compute-bound and scales with GPU cores; numbers here are **decode** t/s, which is what matters for streaming completions.

| Rank | Config | Est. supply share | Max model @ Q4_K_M | 7B Q4 decode t/s (est.) |
|---|---|---|---|---|
| 1 | **Mac mini M4 Pro, 64 GB** | ~12–15% | ~70B | ~55–65 t/s (273 GB/s) |
| 2 | **MacBook Pro 14"/16" M4 Max, 64 GB** | ~10–13% | ~70B | ~90–120 t/s (410–546 GB/s) |
| 3 | **Mac Studio M2 Ultra, 128 GB** | ~8–10% | ~140B | ~180 t/s (819 GB/s) |
| 4 | **MacBook Pro M1/M2 Max, 32–64 GB** | ~8–10% | 32B–70B | ~85–90 t/s (410 GB/s) |
| 5 | **Mac Studio M1 Ultra, 64–128 GB** | ~7–9% | 70B–140B | ~170–180 t/s (819 GB/s) |
| 6 | **Mac Studio M3 Ultra, 256 GB** | ~5–7% | ~280B | ~180 t/s (819 GB/s) |
| 7 | **Mac mini M2 Pro, 32 GB** | ~5–7% | ~30B | ~45 t/s (204 GB/s) |
| 8 | **MacBook Pro M3/M4 Pro, 36–48 GB** | ~5–7% | 30B–50B | ~55–65 t/s (153–273 GB/s) |
| 9 | **Mac Studio M3 Ultra, 512 GB** | ~2–4% | ~560B (fits 405B Q4, 671B Q4 DeepSeek) | ~180 t/s (819 GB/s) |
| 10 | **Mac Studio M2 Ultra, 192 GB** | ~2–3% | ~210B | ~180 t/s (819 GB/s) |
| — | _all MacBook Airs combined (base chips, 8–24 GB)_ | ~5–8% | 7–13B | ~15–30 t/s |

Sources for decode-rate order of magnitude: [hardware-corner LLM Mac guide](https://www.hardware-corner.net/guides/mac-for-large-language-models/) — reports ~75 t/s 7B Q4 on M1 Ultra, ~94 t/s on M2 Ultra, ~66 t/s on M2 Max 64GB. [llama.cpp 7B benchmark discussion](https://github.com/ggml-org/llama.cpp/discussions/4167) — M4 Max 40-core reaches ~65–105 t/s decode depending on quantization.

**Data-quality caveat:** the supply-share column is a best-guess weighted average of (general Mac mix) × (willingness-to-serve multipliers by archetype). We should treat these as planning priors and update them against real fleet telemetry within the first ~100 nodes.

---

## 5. Implications for Model Catalog

### Model-size brackets vs supply

- **4B–8B (Q4 = 2–5 GB)** — **universal supply.** Any Mac with ≥16 GB RAM can host one. This is the floor tier of our catalog and will have the largest number of available replicas. Target every node that qualifies.
- **13B (Q4 = 7–8 GB)** — **very broad supply.** Any 16–32 GB Mac. Still includes Airs (marginal) and all Pro-tier laptops and minis. Probably covers 80%+ of the supply fleet by node count.
- **30–34B (Q4 = 17–20 GB)** — **broad supply, but needs ≥32 GB.** Excludes the Air long-tail and base-RAM Pros. Pushes us toward Mac mini Pro 32GB+, MBP Pro 36GB+, and everything Max/Ultra. ~50–60% of supply fleet.
- **70–72B (Q4 = 40–42 GB)** — **mid supply.** Needs ≥64 GB RAM to run comfortably (0.6 × 64 = 38.4; tight at 64, comfortable at 96+). Target: M1/M2/M3 Max 64GB MBPs, M4 Pro mini 64GB, all Ultras, M4 Max Studio 64GB+. **Probably ~25–35% of supply-side nodes.** This is the "prosumer sweet spot" tier.
- **110–180B** — **narrow.** Needs ≥128 GB. Mac Studio Ultra 128GB+, MacBook Pro Max 128GB, M4 Max Studio 128GB. **~10–15% of supply.** Decode throughput on Ultras (800+ GB/s) is actually competitive here.
- **405B / 671B (DeepSeek)** — **very narrow.** Needs M3 Ultra 256GB or 512GB Mac Studio, or a paired/sharded multi-node setup. **≤2–4% of supply by node count, but these nodes are disproportionately valuable per unit** because they are the only ones that can serve frontier-sized open weights.

### Routing/catalog takeaways

1. **Have a small 4–8B workhorse tier** (e.g. Llama 3.x 8B, Qwen 3 8B, Gemma 3 4B). Enormous replica count, lowest latency, best for short completions and tool-calling at scale. Most of the fleet can host these.
2. **Make 70B-class the flagship cost-efficient tier** (Llama 3.x 70B, Qwen 2.5/3 72B). Requires ≥64 GB nodes — Ultras, M-Max 64/128 MBPs, M4 Pro 64GB mini. Enough supply to matter, good Ultra-decode speeds (~10–20 t/s for 70B).
3. **Flag Ultra-class (M1/M2/M3 Ultra + M3 Ultra 512) as a distinct routing class** for 100B+ models (Qwen 235B MoE, DeepSeek-V3, Llama 405B, Kimi K2). These are rare nodes, so pricing should reflect scarcity; MoE models especially pair well with Ultra RAM because most parameters are cold.
4. **Explicitly de-optimize for ≤16 GB Airs.** They will self-register but we should route them tiny traffic (4B models, tool-calling, draft decoding) to avoid battery/thermal angering users. A silent 16GB Air is a worse supply node than one Mac Studio.
5. **The Mac mini M4 Pro 64GB is the "reference node"** — it's the most common single config we should benchmark everything against. Cheapest path to 70B-capable, and likely the plurality of new homelab supply over the next 18 months.

---

## Appendix — Known unknowns / data gaps

- Apple does not publish per-SKU (RAM) sales mix. All RAM-mix numbers in Section 2c and 3 are **inferences**, labeled as such.
- TelemetryDeck's installed-base sample is biased toward apps that integrate their SDK — useful as a directional signal, not a census.
- Geekbench's [Mac benchmark browser](https://browser.geekbench.com/mac-benchmarks/) was not directly scraped for submission counts; submission count is also a biased proxy (benchmarkers self-select toward high-end).
- The tokens/sec numbers are first-order bandwidth estimates. Real-world rates depend on quantization format (Q4_K_M vs Q4_0), runtime (llama.cpp vs MLX), context length, and prompt-processing overhead. Treat the decode t/s column as a rough planning figure only.
- M5 Max Studio likely launches later 2026; no M4 Ultra or M5 Ultra exists today. Plans should assume M3 Ultra stays the top tier on the supply side through at least H2 2026.
