# Supported Models

Curated model catalog with sizes, RAM requirements, and HuggingFace repositories.

## Model Catalog

All models are 4-bit quantized (q4) for the MLX framework. Rankings reflect network demand -- lower rank means more frequently requested.

| Rank | Model | Parameters | Quantization | Size | RAM Required | HuggingFace Repo |
|------|-------|-----------|-------------|------|-------------|-----------------|
| 1 | Llama 3.1 8B Instruct | 8B | q4 | 4.5 GB | 10 GB | `mlx-community/Meta-Llama-3.1-8B-Instruct-4bit` |
| 2 | Qwen 3 8B | 8B | q4 | 4.5 GB | 10 GB | `mlx-community/Qwen3-8B-4bit` |
| 3 | Gemma 3 4B Instruct | 4B | q4 | 2.5 GB | 6 GB | `mlx-community/gemma-3-4b-it-qat-4bit` |
| 4 | Llama 3.2 3B Instruct | 3B | q4 | 1.8 GB | 6 GB | `mlx-community/Llama-3.2-3B-Instruct-4bit` |
| 5 | Llama 3.2 1B Instruct | 1B | q4 | 0.7 GB | 4 GB | `mlx-community/Llama-3.2-1B-Instruct-4bit` |
| 6 | Phi 4 | 14B | q4 | 8.0 GB | 14 GB | `mlx-community/phi-4-4bit` |
| 7 | Mistral Small 24B | 24B | q4 | 13.0 GB | 20 GB | `mlx-community/Mistral-Small-24B-Instruct-2501-4bit` |
| 8 | Gemma 3 27B Instruct | 27B | q4 | 15.0 GB | 24 GB | `mlx-community/gemma-3-27b-it-qat-4bit` |
| 9 | Qwen 3 32B | 32B | q4 | 18.0 GB | 28 GB | `mlx-community/Qwen3-32B-4bit` |
| 10 | Llama 4 Scout 109B (MoE) | 109B | q4 | 56.0 GB | 72 GB | `mlx-community/Llama-4-Scout-17Bx16E-Instruct-4bit` |

## Model Families

| Family | Provider | Models |
|--------|----------|--------|
| Llama | Meta | 1B, 3B, 8B, 109B MoE |
| Qwen | Alibaba | 8B, 32B |
| Gemma | Google | 4B, 27B |
| Phi | Microsoft | 14B |
| Mistral | Mistral AI | 24B |

## RAM Recommendations

| Available RAM | Recommended Models |
|--------------|-------------------|
| 4-6 GB | Llama 3.2 1B |
| 6-10 GB | Llama 3.2 3B, Gemma 3 4B |
| 10-14 GB | Llama 3.1 8B, Qwen 3 8B |
| 14-20 GB | Phi 4 14B |
| 20-28 GB | Mistral Small 24B, Gemma 3 27B |
| 28-64 GB | Qwen 3 32B |
| 64+ GB | Llama 4 Scout 109B MoE |

## Model Selection

Teale automatically selects models based on available hardware. The `ModelCatalog` provides:

- `availableModels(for: hardware)` -- all models that fit in available RAM
- `topModels(for: hardware, limit: 3)` -- the most popular models that fit, sorted by demand ranking

## GGUF Models (Cross-Platform)

On non-Apple platforms, Teale uses **llama.cpp** with GGUF-format models instead of MLX. GGUF models are available from the same HuggingFace repositories in GGUF format (e.g., `Qwen/Qwen3-8B-GGUF`).

The GGUF backend supports:
- NVIDIA GPUs via CUDA
- AMD GPUs via ROCm
- CPU-only inference on any platform
- Vulkan for cross-platform GPU acceleration

Model sizes and RAM requirements are similar between MLX and GGUF at the same quantization level.

## Quantization Levels

| Level | Description | Size Multiplier | Quality |
|-------|-------------|----------------|---------|
| q4 | 4-bit quantization | 1.0x (baseline) | Good for most tasks |
| q8 | 8-bit quantization | ~2x | Better quality, more RAM |
| fp16 | Half-precision float | ~4x | Full quality, maximum RAM |

The catalog uses q4 by default for the best balance of quality and memory efficiency. Higher quantizations are available by specifying alternate HuggingFace repos.
