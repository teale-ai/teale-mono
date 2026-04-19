# Manage Models

Download, load, and organize the models Teale uses for inference. Teale supports GGUF models via llama.cpp and MLX models for Apple Silicon.

---

## Prerequisites

- Teale installed and running

## List available models

See all models that Teale knows about, including downloaded and remote:

```bash
teale models list
```

The output shows each model's name, size, quantization, and whether it is downloaded, loaded, or available for download.

## Download a model

```bash
teale models download llama-3.1-8b-instruct-4bit
```

Teale downloads the model from HuggingFace Hub. If a LAN peer already has the model, Teale downloads from the peer instead (faster, no internet required).

## Load a model

Loading a model makes it available for inference:

```bash
teale models load llama-3.1-8b-instruct-4bit
```

Only one model can be loaded at a time. Loading a new model automatically unloads the previous one.

## Unload a model

Free memory by unloading the current model:

```bash
teale models unload
```

## Auto-management

Let Teale manage models automatically based on network demand:

```bash
teale config set auto_manage_models true
```

When enabled, Teale:

- Downloads models that are frequently requested on the network.
- Loads the model that best matches current demand and your hardware capabilities.
- Swaps models as demand shifts throughout the day.

This is enabled by default when you run `teale up --maximize-earnings`.

## Storage limit

Control how much disk space Teale uses for model storage:

```bash
teale config set max_storage_gb 50
```

When the limit is reached, Teale removes the least recently used models to make room for new downloads.

## Use existing GGUF files

Teale scans common model directories for `.gguf` files already on your system:

- **LM Studio:** `~/.cache/lm-studio/models/`
- **Ollama:** `~/.ollama/models/`
- **HuggingFace cache:** `~/.cache/huggingface/hub/`

Models found in these locations appear in `teale models list` and can be loaded directly without re-downloading.

## Backend selection

Teale supports two inference backends:

| Backend   | Description                          | Best for                        |
|-----------|--------------------------------------|---------------------------------|
| `llamacpp`| llama.cpp with Metal acceleration    | GGUF models, broad compatibility |
| `mlx`     | Apple MLX framework                  | MLX-format models, Apple Silicon |

Set the backend:

```bash
teale config set inference_backend llamacpp
```

The default is `llamacpp`. Switch to `mlx` if you are using MLX-format models or want to experiment with the MLX runtime.

## Model naming

Models are identified by a short name that encodes the model family, parameter count, variant, and quantization:

```
llama-3.1-8b-instruct-4bit
^^^^^^^^^  ^^  ^^^^^^^^  ^^^^
family     params variant  quant
```

Use `teale models list` to see all available names.

---

## Next steps

- [Earn Credits](earn-credits.md) --- let Teale pick the optimal model for earning
- [Headless Server Mode](headless-server.md) --- run a dedicated inference server
- [Inference Providers](../concepts/inference-providers.md) --- how the backend system works
