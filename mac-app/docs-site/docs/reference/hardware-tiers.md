# Hardware Tiers

Device classification and chip family reference.

## Device Tiers

| Tier | Name | Examples | Role |
|------|------|----------|------|
| 1 | Backbone | Mac Studio, Mac Pro, Linux servers with NVIDIA/AMD GPU | Always-on inference nodes. Serve large models, high throughput. |
| 2 | Desktop | MacBook Pro, Mac Mini, Linux/Windows desktops with GPU | Primary compute. Available when in use, may sleep. |
| 3 | Tablet | iPad Pro (M-series), high-end Android tablets | Light inference. Small models only, intermittent availability. |
| 4 | Phone/Leaf | iPhone, Android phones, single-board computers | Consumer only. Requests inference but does not serve it. |

Tier numbering is inverted: tier 1 is the highest capability. When filtering peers with `minTier`, a value of 2 means "tier 2 or better" (tiers 1 and 2).

## Chip Family Reference

### Apple Silicon -- Mac

| Chip | Family | Generation | GPU Cores | Max RAM | Bandwidth | Watts | Tier |
|------|--------|-----------|-----------|---------|-----------|-------|------|
| Apple M1 | `m1` | 1 | 7-8 | 16 GB | 68 GB/s | 20W | 2 |
| Apple M1 Pro | `m1Pro` | 1 | 14-16 | 32 GB | 200 GB/s | 30W | 2 |
| Apple M1 Max | `m1Max` | 1 | 24-32 | 64 GB | 400 GB/s | 40W | 1-2 |
| Apple M1 Ultra | `m1Ultra` | 1 | 48-64 | 128 GB | 800 GB/s | 60W | 1 |
| Apple M2 | `m2` | 2 | 8-10 | 24 GB | 100 GB/s | 22W | 2 |
| Apple M2 Pro | `m2Pro` | 2 | 16-19 | 32 GB | 200 GB/s | 35W | 2 |
| Apple M2 Max | `m2Max` | 2 | 30-38 | 96 GB | 400 GB/s | 45W | 1-2 |
| Apple M2 Ultra | `m2Ultra` | 2 | 60-76 | 192 GB | 800 GB/s | 65W | 1 |
| Apple M3 | `m3` | 3 | 8-10 | 24 GB | 100 GB/s | 22W | 2 |
| Apple M3 Pro | `m3Pro` | 3 | 14-18 | 36 GB | 150 GB/s | 36W | 2 |
| Apple M3 Max | `m3Max` | 3 | 30-40 | 128 GB | 400 GB/s | 48W | 1-2 |
| Apple M3 Ultra | `m3Ultra` | 3 | 60-80 | 192 GB | 800 GB/s | 70W | 1 |
| Apple M4 | `m4` | 4 | 10 | 32 GB | 120 GB/s | 22W | 2 |
| Apple M4 Pro | `m4Pro` | 4 | 16-20 | 48 GB | 273 GB/s | 38W | 2 |
| Apple M4 Max | `m4Max` | 4 | 32-40 | 128 GB | 546 GB/s | 50W | 1-2 |
| Apple M4 Ultra | `m4Ultra` | 4 | 64-80 | 256 GB | 819 GB/s | 75W | 1 |

### Apple Silicon -- iPhone/iPad

| Chip | Family | Generation | Watts | Tier |
|------|--------|-----------|-------|------|
| Apple A14 Bionic | `a14` | 14 | 5W | 4 |
| Apple A15 Bionic | `a15` | 15 | 5W | 4 |
| Apple A16 Bionic | `a16` | 16 | 6W | 4 |
| Apple A17 Pro | `a17Pro` | 17 | 6W | 4 |
| Apple A18 | `a18` | 18 | 7W | 4 |
| Apple A18 Pro | `a18Pro` | 18 | 7W | 4 |
| Apple A19 Pro | `a19Pro` | 19 | 8W | 4 |

iPads with M-series chips (M1, M2, M4) use the Mac chip families and are classified as tier 3.

### Non-Apple

| Chip Type | Family | Watts | Tier | GPU Backend |
|-----------|--------|-------|------|-------------|
| NVIDIA GPU (RTX 3090/4090 class) | `nvidiaGPU` | 300W | 1 | `cuda` |
| AMD GPU (RX 7900 class) | `amdGPU` | 250W | 1 | `rocm` |
| Intel CPU (desktop) | `intelCPU` | 65W | 2 | `cpu` or `sycl` |
| AMD CPU (desktop) | `amdCPU` | 65W | 2 | `cpu` |
| ARM Generic (Snapdragon, RPi) | `armGeneric` | 10W | 3-4 | `cpu` or `vulkan` |
| Unknown | `unknown` | 30W | 2 | `cpu` |

## RAM and Model Capacity

The available RAM for model loading is:

```
availableRAMForModelsGB = max(totalRAMGB - 4.0, 1.0)
```

| Total RAM | Available for Models | Largest Model (q4) |
|-----------|---------------------|---------------------|
| 8 GB | 4 GB | Llama 3.2 3B (1.8 GB) |
| 16 GB | 12 GB | Llama 3.1 8B (4.5 GB) or Phi 4 14B (8 GB) |
| 32 GB | 28 GB | Qwen 3 32B (18 GB) |
| 48 GB | 44 GB | Qwen 3 32B (18 GB) + spare |
| 64 GB | 60 GB | Llama 4 Scout 109B MoE (56 GB) |
| 128 GB | 124 GB | Multiple large models simultaneously |
| 192 GB | 188 GB | Any model or combination |

For discrete GPUs (`gpuVRAMGB` field), the VRAM limit determines maximum model size, independent of system RAM.
