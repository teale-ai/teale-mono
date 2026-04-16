# teale-node

Cross-platform TealeNet supply node agent. Run this on any machine (Linux, Windows, macOS, Android) to contribute inference capacity to the Teale network.

## Quick Start

### 1. Get llama-server

Download from [llama.cpp releases](https://github.com/ggml-org/llama.cpp/releases) or build from source.

### 2. Get a GGUF model

```bash
# Example: download Qwen3 8B Q4
huggingface-cli download Qwen/Qwen3-8B-GGUF qwen3-8b-q4_k_m.gguf --local-dir /models
```

### 3. Configure

```bash
cp teale-node.example.toml teale-node.toml
# Edit teale-node.toml: set binary path, model path, display name
```

### 4. Run

```bash
cargo build --release
./target/release/teale-node --config teale-node.toml
```

## Docker (Linux with NVIDIA GPU)

```bash
docker build -t teale/node .
docker run -v /path/to/models:/models --gpus all \
  -e DISPLAY_NAME="My GPU Server" \
  teale/node
```

CPU-only variant:
```bash
docker build -f Dockerfile.cpu -t teale/node-cpu .
docker run -v /path/to/models:/models teale/node-cpu
```

## Android (Termux)

### Prerequisites

1. Install [Termux](https://f-droid.org/en/packages/com.termux/) from F-Droid (not Play Store — the Play Store version is outdated)
2. Grant storage access: `termux-setup-storage`

### Install llama-server

```bash
pkg update && pkg install cmake clang git
git clone https://github.com/ggml-org/llama.cpp
cd llama.cpp
cmake -B build -DGGML_VULKAN=ON
cmake --build build --target llama-server -j4
cp build/bin/llama-server $PREFIX/bin/
```

### Install teale-node

```bash
pkg install rust
git clone <repo-url>
cd copenhagen
cargo build --release
cp target/release/teale-node $PREFIX/bin/
```

### Download a model

For **Pixel 9 Pro Fold** (Tensor G4) — use Gemma 4 E4B, which is hardware-optimized for Tensor chips:

```bash
pip install huggingface-hub
# Recommended: Gemma 4 E4B (2.5GB Q4, vision + function calling)
huggingface-cli download ggml-org/gemma-4-E4B-it-GGUF \
  gemma-4-E4B-it-Q4_K_M.gguf --local-dir /storage/emulated/0/models
```

For **non-Pixel Android phones** — use Qwen3.5 4B:

```bash
# Qwen3.5 4B GGUF (for llama-server)
huggingface-cli download unsloth/Qwen3-4B-GGUF \
  Qwen3-4B-Q4_K_M.gguf --local-dir /storage/emulated/0/models
```

See [Model Recommendations](#model-recommendations) below for the full breakdown by device and RAM.

### Configure and run

```bash
cp teale-node.android.toml teale-node.toml
# Edit paths as needed
teale-node --config teale-node.toml
```

Key settings for Pixel 9 Pro Fold (16GB):
- `gpu_backend = "vulkan"` (Mali-G715 GPU)
- `context_size = 4096` (E4B at 2.5GB leaves plenty of headroom)
- `gpu_layers = 999` (full GPU offload via Vulkan)
- Model: [Gemma 4 E4B GGUF](https://huggingface.co/ggml-org/gemma-4-E4B-it-GGUF) (~2.5 GB Q4_K_M)

### Tips

- Run `termux-wake-lock` before starting to prevent Android from killing the process
- Use `TEALE_CHIP_FAMILY=tensorG4` if auto-detection doesn't identify your SoC
- The Tensor G4 will thermal-throttle under sustained load — consider smaller models or lower context sizes
- For best Vulkan performance, ensure your device has up-to-date GPU drivers

## Android with MNN-LLM (Huawei / OpenCL devices)

For Huawei phones (Kirin SoC) and other devices where OpenCL outperforms Vulkan, use MNN-LLM instead of llama-server.

### Install MNN-LLM

```bash
pkg update && pkg install cmake clang git
git clone https://github.com/alibaba/MNN
cd MNN
cmake -B build -DMNN_LOW_MEMORY=ON -DMNN_BUILD_LLM=ON -DMNN_OPENCL=ON
cmake --build build -j4
cp build/mnn_llm $PREFIX/bin/
```

### Download a model

Pre-built MNN models are available from the Alibaba MNN team (no conversion needed):

```bash
# Qwen3.5 4B — recommended for 8-16GB phones
huggingface-cli download taobao-mnn/Qwen3.5-4B-MNN \
  --local-dir /storage/emulated/0/models/qwen3.5-4b-mnn

# Qwen3 4B — alternative
huggingface-cli download taobao-mnn/Qwen3-4B-MNN \
  --local-dir /storage/emulated/0/models/qwen3-4b-mnn
```

To convert other models manually:

```bash
python3 MNN/transformers/llm/export/llm_export.py \
  --model Qwen/Qwen3-0.6B --quant_bit 4 \
  --output_dir /storage/emulated/0/models/qwen3-0.6b-mnn
```

### Configure

Set `backend = "mnn"` at the top of your config and add an `[mnn]` section:

```toml
backend = "mnn"

[mnn]
binary = "/data/data/com.termux/files/usr/bin/mnn_llm"
model_dir = "/storage/emulated/0/models/qwen3.5-4b-mnn"
model_id = "qwen3.5-4b"
backend_type = "opencl"
context_size = 2048
port = 11437

[node]
display_name = "Huawei Mate 60 Pro"
gpu_backend = "opencl"
```

### Why MNN over llama-server?

- **OpenCL**: MNN's OpenCL backend is significantly faster on Mali GPUs (Kirin, Exynos, MediaTek) than llama.cpp's Vulkan
- **Optimized for mobile**: Built by Alibaba specifically for on-device inference
- **Pre-built models**: [Qwen3.5 4B MNN](https://huggingface.co/taobao-mnn/Qwen3.5-4B-MNN) and [Qwen3 4B MNN](https://huggingface.co/taobao-mnn/Qwen3-4B-MNN) are ready to deploy
- **No Google Play Services required**: Works on Huawei devices without GMS

## LiteRT-LM (Pixel / Tensor — In-Process)

For Pixel devices with Tensor chips, LiteRT-LM uses Google's on-device runtime with GPU/NPU acceleration optimized for Gemma models.

### Build litert_lm_main

```bash
# One-time: build the LiteRT-LM binary + GPU plugins (requires Bazel + NDK)
./scripts/build-litert.sh
```

This produces `lib/android_arm64/litert_lm_main` (15MB stripped) and GPU accelerator `.so` files.

### Download model

```bash
huggingface-cli download litert-community/gemma-4-E4B-it-litert-lm \
  --local-dir /storage/emulated/0/models/gemma-4-E4B-it-litert-lm
```

### Deploy

```bash
adb push target/aarch64-linux-android/release/teale-node /data/local/tmp/
adb push lib/android_arm64/litert_lm_main /data/local/tmp/
adb push lib/android_arm64/*.so /data/local/tmp/lib/   # GPU accelerator plugins
adb push teale-node.litert.toml /data/local/tmp/teale-node.toml
adb shell chmod +x /data/local/tmp/teale-node /data/local/tmp/litert_lm_main
adb shell /data/local/tmp/teale-node --config /data/local/tmp/teale-node.toml
```

### Why LiteRT-LM?

- **Hardware-optimized**: Tensor G4's dedicated AI cores accelerate Gemma models directly
- **No Python/Node.js**: Just two binaries (teale-node + litert_lm_main) + model file
- **Multimodal**: Supports vision + audio input natively
- **GPU plugins**: Prebuilt OpenCL and GPU accelerators for maximum throughput

## Windows Fleet Deployment

For deploying to multiple Windows machines (tested with 200+ nodes):

```powershell
# On each machine (or via Group Policy / PSRemoting):
powershell -ExecutionPolicy Bypass -File \\share\teale\deploy-windows.ps1 `
    -ModelSharePath "\\fileserver\teale\models\qwen3-8b-q4_k_m.gguf"
```

See [Fleet Deployment Guide](docs/fleet-deployment-windows.md) for detailed instructions including SCCM, Group Policy, and BranchCache strategies.

## Model Recommendations

### Pixel / Tensor G4 devices (16GB)

Use **Gemma 4 E4B** — Google-optimized for Tensor hardware with dedicated AI core acceleration.

| Format | Model | Size | Link |
|--------|-------|------|------|
| LiteRT-LM (in-process) | Gemma 4 E4B | ~3.6 GB | [litert-community/gemma-4-E4B-it-litert-lm](https://huggingface.co/litert-community/gemma-4-E4B-it-litert-lm) |
| GGUF (llama-server) | Gemma 4 E4B Q4_K_M | ~2.5 GB | [ggml-org/gemma-4-E4B-it-GGUF](https://huggingface.co/ggml-org/gemma-4-E4B-it-GGUF) |
| GGUF (llama-server) | Gemma 4 E2B Q8_0 | ~5.0 GB | [ggml-org/gemma-4-E2B-it-GGUF](https://huggingface.co/ggml-org/gemma-4-E2B-it-GGUF) |

Gemma 4 E4B gives you vision + audio + function calling at 2.5GB, leaving massive headroom on 16GB. Use E4B over E2B — it has more effective parameters and multimodal support.

### Non-Pixel Android (Snapdragon, Kirin, Exynos, MediaTek)

| RAM | Backend | Model | Size | Link |
|-----|---------|-------|------|------|
| 8–16 GB | MNN | Qwen3.5 4B MNN | ~2.5 GB | [taobao-mnn/Qwen3.5-4B-MNN](https://huggingface.co/taobao-mnn/Qwen3.5-4B-MNN) |
| 8–16 GB | llama-server | Qwen3 4B GGUF | ~2.5 GB | [unsloth/Qwen3-4B-GGUF](https://huggingface.co/unsloth/Qwen3-4B-GGUF) |
| 4–8 GB | MNN | Qwen3 4B MNN | ~2.5 GB | [taobao-mnn/Qwen3-4B-MNN](https://huggingface.co/taobao-mnn/Qwen3-4B-MNN) |
| 2–4 GB | MNN | Qwen3 0.6B | ~400 MB | Convert via llm_export |

Qwen3.5 is a generation newer than Qwen3 with hybrid Gated Delta Networks + sparse MoE architecture and 201 language support. Prefer it over Qwen3 when RAM allows.

## Supported Platforms

| Platform | GPU | Backend | Status |
|----------|-----|---------|--------|
| macOS (Apple Silicon) | Metal | llama-server | Native binary |
| Linux x86_64 | CUDA/ROCm/Vulkan/CPU | llama-server | Docker or native |
| Linux aarch64 | CPU | llama-server | Native binary |
| Windows x86_64 | CUDA/Vulkan/CPU | llama-server | Native binary |
| Android aarch64 | Vulkan/CPU | llama-server | Termux or NDK |
| Android aarch64 (Kirin/Mali) | OpenCL/CPU | MNN-LLM | Termux |
| Android aarch64 (Pixel/Tensor) | GPU/NPU | LiteRT-LM | Native (in-process) |

## How It Works

1. Generates an Ed25519 identity (persisted to disk)
2. Connects to the TealeNet relay server via WebSocket
3. Registers as a supply node with hardware capabilities
4. Launches inference backend (llama-server or MNN-LLM) as a subprocess
5. Accepts inference requests from demand nodes (Mac/iPhone app)
6. Proxies requests to the backend's OpenAI-compatible API
7. Streams responses back through the relay

## Architecture

```
┌─────────────┐     WebSocket     ┌──────────┐     WebSocket    ┌──────────────┐
│  teale-node │ ◄──────────────► │  Relay   │ ◄──────────────► │  Mac/iPhone  │
│  (Linux)    │                   │  Server  │                   │  Teale App   │
└──────┬──────┘                   └──────────┘                   └──────────────┘
       │ HTTP (localhost)
       ▼
┌─────────────────────┐
│ llama-server (GGUF) │
│   — or —            │
│ mnn_llm (MNN)       │
└─────────────────────┘
```

## License

[AGPL-3.0](LICENSE)
