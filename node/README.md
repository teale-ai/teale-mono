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

## Windows Fleet Deployment

For deploying to multiple Windows machines (tested with 200+ nodes):

```powershell
# On each machine (or via Group Policy / PSRemoting):
powershell -ExecutionPolicy Bypass -File \\share\teale\deploy-windows.ps1 `
    -ModelSharePath "\\fileserver\teale\models\qwen3-8b-q4_k_m.gguf"
```

See [Fleet Deployment Guide](docs/fleet-deployment-windows.md) for detailed instructions including SCCM, Group Policy, and BranchCache strategies.

## Supported Platforms

| Platform | GPU | Status |
|----------|-----|--------|
| macOS (Apple Silicon) | Metal | Native binary |
| Linux x86_64 | CUDA/ROCm/Vulkan/CPU | Docker or native |
| Linux aarch64 | CPU | Native binary |
| Windows x86_64 | CUDA/Vulkan/CPU | Native binary |
| Android aarch64 | Vulkan/CPU | Termux or NDK |

## How It Works

1. Generates an Ed25519 identity (persisted to disk)
2. Connects to the TealeNet relay server via WebSocket
3. Registers as a supply node with hardware capabilities
4. Launches llama-server as a subprocess (or connects to existing)
5. Accepts inference requests from demand nodes (Mac/iPhone app)
6. Proxies requests to llama-server's OpenAI-compatible API
7. Streams responses back through the relay

## Architecture

```
┌─────────────┐     WebSocket     ┌──────────┐     WebSocket    ┌──────────────┐
│  teale-node │ ◄──────────────► │  Relay   │ ◄──────────────► │  Mac/iPhone  │
│  (Linux)    │                   │  Server  │                   │  Teale App   │
└──────┬──────┘                   └──────────┘                   └──────────────┘
       │ HTTP (localhost)
       ▼
┌──────────────┐
│ llama-server │
│ (GGUF model) │
└──────────────┘
```

## License

[AGPL-3.0](LICENSE)
