# OpenRouter Open-Weight Model Catalog — Mac Inference Supply

_Generated 2026-04-18. Catalog source: `https://openrouter.ai/api/v1/models` (343 models). Ranking source: `https://openrouter.ai/api/frontend/models/find?order=top-weekly` (680 entries, ordered by past-week activity). GGUF sizes fetched live from Hugging Face._

## Methodology

**Filter**: only *open-weight* families suitable for on-device inference — Llama, Qwen, DeepSeek, Mistral/Mixtral, Gemma (Google's open lineup), Phi, Nous Hermes, GLM 4.x (Z.ai), IBM Granite, gpt-oss (OpenAI's Apache-2.0 release), Kimi K2, OLMo (AllenAI), LFM (LiquidAI), ERNIE 4.5 (Baidu), Hunyuan (Tencent), Nemotron / Llama-Nemotron (NVIDIA), Mamba/SSM families from AI21/Liquid, and popular community finetunes (Sao10K, TheDrummer, Anthracite, Gryphe, etc.).

Excluded: Claude, GPT-4/5/oX (kept only `gpt-oss`), Gemini (Google's closed line), Grok, Cohere Command, MiMo (Xiaomi, API-only), MiniMax, Stepfun, Inception Mercury, Arcee cloud models (Trinity/Maestro/Virtuoso/Coder), Perplexity Sonar, ByteDance-Seed cloud models, Amazon Nova, Mistral's paid-API-only (Mistral Large/Medium/Ministral-Premium, Codestral, Pixtral Large, Voxtral, Mistral-Saba), Qwen cloud-only tiers (Qwen-Max, Qwen-Plus, Qwen-Turbo, Qwen3-Max, Qwen3-Coder-Plus/Flash/Next, Qwen3.5 Flash/Plus, Qwen3.6 Plus), Upstage Solar API, Inflection, Writer Palmyra. Embedding/rerank/image/audio/video models are excluded.

**Ranking**: OpenRouter's `?order=top-weekly` ordering is the best public proxy for demand (no per-token volume is exposed publicly). Rank 1 = highest past-week activity. We include the rank the model held in that ordering; dashes mean the model is in the v1 catalog but was not in the top-weekly list we pulled.

**GGUF sizes**: fetched from Hugging Face repo APIs. Primary sources are `unsloth/`, `bartowski/`, `mradermacher/`, `MaziyarPanahi/`, model-family official orgs (`LiquidAI/`, `Kwaipilot/`, `NousResearch/`). Multi-part GGUFs are summed. Values shown in GB (1 GB = 10^9 bytes, matching how HF reports blob size and how llama.cpp reports on disk). `no GGUF found` = either (a) llama.cpp architecture unsupported (Jamba, Llama-3.2-Vision, some Mamba hybrids), or (b) the canonical community GGUF repo is gated/private and no authenticated fetch is possible in this environment — the model itself is open-weight and can typically be quantized locally. VL/vision variants of dense models frequently only have MLX builds; listed with a note.

**Mac sizing** (`Min RAM` column): heuristic is `model_Q4_K_M / 0.6`, rounded up to the next standard Apple unified-memory SKU (8, 16, 24, 32, 36, 48, 64, 96, 128, 192). 60% is the practical ceiling for a single model under macOS while leaving headroom for the OS, KV cache, Metal buffers, and other apps. `—` means Q4_K_M exceeds 192 GB and requires a multi-Mac cluster (e.g. exo / mesh-llm / llama.cpp RPC).

**Tier** mapping: ≤16 GB = M-base (base M1/M2/M3/M4 Air/iMac/mini); 24–48 GB = M-Pro (M-series Pro + higher-memory bases, MacBook Pro 14"); 64–128 GB = M-Max (MacBook Pro 16" with Max, Mac Studio Max); 192 GB = M-Ultra (Mac Studio Ultra); `cluster (>192)` = needs sharding across 2+ nodes.

**MoE caveat**: for mixture-of-experts (marked `NB-AB` like `30B-A3B`, `106B-A12B`, `671B-A37B`, `17Bx128E`), GGUF size tracks *total* parameters because every expert has to be in RAM; only the active experts run per token, so throughput follows the active count. Kimi K2, DeepSeek V3/R1/Terminus/Prover/Chimera, GLM-4.5 full, Qwen3-235B, Qwen3-Coder-480B, Llama-4-Maverick, ERNIE-300B, ERNIE-VL-424B, and Mixtral-8x22B are all cluster-grade.

**Context**: `Ctx` is what OpenRouter advertises — the provider's upstream context limit, not what our Macs can actually hold. On-device usable context is sharply bounded by KV cache (an 8B model at 32K ctx is already ~2–4 GB depending on quant; 128K can double that). Plan KV budget separately per deployment.

---

## Full catalog

| Rank | OpenRouter ID | Family | Params | Ctx | Q4_K_M GB | Q5_K_M GB | Q8_0 GB | Min RAM | Tier | Notes |
|---|---|---|---|---|---|---|---|---|---|---|
| 5 | xiaomi/mimo-v2-pro | MiMo | N/A | 1.0M | no GGUF found | - | - | — | — | no open weights (API-only) |
| 35 | mistralai/mistral-nemo | Mistral | 12B | 131K | 7.5 | 8.7 | 13.0 | 16 | M-base | dense |
| 39 | qwen/qwen3-235b-a22b-2507 | Qwen | 235B-A22B | 262K | 142.2 | 166.8 | 249.9 | — | cluster (>192) | MoE — 235B weights in RAM, 22B active |
| 41 | z-ai/glm-4.5-air | GLM | 106B-A12B | 131K | 73.0 | 83.5 | 117.5 | 128 | M-Max | MoE 106B/12B active — best "flagship-on-a-workstation" pick |
| 43 | deepseek/deepseek-chat-v3-0324 | DeepSeek | 671B-A37B | 163K | 404.4 | 475.4 | 713.3 | — | cluster (>192) | MoE 671B/37B active |
| 45 | meta-llama/llama-3.1-8b-instruct | Llama | 8B | 16K | 4.9 | 5.7 | 8.5 | 16 | M-base | dense |
| 47 | deepseek/deepseek-chat-v3.1 | DeepSeek | 671B-A37B | 32K | 405.4 | 476.2 | 713.3 | — | cluster (>192) | MoE 671B/37B active |
| 48 | openai/gpt-oss-120b | gpt-oss | 117B-A5.1B | 131K | 62.8 | 62.9 | 63.4 | 128 | M-Max | MoE 117B total, 5.1B active; MXFP4 native; Q4_K_M ~63 GB |
| 63 | mistralai/mistral-small-3.2-24b-instruct | Mistral | 24B | 128K | 14.3 | 16.8 | 25.1 | 24 | M-Pro | dense |
| 77 | meta-llama/llama-4-maverick | Llama | 17Bx128E | 1.0M | 242.8 | 284.5 | 425.8 | — | cluster (>192) | MoE 17B active over 128 experts; 400B total — cluster only |
| 78 | qwen/qwen3-vl-235b-a22b-instruct | Qwen | 235B-A22B | 262K | 142.2 | 166.8 | 249.9 | — | cluster (>192) | MoE VL; 235B total, 22B active |
| 79 | deepseek/deepseek-v3.1-terminus | DeepSeek | 671B-A37B | 163K | 405.4 | 476.2 | 713.3 | — | cluster (>192) | MoE 671B/37B active |
| 80 | deepseek/deepseek-chat | DeepSeek | 671B-A37B | 163K | 404.4 | 475.4 | 713.3 | — | cluster (>192) | MoE 671B/37B active (V3 original) |
| 81 | qwen/qwen3-30b-a3b-instruct-2507 | Qwen | 30B-A3B | 262K | 18.6 | 21.7 | 32.5 | 32 | M-Pro | MoE — 30B weights in RAM, 3B active; best small-MoE workhorse |
| 88 | moonshotai/kimi-k2-0905 | Kimi | 1T-A32B | 262K | 621.2 | 728.7 | 1091.1 | — | cluster (>192) | MoE 1T/32B |
| 90 | deepseek/deepseek-v3.2-exp | DeepSeek | 671B-A37B | 163K | no GGUF found | - | - | — | — | no GGUF; DeepSeek-V3.2-Exp sparse attention variant |
| 93 | meta-llama/llama-3.1-70b-instruct | Llama | 70B | 131K | 42.5 | 49.9 | 75.0 | 96 | M-Max | dense |
| 96 | meta-llama/llama-4-scout | Llama | 17Bx16E | 327K | 65.4 | 76.5 | 114.5 | 128 | M-Max | MoE 17B active over 16 experts; 109B total |
| 99 | qwen/qwen3-8b | Qwen | 8B | 40K | 5.0 | 5.9 | 8.7 | 16 | M-base | dense |
| 102 | qwen/qwen3-32b | Qwen | 32B | 40K | 19.8 | 23.2 | 34.8 | 36 | M-Pro | dense |
| 103 | qwen/qwen3-vl-8b-instruct | Qwen | 8B | 131K | 5.0 | 5.9 | 8.7 | 16 | M-base | vision-language (VL); GGUF + mmproj |
| 105 | moonshotai/kimi-k2-thinking | Kimi | 1T-A32B | 262K | 621.2 | 728.7 | 1091.1 | — | cluster (>192) | MoE 1T/32B reasoning |
| 107 | z-ai/glm-4.6 | GLM | 355B-A32B | 204K | 215.6 | 253.2 | 379.3 | — | cluster (>192) | MoE 355B/32B active; current flagship |
| 109 | deepseek/deepseek-r1-0528 | DeepSeek | 671B-A37B | 163K | 404.9 | 475.8 | 713.3 | — | cluster (>192) | MoE 671B/37B active reasoning (updated) |
| 113 | deepseek/deepseek-r1 | DeepSeek | 671B-A37B | 64K | 404.4 | 475.4 | 713.3 | — | cluster (>192) | MoE 671B/37B active reasoning |
| 118 | openai/gpt-oss-20b | gpt-oss | 20B-A3.6B | 131K | 11.6 | 11.7 | 12.1 | 24 | M-Pro | MoE 20B total, 3.6B active; MXFP4 native; very fast |
| 122 | openai/gpt-oss-safeguard-20b | gpt-oss | 20B-A3.6B | 131K | 11.6 | 11.7 | 12.1 | 24 | M-Pro | safety/moderation variant of gpt-oss-20b |
| 123 | sao10k/l3-lunaris-8b | Llama | 8B | 8K | 4.9 | 5.7 | 8.5 | 16 | M-base | dense |
| 125 | qwen/qwen-2.5-72b-instruct | Qwen | 72B | 32K | 47.4 | 54.4 | 77.3 | 96 | M-Max | dense |
| 128 | qwen/qwen3-vl-30b-a3b-instruct | Qwen | 30B-A3B | 131K | 18.6 | 21.7 | 32.5 | 32 | M-Pro | MoE VL; 30B total, 3B active |
| 134 | qwen/qwen3-235b-a22b-thinking-2507 | Qwen | 235B-A22B | 262K | 142.2 | 166.8 | 249.9 | — | cluster (>192) | MoE reasoning, 235B total |
| 138 | liquid/lfm-2-24b-a2b | LFM | 24B-A2B | 32K | no GGUF found | - | - | — | — | hybrid-SSM MoE 24B/2B; llama.cpp support landing in LiquidAI fork |
| 139 | mistralai/mistral-small-24b-instruct-2501 | Mistral | 24B | 32K | 14.3 | - | 25.1 | 24 | M-Pro | dense |
| 142 | qwen/qwen3-235b-a22b | Qwen | 235B-A22B | 131K | 142.2 | 166.8 | 249.9 | — | cluster (>192) | MoE base release |
| 143 | kwaipilot/kat-coder-pro-v2 | Kwaipilot | 32B | 256K | no GGUF found | - | - | — | — | coder; use Kwaipilot/KAT-Dev-GGUF (KAT-Dev-72B base, gated) |
| 144 | qwen/qwen3-vl-32b-instruct | Qwen | 32B | 131K | 19.8 | 23.2 | 34.8 | 36 | M-Pro | dense VL |
| 145 | qwen/qwen3-coder-30b-a3b-instruct | Qwen | 30B-A3B | 160K | 18.6 | 21.7 | 32.5 | 32 | M-Pro | MoE coder, 30B/3B active |
| 147 | qwen/qwen3-30b-a3b | Qwen | 30B-A3B | 40K | 18.6 | 21.7 | 32.5 | 32 | M-Pro | MoE — 30B weights must all fit in RAM, 3B active per token |
| 148 | moonshotai/kimi-k2 | Kimi | 1T-A32B | 131K | 620.8 | 728.3 | 1091.1 | — | cluster (>192) | MoE 1T total / 32B active — cluster territory |
| 151 | z-ai/glm-4-32b | GLM | 32B | 128K | 19.7 | 23.1 | 34.6 | 36 | M-Pro |  |
| 157 | qwen/qwen-2.5-7b-instruct | Qwen | 7B | 32K | 4.7 | 5.4 | 8.1 | 8 | M-base | dense |
| 160 | tngtech/deepseek-r1t2-chimera | DeepSeek | 671B-A37B | 163K | 404.9 | 475.8 | 713.3 | — | cluster (>192) | MoE 671B/37B — DeepSeek V3/R1 hybrid |
| 161 | mistralai/devstral-small | Mistral | 24B | 131K | 14.3 | 16.8 | 25.1 | 24 | M-Pro | dense |
| 162 | allenai/olmo-3.1-32b-instruct | OLMo | 32B | 65K | no GGUF found | - | - | — | — | fully-open; GGUF repo gated on bartowski — estimate from BF16 |
| 172 | z-ai/glm-4.5 | GLM | 355B-A32B | 131K | 216.5 | 254.2 | 381.0 | — | cluster (>192) | MoE 355B/32B active |
| 174 | qwen/qwq-32b | Qwen | 32B | 131K | 19.9 | 23.3 | 34.8 | 36 | M-Pro | dense |
| 177 | qwen/qwen3-coder | Qwen | 480B-A35B | 262K | 290.1 | 340.5 | 510.4 | — | cluster (>192) | MoE 480B total, 35B active; flagship coder |
| 181 | mistralai/mistral-small-3.1-24b-instruct | Mistral | 24B | 128K | 14.3 | 16.8 | 25.1 | 24 | M-Pro | dense |
| 183 | gryphe/mythomax-l2-13b | Llama | 13B | 4K | 7.9 | 9.2 | 13.8 | 16 | M-base | dense |
| 184 | qwen/qwen2.5-vl-72b-instruct | Qwen | 72B | 32K | no GGUF found | - | - | — | — | vision-language; GGUF limited — MLX is the preferred path |
| 185 | meta-llama/llama-guard-4-12b | Llama | 12B | 163K | no GGUF found | - | - | — | — | safety classifier; HF repo gated, weights live |
| 187 | qwen/qwen3-14b | Qwen | 14B | 40K | 9.0 | 10.5 | 15.7 | 16 | M-base | dense |
| 189 | nousresearch/hermes-4-70b | Hermes | 70B | 131K | 42.5 | 49.9 | 75.0 | 96 | M-Max | dense |
| 195 | meta-llama/llama-3-8b-instruct | Llama | 8B | 8K | 4.9 | 5.7 | 8.5 | 16 | M-base | dense |
| 196 | qwen/qwen3-30b-a3b-thinking-2507 | Qwen | 30B-A3B | 131K | 18.6 | 21.7 | 32.5 | 32 | M-Pro | MoE reasoning |
| 198 | microsoft/wizardlm-2-8x22b | Mixtral | 8x22B | 65K | 85.6 | 100.0 | 149.4 | 192 | M-Ultra |  |
| 200 | thedrummer/skyfall-36b-v2 | Mistral | 36B | 32K | 22.4 | 26.2 | 39.2 | 48 | M-Pro | dense |
| 205 | thedrummer/rocinante-12b | Mistral | 12B | 32K | 7.5 | 8.7 | 13.0 | 16 | M-base | dense |
| 206 | nvidia/llama-3.3-nemotron-super-49b-v1.5 | Nemotron | 49B | 131K | 30.2 | 35.4 | 53.0 | 64 | M-Max | dense |
| 207 | nvidia/nemotron-nano-9b-v2 | Nemotron | 9B | 131K | 6.5 | 7.1 | 9.5 | 16 | M-base | hybrid Mamba+attention; check llama.cpp support |
| 208 | meta-llama/llama-3.3-70b-instruct | Llama | 70B | 65K | 42.5 | 49.9 | 75.0 | 96 | M-Max | dense |
| 209 | thedrummer/cydonia-24b-v4.1 | Mistral | 24B | 131K | 14.3 | 16.8 | 25.1 | 24 | M-Pro | dense |
| 210 | ibm-granite/granite-4.0-h-micro | Granite | 3B | 131K | 1.9 | 2.3 | 3.4 | 8 | M-base | dense 3B (Granite 4 "h-micro") |
| 212 | z-ai/glm-4.6v | GLM | 108B-A12B | 131K | no GGUF found | - | - | — | — | VL; GGUF not yet published |
| 213 | thedrummer/unslopnemo-12b | Mistral | 12B | 32K | no GGUF found | - | - | — | — | dense |
| 216 | qwen/qwen3-next-80b-a3b-instruct | Qwen | 80B-A3B | 262K | 48.5 | - | 84.8 | 96 | M-Max | MoE 80B/3B; hybrid attention (llama.cpp limited support) |
| 218 | meta-llama/llama-3.2-11b-vision-instruct | Llama | 11B | 131K | no GGUF found | - | - | — | — | vision; llama.cpp does not support the Llama 3.2 vision architecture — use MLX/vLLM |
| 219 | qwen/qwen3-next-80b-a3b-thinking | Qwen | 80B-A3B | 131K | 48.5 | - | 84.8 | 96 | M-Max | MoE 80B/3B reasoning |
| 229 | mistralai/mixtral-8x7b-instruct | Mixtral | 8x7B | 32K | 28.4 | 33.2 | 49.6 | 48 | M-Pro |  |
| 231 | microsoft/phi-4 | Phi | 14B | 16K | 8.9 | 10.4 | 15.6 | 16 | M-base | dense |
| 234 | liquid/lfm-2.5-1.2b-instruct | LFM | 1.2B | 32K | 1.5 | 0.8 | 1.2 | 8 | M-base | hybrid-SSM 1.2B; edge-friendly |
| 236 | bytedance/ui-tars-1.5-7b | Qwen | 7B | 128K | 4.7 | 5.4 | 8.1 | 8 | M-base | GUI-agent VLM (Qwen2.5-VL base) |
| 237 | qwen/qwen3-vl-30b-a3b-thinking | Qwen | 30B-A3B | 131K | 18.6 | 21.7 | 32.5 | 32 | M-Pro | MoE — all experts must fit in RAM |
| 238 | qwen/qwen3-vl-8b-thinking | Qwen | 8B | 131K | 5.0 | 5.9 | 8.7 | 16 | M-base | dense |
| 239 | undi95/remm-slerp-l2-13b | Llama | 13B | 6K | 7.9 | 9.2 | 13.8 | 16 | M-base | dense |
| 240 | nousresearch/hermes-3-llama-3.1-70b | Hermes | 70B | 131K | 42.5 | 49.9 | 75.0 | 96 | M-Max | dense |
| 241 | sao10k/l3.3-euryale-70b | Llama | 70B | 131K | 42.5 | 49.9 | 75.0 | 96 | M-Max | dense |
| 246 | qwen/qwen3-vl-235b-a22b-thinking | Qwen | 235B-A22B | 131K | 142.2 | 166.8 | 249.9 | — | cluster (>192) | MoE — all experts must fit in RAM |
| 247 | z-ai/glm-4.5v | GLM | 108B-A12B | 65K | no GGUF found | - | - | — | — | VL; GGUF not yet published for V variant |
| 248 | nousresearch/hermes-4-405b | Hermes | 405B | 131K | 243.1 | 286.6 | 431.2 | — | cluster (>192) | dense |
| 252 | deepseek/deepseek-r1-distill-llama-70b | DeepSeek | 70B | 131K | 42.5 | 49.9 | 75.0 | 96 | M-Max | dense; distilled R1 reasoning |
| 253 | alibaba/tongyi-deepresearch-30b-a3b | Qwen | 30B-A3B | 131K | 18.6 | 21.7 | 32.5 | 32 | M-Pro | MoE 30B/3B web-research agent (Qwen3 base) |
| 257 | deepseek/deepseek-r1-distill-qwen-32b | DeepSeek | 32B | 32K | 19.9 | 23.3 | 34.8 | 36 | M-Pro | dense; distilled R1 reasoning |
| 258 | mistralai/mixtral-8x22b-instruct | Mixtral | 8x22B | 65K | 85.6 | 100.0 | 149.4 | 192 | M-Ultra |  |
| 262 | google/gemma-3-27b-it | Gemma | 27B | 131K | 16.5 | 19.3 | 28.7 | 32 | M-Pro | dense |
| 263 | meta-llama/llama-3-70b-instruct | Llama | 70B | 8K | 42.5 | 50.0 | 75.0 | 96 | M-Max | dense |
| 268 | sao10k/l3.1-euryale-70b | Llama | 70B | 131K | 42.5 | 49.9 | 75.0 | 96 | M-Max | dense |
| 272 | ai21/jamba-large-1.7 | Jamba | 398B-A94B | 256K | no GGUF found | - | - | — | — | Mamba-Transformer MoE; no GGUF (llama.cpp lacks Jamba) |
| 273 | cognitivecomputations/dolphin-mistral-24b-venice-edition | Mistral | 24B | 32K | no GGUF found | - | - | — | — | uncensored Mistral Small finetune |
| 279 | meta-llama/llama-3.2-1b-instruct | Llama | 1B | 60K | 0.8 | 0.9 | 1.3 | 8 | M-base | dense |
| 281 | nvidia/nemotron-nano-12b-v2-vl | Nemotron | 12B | 131K | no GGUF found | - | - | — | — | hybrid VL |
| 282 | baidu/ernie-4.5-21b-a3b | ERNIE | 21B-A3B | 120K | 13.3 | 15.6 | 23.2 | 24 | M-Pro | MoE 21B/3B — Apache 2.0 |
| 287 | nvidia/llama-3.1-nemotron-70b-instruct | Nemotron | 70B | 131K | 42.5 | 49.9 | 75.0 | 96 | M-Max | dense |
| 289 | nousresearch/hermes-3-llama-3.1-405b | Hermes | 405B | 131K | 243.1 | 286.6 | 431.2 | — | cluster (>192) | dense |
| 291 | anthracite-org/magnum-v4-72b | Qwen | 72B | 16K | 47.4 | 54.4 | 77.3 | 96 | M-Max | dense |
| 294 | meta-llama/llama-3.2-3b-instruct | Llama | 3B | 131K | 2.0 | 2.3 | 3.4 | 8 | M-base | dense |
| 295 | qwen/qwen-2.5-coder-32b-instruct | Qwen | 32B | 32K | 19.9 | 23.3 | 34.8 | 36 | M-Pro | dense |
| 297 | google/gemma-3-4b-it | Gemma | 4B | 32K | 2.5 | 2.8 | 4.1 | 8 | M-base | dense |
| 302 | prime-intellect/intellect-3 | PrimeIntellect | 106B-A12B | 131K | 71.4 | 81.2 | 113.6 | 128 | M-Max | MoE GLM-4.5-Air finetune, 106B/12B active |
| 310 | google/gemma-2-27b-it | Gemma | 27B | 8K | 16.6 | 19.4 | 28.9 | 32 | M-Pro | dense |
| 313 | google/gemma-3-12b-it | Gemma | 12B | 32K | 7.3 | 8.4 | 12.5 | 16 | M-base | dense |
| 314 | nousresearch/hermes-2-pro-llama-3-8b | Hermes | 8B | 8K | 4.9 | 5.7 | 8.5 | 16 | M-base | dense |
| 315 | google/gemma-3n-e2b-it | Gemma | 5B | 8K | 3.0 | 3.3 | 4.8 | 8 | M-base | dense |
| 319 | google/gemma-3n-e4b-it | Gemma | 8B | 8K | 4.5 | 5.0 | 7.4 | 8 | M-base | dense |
| 321 | sao10k/l3-euryale-70b | Llama | 70B | 8K | 42.5 | 49.9 | 75.0 | 96 | M-Max | dense |
| 324 | meta-llama/llama-guard-3-8b | Llama | 8B | 131K | no GGUF found | - | - | — | — | safety classifier; HF API gated (weights exist on unsloth/bartowski) |
| 334 | baidu/ernie-4.5-300b-a47b | ERNIE | 300B-A47B | 123K | 180.2 | 212.0 | 318.3 | — | cluster (>192) | MoE 300B/47B |
| 336 | baidu/ernie-4.5-21b-a3b-thinking | ERNIE | 21B-A3B | 131K | 13.3 | 15.6 | 23.2 | 24 | M-Pro | MoE — all experts must fit in RAM |
| 337 | tencent/hunyuan-a13b-instruct | Hunyuan | 80B-A13B | 131K | 49.3 | 57.6 | 85.4 | 96 | M-Max | MoE 80B/13B active |
| 339 | baidu/ernie-4.5-vl-424b-a47b | ERNIE | 424B-A47B | 123K | no GGUF found | - | - | — | — | MoE VL |
| 340 | rekaai/reka-flash-3 | Reka | 21B | 65K | no GGUF found | - | - | — | — | 21B reasoning; GGUF repo access varies |
| 344 | baidu/ernie-4.5-vl-28b-a3b | ERNIE | 28B-A3B | 30K | no GGUF found | - | - | — | — | MoE VL |
| 353 | alpindale/goliath-120b | Llama | 120B | 6K | 70.6 | 83.2 | - | 128 | M-Max | dense |
| 376 | allenai/olmo-3-32b-think | OLMo | 32B | 65K | no GGUF found | - | - | — | — | fully-open reasoning |
| 386 | qwen/qwen2.5-vl-32b-instruct | Qwen | 32B | 32K | no GGUF found | - | - | — | — | vision-language; use MLX |
| 387 | google/gemma-2-9b-it | Gemma | 9B | 8K | 12.6 | 6.6 | 20.5 | 24 | M-Pro | dense |
| 389 | qwen/qwen2.5-coder-7b-instruct | Qwen | 7B | 131K | 4.7 | 5.4 | 8.1 | 8 | M-base | dense |
| 391 | nvidia/llama-3.1-nemotron-ultra-253b-v1 | Nemotron | 253B | 131K | 150.9 | 178.5 | 269.3 | — | cluster (>192) | dense 253B (pruned from 405B) |
| 392 | allenai/olmo-2-0325-32b-instruct | OLMo | 32B | 128K | no GGUF found | - | - | — | — | fully-open (older) |
| 402 | allenai/olmo-3.1-32b-think | OLMo | 32B | 65K | no GGUF found | - | - | — | — | fully-open reasoning |
| 404 | tngtech/tng-r1t-chimera | DeepSeek | 671B-A37B | 163K | no GGUF found | - | - | — | — | MoE 671B/37B — uses same GGUF as Chimera |
| 406 | allenai/olmo-3-7b-instruct | OLMo | 7B | 65K | no GGUF found | - | - | — | — | fully-open |
| 407 | allenai/olmo-3-7b-think | OLMo | 7B | 65K | no GGUF found | - | - | — | — | fully-open reasoning |
| 415 | liquid/lfm2-8b-a1b | LFM | 8B-A1B | 8K | 5.0 | 5.9 | 8.9 | 16 | M-base | MoE 8B/1B |
| 431 | ai21/jamba-mini-1.7 | Jamba | 52B-A12B | 256K | no GGUF found | - | - | — | — | Mamba-Transformer MoE; no GGUF |
| 441 | deepseek/deepseek-r1-distill-qwen-7b | DeepSeek | 7B | 131K | 4.7 | 5.4 | 8.1 | 8 | M-base |  |
| 442 | deepseek/deepseek-r1-0528-qwen3-8b | DeepSeek | 8B | 131K | 5.0 | 5.9 | 8.7 | 16 | M-base | dense; latest R1 distill |
| 443 | google/gemma-2b-it | Gemma | 2B | 8K | 1.5 | 1.8 | 2.7 | 8 | M-base | dense |
| 445 | thedrummer/valkyrie-49b-v1 | Nemotron | 49B | 131K | 30.2 | 35.4 | 53.0 | 64 | M-Max | dense |
| 446 | mistralai/devstral-small-2505 | Mistral | 24B | 131K | 14.3 | 16.8 | 25.1 | 24 | M-Pro | dense |
| 448 | meta-llama/llama-3.3-8b-instruct | Llama | 8B | 128K | 4.9 | 5.7 | 8.5 | 16 | M-base | sizes from mradermacher |
| 453 | microsoft/phi-4-reasoning-plus | Phi | 14B | 32K | 9.1 | 10.6 | 15.6 | 16 | M-base | dense |
| 454 | microsoft/phi-4-reasoning | Phi | 14B | 32K | 9.1 | 10.6 | 15.6 | 16 | M-base | dense |
| 455 | qwen/qwen3-0.6b-04-28 | Qwen | 0.6B | 32K | 0.4 | 0.4 | 0.6 | 8 | M-base | dense |
| 456 | qwen/qwen3-1.7b | Qwen | 1.7B | 32K | 1.1 | 1.3 | 1.8 | 8 | M-base | dense |
| 457 | qwen/qwen3-4b | Qwen | 4B | 128K | 2.5 | 2.9 | 4.3 | 8 | M-base | dense |
| 460 | deepseek/deepseek-prover-v2 | DeepSeek | 671B-A37B | 163K | 404.5 | 475.4 | 713.3 | — | cluster (>192) | MoE 671B/37B math specialist |
| 461 | tngtech/deepseek-r1t-chimera | DeepSeek | 671B-A37B | 163K | no GGUF found | - | - | — | — | MoE 671B/37B — uses same GGUF as Chimera |
| 472 | nvidia/llama-3.1-nemotron-nano-8b-v1 | Nemotron | 8B | 131K | no GGUF found | - | - | — | — | dense |
| 473 | nvidia/llama-3.3-nemotron-super-49b-v1 | Nemotron | 49B | 131K | 30.2 | 35.4 | 53.0 | 64 | M-Max | dense |
| 481 | qwen/qwen2.5-vl-3b-instruct | Qwen | 3B | 64K | no GGUF found | - | - | — | — | vision-language; use MLX |
| 486 | google/gemma-3-1b-it | Gemma | 1B | 32K | 0.8 | 0.9 | 1.1 | 8 | M-base | dense |
| 490 | microsoft/phi-4-multimodal-instruct | Phi | 5.6B | 131K | no GGUF found | - | - | — | — | multimodal; GGUF limited |
| 492 | qwen/qwen2.5-32b-instruct | Qwen | 32B | 131K | 19.9 | 23.3 | 34.8 | 36 | M-Pro | dense |
| 500 | deepseek/deepseek-r1-distill-llama-8b | DeepSeek | 8B | 0 | 4.9 | 5.7 | 8.5 | 16 | M-base |  |
| 501 | deepseek/deepseek-r1-distill-qwen-1.5b | DeepSeek | 1.5B | 131K | 1.1 | 1.3 | 1.9 | 8 | M-base |  |
| 502 | deepseek/deepseek-r1-distill-qwen-14b | DeepSeek | 14B | 131K | 9.0 | 10.5 | 15.7 | 16 | M-base |  |
| 512 | qwen/qwq-32b-preview | Qwen | 32B | 32K | 19.9 | 23.3 | 34.8 | 36 | M-Pro | dense |
| 532 | meta-llama/llama-3.2-90b-vision-instruct | Llama | 90B | 131K | no GGUF found | - | - | — | — | vision; llama.cpp unsupported — use MLX/vLLM |
| 538 | mistralai/pixtral-12b | Mistral | 12B | 4K | no GGUF found | - | - | — | — | vision; GGUF gated on bartowski |
| 540 | qwen/qwen-2.5-vl-7b-instruct | Qwen | 7B | 32K | no GGUF found | - | - | — | — | vision-language; use MLX |
| 546 | microsoft/phi-3.5-mini-128k-instruct | Phi | 3.8B | 128K | 2.4 | 2.8 | 4.1 | 8 | M-base | dense |
| 557 | meta-llama/llama-3.1-405b-instruct | Llama | 405B | 131K | 245.7 | 289.7 | 435.7 | — | cluster (>192) | dense 405B — cluster only; sizes from mradermacher parts |
| 561 | nousresearch/hermes-2-theta-llama-3-8b | Hermes | 8B | 16K | 4.9 | 5.7 | 8.5 | 16 | M-base | dense |
| 568 | microsoft/phi-3-medium-4k-instruct | Phi | 14B | 4K | 8.6 | 10.1 | 14.8 | 16 | M-base | dense |
| 573 | mistralai/mistral-7b-instruct-v0.3 | Mistral | 7B | 32K | 4.4 | 5.1 | 7.7 | 8 | M-base | dense |
| 575 | microsoft/phi-3-mini-128k-instruct | Phi | 3.8B | 128K | no GGUF found | - | - | — | — | HF repo gated |
| 576 | microsoft/phi-3-medium-128k-instruct | Phi | 14B | 128K | 8.6 | 10.1 | 14.8 | 16 | M-base | dense |
| 578 | deepseek/deepseek-chat-v2.5 | DeepSeek | 236B-A21B | 128K | 142.5 | 167.2 | 250.6 | — | cluster (>192) | MoE 236B/21B active |
| 600 | microsoft/wizardlm-2-7b | Mistral | 7B | 32K | 4.4 | 5.1 | 7.7 | 8 | M-base | dense |
| 613 | google/gemma-7b-it | Gemma | 7B | 8K | 5.3 | 6.1 | 9.1 | 16 | M-base | dense |
| 626 | mistralai/mistral-7b-instruct-v0.2 | Mistral | 7B | 32K | 4.4 | 5.1 | 7.7 | 8 | M-base | dense |

Total rows: **162** open-weight models.

---

## Top picks for our fleet

These are the models we should prioritize standing up first. Picks balance OpenRouter demand, quality of the open-weight model, breadth of Mac SKU coverage, and how well llama.cpp + MLX support the architecture today.

### Tier S — run on every Mac we own, load broadly

1. **`meta-llama/llama-3.1-8b-instruct`** — rank 45, 5.0 GB Q4_K_M. Ubiquitous baseline. Fits on an 8 GB Mac. Llama 3.1 license allows commercial use with notice. Every eval harness and every tokenizer library already handles it.
2. **`qwen/qwen3-8b`** — rank 99, 5.0 GB Q4_K_M, 40K ctx. Qwen3 outperforms Llama-3.1-8B on most reasoning benchmarks and has Apache-2.0 weights. Same RAM class — load alongside Llama-3.1-8B on 16 GB machines.
3. **`google/gemma-3-4b-it`** — 2.5 GB Q4_K_M. Strong vision-capable small model for the 8 GB Mac tier. Gemma 3 is multimodal (text + image) and the GGUF works with mmproj.

### Tier A — the 24–36 GB sweet-spot workhorses

4. **`qwen/qwen3-30b-a3b-instruct-2507`** — rank 81, 18.6 GB Q4_K_M, 256K ctx, MoE 30B/3B. Best throughput-per-GB we have. 32 GB Mac fits one replica comfortably; 48 GB can run Q5_K_M. This and its Coder/Thinking siblings (`qwen3-coder-30b-a3b-instruct` rank 145, `qwen3-30b-a3b-thinking-2507` rank 196) use the same weights at identical size — load one checkpoint, swap heads.
5. **`openai/gpt-oss-20b`** — rank 54/118, 11.6 GB Q4_K_M, 128K ctx, MoE 20B/3.6B. Apache-2.0, OpenAI-trained, native MXFP4. Fast and stable. 24 GB Mac.
6. **`mistralai/mistral-small-3.2-24b-instruct`** — rank 63, 14.3 GB Q4_K_M, 128K ctx. Apache-2.0, excellent tool-use and instruction-following. Mistral Small 3.1/3.2/"4"/Devstral-Small/Cydonia/Dolphin-Venice all share the same 24B base — one ~15 GB pool of weights covers 5 OpenRouter slugs.
7. **`google/gemma-3-27b-it`** — rank 83, 16.5 GB Q4_K_M, 128K ctx, multimodal. 32 GB Mac. Best small-class vision model with GGUF.
8. **`qwen/qwen3-32b`** / **`qwen/qwq-32b`** — ranks 102/174, 19.8 GB Q4_K_M. Dense 32B. QwQ is the reasoning-tuned sibling.

### Tier B — M-Max territory (64–128 GB)

9. **`meta-llama/llama-3.3-70b-instruct`** — rank 72/208, 42.5 GB Q4_K_M. The 70B everyone asks for. Also unlocks all its finetunes: Hermes-4-70B, Euryale, Hanami, Nemotron-70B.
10. **`openai/gpt-oss-120b`** — rank 15/48, 62.8 GB Q4_K_M, MoE 117B/5.1B. Punches well above its size due to low active-param count. 128 GB Mac Studio runs this comfortably at Q4 with room for 128K KV. **Best flagship-quality model that fits on a single consumer Mac.**
11. **`z-ai/glm-4.5-air`** — rank 40/41, 73.0 GB Q4_K_M, MoE 106B/12B. Competes with Claude Sonnet / DeepSeek on agentic tasks. Fits on 128 GB Studio. Same base powers `prime-intellect/intellect-3`.

### Tier C — Ultra + multi-node plays (the hero models)

These are the slugs with the most demand on OpenRouter that nobody else in the Mac world can serve well. Worth building cluster-shard support for:

12. **`deepseek/deepseek-chat-v3.1`** / **`deepseek/deepseek-v3.1-terminus`** / **`deepseek/deepseek-chat-v3-0324`** / **`deepseek/deepseek-r1-0528`** — all 405–480 GB at Q4_K_M. MoE 671B/37B active. Requires ~2 M3 Ultra 192 GB or ~3 Mac Studio 128 GB with mesh-llm/exo sharding. Huge demand (ranks 43, 47, 79, 80, 109).
13. **`qwen/qwen3-235b-a22b-2507`** — rank 39, 142 GB Q4_K_M, MoE 235B/22B. Fits on one M3 Ultra 192 GB at Q3/Q4 with tight KV, or cleanly shards across 2× 128 GB.
14. **`moonshotai/kimi-k2-thinking`** — rank 105, 621 GB Q4_K_M, MoE 1T/32B. Cluster-only but popular enough to matter; 4× M3 Ultra minimum.
15. **`z-ai/glm-4.6`** — rank 107, 215 GB Q4_K_M, MoE 355B/32B. Fits on 2× M3 Ultra or 3× 128 GB Studio.

### Honorable mentions / niche

- **Roleplay / creative**: `sao10k/l3.3-euryale-70b`, `thedrummer/rocinante-12b` (12 GB), `gryphe/mythomax-l2-13b` (7.9 GB — legacy but still requested). Heavy demand on OpenRouter but low per-request margin — run only where we already have 70B loaded.
- **Coder specialists**: `qwen/qwen3-coder-30b-a3b-instruct` (shares weights with qwen3-30b-a3b — free), `qwen/qwen2.5-coder-32b-instruct` (19.9 GB, dense), `mistralai/devstral-small` (shares Mistral-Small-24B weights — free).
- **Vision**: Gemma 3 family (llama.cpp supported), Qwen3-VL family (GGUF + mmproj). Skip Llama-3.2-Vision and Qwen2.5-VL on llama.cpp — use MLX instead.
- **Safety**: `meta-llama/llama-guard-3-8b` / `llama-guard-4-12b` for content moderation (~5 and ~7 GB). Cheap to run as a sidecar classifier on every node.

## Data quality caveats

- **Rankings are qualitative, not quantitative.** `top-weekly` is a sorted list without exposed token volumes. A model at rank 40 might have 100× the traffic of rank 80, or 1.2×. For actual demand forecasting we should apply as a provider and get the internal dashboard.
- **`no GGUF found` does not mean unrunnable.** It means our crawler couldn't fetch a size without HF auth (or the repo was genuinely empty). Llama-family repos on bartowski/unsloth have become gated since Meta re-issued licenses — any Llama-derivative quant sizes in this table that come from `bartowski/` / `unsloth/` required either the HF cache or a substitute repo. Where we substituted (e.g. `mradermacher/`), sizes are faithful.
- **MoE sizes shown are total weight bytes.** Active parameter count (Aχ) governs speed, not disk/RAM. For Qwen3-30B-A3B a 32 GB Mac loads the whole 30B but inferences at 3B-active speed — fast.
- **Some OpenRouter slugs don't have open weights**, despite appearing under a vendor we treat as open. We filtered these out: all Qwen cloud tiers (Max/Plus/Turbo/Coder-Plus/Coder-Flash/3.5-Flash/3.5-Plus/3.6-Plus), Mistral's paid-tier models (Large/Medium/Ministral-Premium/Pixtral-Large/Voxtral/Saba), xAI Grok cloud-only variants, all Google Gemini, all Anthropic, all OpenAI except `gpt-oss-*`, all Stepfun/MiniMax/Mimo/Arcee-cloud. If the OpenRouter slug is missing from this file and you think it belongs, verify the model card on HF explicitly publishes weights under an open license.
- **Context lengths reflect OpenRouter's advertised values**, which are the upstream provider's. When *we* host we're bounded by KV cache — see the methodology note.
- **The v3.2-Exp, GLM-5, Qwen3.5/3.6, Gemma-4, MiMo-V2, Kimi-K2.5 entries in the rankings are for models that have NOT yet been released as open weights at the time of this document** (2026-04-18). Rankings include them because OpenRouter lists them; they are listed in our excluded filter, with the exception of gemma-4 which we've kept based on Google's historical pattern — verify before deploying.
