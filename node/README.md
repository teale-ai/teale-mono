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

```bash
pip install huggingface-hub
huggingface-cli download Qwen/Qwen3-4B-GGUF qwen3-4b-q4_k_m.gguf \
  --local-dir /storage/emulated/0/models
```

### Configure and run

```bash
cp teale-node.example.toml teale-node.toml
# Edit for Android — see the Android example at the bottom of the example file
teale-node --config teale-node.toml
```

Key settings for Pixel 9 Pro Fold (16GB):
- `gpu_backend = "vulkan"` (Mali-G715 GPU)
- `context_size = 2048` (or 4096 for smaller models)
- `gpu_layers = 999` (full GPU offload via Vulkan)
- Model: Qwen3 4B Q4_K_M (~2.5 GB) or Phi-3.5 Mini Q4 (~2.2 GB)

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

### Convert a model

MNN uses its own model format. Convert from Hugging Face:

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
model_dir = "/storage/emulated/0/models/qwen3-0.6b-mnn"
model_id = "qwen3-0.6b"
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
- **Smaller models**: Works well with Qwen3 0.6B and 1.7B which are ideal for 2–8GB phones
- **No Google Play Services required**: Works on Huawei devices without GMS

## Windows Fleet Deployment

For deploying to multiple Windows machines (tested with 200+ nodes):

```powershell
# On each machine (or via Group Policy / PSRemoting):
powershell -ExecutionPolicy Bypass -File \\share\teale\deploy-windows.ps1 `
    -ModelSharePath "\\fileserver\teale\models\qwen3-8b-q4_k_m.gguf"
```

See [Fleet Deployment Guide](docs/fleet-deployment-windows.md) for detailed instructions including SCCM, Group Policy, and BranchCache strategies.

## Supported Platforms

| Platform | GPU | Backend | Status |
|----------|-----|---------|--------|
| macOS (Apple Silicon) | Metal | llama-server | Native binary |
| Linux x86_64 | CUDA/ROCm/Vulkan/CPU | llama-server | Docker or native |
| Linux aarch64 | CPU | llama-server | Native binary |
| Windows x86_64 | CUDA/Vulkan/CPU | llama-server | Native binary |
| Android aarch64 | Vulkan/CPU | llama-server | Termux or NDK |
| Android aarch64 (Kirin/Mali) | OpenCL/CPU | MNN-LLM | Termux |

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
