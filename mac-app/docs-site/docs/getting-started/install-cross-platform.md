# Cross-Platform Install

Install teale-node on Linux, Windows, or Android. teale-node is a single Rust binary (6.2 MB) that brings full Teale network participation to non-Apple platforms.

---

## Supported hardware

teale-node supports a wide range of GPU and CPU backends:

| Backend | Platforms | Notes |
|---------|-----------|-------|
| **NVIDIA (CUDA)** | Linux, Windows | Requires CUDA 12.0+ and driver 525+ |
| **AMD (ROCm)** | Linux | Requires ROCm 5.7+ |
| **Intel (SYCL)** | Linux, Windows | Requires oneAPI runtime |
| **Vulkan** | Linux, Windows, Android | Broad GPU support via Vulkan 1.2+ |
| **CPU-only** | All platforms | Works everywhere, slower inference |

## Install

### Cargo (from source)

```bash
cargo install teale-node
```

### Binary download

Download the latest binary for your platform from [GitHub Releases](https://github.com/teale-ai/teale-node/releases):

- Linux x86_64 (CUDA, ROCm, Vulkan, CPU)
- Linux aarch64 (Vulkan, CPU)
- Windows x86_64 (CUDA, Vulkan, CPU)
- Android aarch64 (Vulkan, CPU)

### Docker

CPU variant:

```bash
docker run -d --name teale teale/node
```

CUDA variant (requires NVIDIA Container Toolkit):

```bash
docker run -d --gpus all --name teale teale/node:cuda
```

## Configuration

On first run, teale-node generates an Ed25519 identity keypair and writes a default configuration file. The config lives at `~/.teale/config.toml` (or `%APPDATA%\Teale\config.toml` on Windows).

teale-node uses the same relay protocol as the macOS app, so cross-platform nodes participate in the same network as Mac and iPhone users.

```bash
# Start the node
teale-node up

# Check status
teale-node status

# View or edit configuration
teale-node config show
```

### Key configuration options

```toml
[network]
relay = "auto"          # Auto-discover relays, or set a specific relay address
max_connections = 32

[inference]
backend = "auto"        # auto, cuda, rocm, sycl, vulkan, cpu
max_memory_gb = 8       # Maximum VRAM/RAM to use for models

[identity]
# Auto-generated on first run. Do not edit.
# keypair = "~/.teale/identity.key"
```

## Verify

```bash
teale-node status
```

You should see the node status, detected GPU backend, and network connectivity.

## Uninstall

```bash
cargo uninstall teale-node
rm -rf ~/.teale
```

Or remove the binary and data directory manually.

---

## Next steps

- [Quickstart: API](quickstart-api.md) --- use the OpenAI-compatible API
- [Quickstart: Earn](quickstart-earn.md) --- contribute compute and earn USDC
