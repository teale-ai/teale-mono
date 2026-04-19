# Node Capabilities

Schema for advertising node hardware, loaded models, and availability.

## NodeCapabilities

The top-level capabilities object sent during registration and returned in discovery responses.

```json
{
  "hardware": { ...HardwareCapability... },
  "loadedModels": ["mlx-community/Qwen3-8B-4bit"],
  "maxModelSizeGB": 20.0,
  "isAvailable": true,
  "ptnIDs": ["a1b2c3..."]
}
```

| Field | Type | Description |
|-------|------|-------------|
| `hardware` | object | HardwareCapability profile |
| `loadedModels` | array | Model IDs currently loaded and ready for inference |
| `maxModelSizeGB` | number | Largest model this node can load (GB) |
| `isAvailable` | boolean | Whether the node is accepting inference requests |
| `ptnIDs` | array | Private TealeNet IDs this node belongs to |

## HardwareCapability

Describes the node's hardware profile.

```json
{
  "chipFamily": "m4Pro",
  "chipName": "Apple M4 Pro",
  "totalRAMGB": 48.0,
  "gpuCoreCount": 20,
  "memoryBandwidthGBs": 273.0,
  "tier": 2,
  "gpuBackend": "metal",
  "platform": "macOS",
  "gpuVRAMGB": null
}
```

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `chipFamily` | string | Yes | One of the chip family values below |
| `chipName` | string | Yes | Human-readable chip name (e.g., "Apple M4 Pro", "NVIDIA RTX 4090") |
| `totalRAMGB` | number | Yes | Total system RAM in gigabytes |
| `gpuCoreCount` | number | Yes | Number of GPU cores |
| `memoryBandwidthGBs` | number | Yes | Estimated memory bandwidth in GB/s |
| `tier` | number | Yes | Device tier: 1 (backbone), 2 (desktop), 3 (tablet), 4 (phone/leaf) |
| `gpuBackend` | string | No | GPU compute backend (optional, inferred from chipFamily for Apple devices) |
| `platform` | string | No | Operating system (optional, inferred from compile target) |
| `gpuVRAMGB` | number | No | Discrete GPU VRAM in GB (null for unified memory architectures) |

### Derived Properties

**Available RAM for models:**

```
availableRAMForModelsGB = max(totalRAMGB - 4.0, 1.0)
```

The 4 GB reservation accounts for OS and background processes.

**Estimated inference watts:** Power draw during active inference, used for [electricity floor pricing](pricing-protocol.md).

## Chip Family Values

### Apple Silicon -- Mac

| Value | Chip |
|-------|------|
| `m1` | Apple M1 |
| `m1Pro` | Apple M1 Pro |
| `m1Max` | Apple M1 Max |
| `m1Ultra` | Apple M1 Ultra |
| `m2` | Apple M2 |
| `m2Pro` | Apple M2 Pro |
| `m2Max` | Apple M2 Max |
| `m2Ultra` | Apple M2 Ultra |
| `m3` | Apple M3 |
| `m3Pro` | Apple M3 Pro |
| `m3Max` | Apple M3 Max |
| `m3Ultra` | Apple M3 Ultra |
| `m4` | Apple M4 |
| `m4Pro` | Apple M4 Pro |
| `m4Max` | Apple M4 Max |
| `m4Ultra` | Apple M4 Ultra |

### Apple Silicon -- iPhone/iPad

| Value | Chip |
|-------|------|
| `a14` | Apple A14 Bionic |
| `a15` | Apple A15 Bionic |
| `a16` | Apple A16 Bionic |
| `a17Pro` | Apple A17 Pro |
| `a18` | Apple A18 |
| `a18Pro` | Apple A18 Pro |
| `a19Pro` | Apple A19 Pro |

### Non-Apple (Cross-Platform)

| Value | Description |
|-------|-------------|
| `nvidiaGPU` | NVIDIA GPU (CUDA) |
| `amdGPU` | AMD GPU (ROCm) |
| `intelCPU` | x86_64 Intel CPU |
| `amdCPU` | x86_64 AMD CPU |
| `armGeneric` | ARM64 non-Apple (Snapdragon, Raspberry Pi, etc.) |
| `unknown` | Undetected or unsupported hardware |

## Estimated Inference Watts

Power consumption estimates during active inference workloads, by chip family.

| Chip Family | Watts | Notes |
|-------------|-------|-------|
| M1 | 20W | |
| M1 Pro | 30W | |
| M1 Max | 40W | |
| M1 Ultra | 60W | |
| M2 | 22W | |
| M2 Pro | 35W | |
| M2 Max | 45W | |
| M2 Ultra | 65W | |
| M3 | 22W | |
| M3 Pro | 36W | |
| M3 Max | 48W | |
| M3 Ultra | 70W | |
| M4 | 22W | |
| M4 Pro | 38W | |
| M4 Max | 50W | |
| M4 Ultra | 75W | |
| A14, A15 | 5W | iPhone/iPad |
| A16, A17 Pro | 6W | iPhone/iPad |
| A18, A18 Pro | 7W | iPhone/iPad |
| A19 Pro | 8W | iPhone/iPad |
| NVIDIA GPU | 300W | Typical RTX 3090/4090 TDP |
| AMD GPU | 250W | Typical AMD GPU TDP |
| Intel CPU | 65W | Typical desktop CPU |
| AMD CPU | 65W | Typical desktop CPU |
| ARM Generic | 10W | Low-power ARM (Snapdragon, RPi) |
| Unknown | 30W | Conservative estimate |

## GPU Backend Values

| Value | Description |
|-------|-------------|
| `metal` | Apple Metal (macOS/iOS) |
| `cuda` | NVIDIA CUDA |
| `rocm` | AMD ROCm |
| `vulkan` | Vulkan (cross-platform) |
| `sycl` | Intel SYCL |
| `cpu` | CPU-only fallback |

## Platform Values

| Value | Description |
|-------|-------------|
| `macOS` | macOS |
| `iOS` | iOS / iPadOS |
| `linux` | Linux |
| `windows` | Windows |
| `android` | Android |
| `freebsd` | FreeBSD |

## Device Tiers

| Tier | Name | Examples | Role |
|------|------|----------|------|
| 1 | Backbone | Mac Studio, Mac Pro, Linux servers with GPU | Always-on inference nodes |
| 2 | Desktop | MacBook Pro, Mac Mini, Linux/Windows desktops with GPU | Primary compute |
| 3 | Tablet | iPad Pro (M-series), high-end Android tablets | Light inference |
| 4 | Phone/Leaf | iPhone, Android phones, SBCs | Consumer only |

Tier numbering is inverted: tier 1 is the highest capability. When filtering with `minTier`, a value of 2 means "tier 2 or better" (i.e., tier 1 and tier 2).
