# Inference Pool (Solair)

Decentralized AI inference on Apple Silicon. Native macOS MenuBarExtra app that turns any Mac into a node in a peer-to-peer inference network.

## Project Status

### Phase 1 — Local Inference (Complete)
- MenuBarExtra SwiftUI app with dashboard, chat, model browser, settings
- MLX-based inference via mlx-swift-lm (streaming token generation)
- Model catalog with 10 curated models (1B-70B params)
- HuggingFace Hub download + local cache management
- OpenAI-compatible HTTP API at localhost:11435 (Hummingbird)
- Hardware detection (chip, RAM, GPU cores, memory bandwidth)
- Adaptive throttling (thermal, battery, user activity, network)

### Phase 2 — LAN Cluster (Complete)
- ClusterKit module: mDNS/Bonjour discovery, NWConnection transport, custom message framer
- Peer handshake with optional passcode authentication
- Heartbeat health monitoring (5s/15s/30s intervals)
- Request routing to best available node (model loaded, not throttled, highest capability)
- ClusterProvider: InferenceProvider that routes to local or remote transparently
- Model sharing over LAN (1MB chunked file transfer)
- Cluster UI: peer cards, stats, enable/disable toggle

### Phase 3+ — Not started
- WAN P2P (rust-libp2p, QUIC, NAT traversal)
- Credit economy
- iOS companion app

## Architecture

8 Swift modules in a single Package.swift:

| Module | Purpose |
|--------|---------|
| SharedTypes | Protocols, API types, hardware types (no deps) |
| HardwareProfile | Chip/RAM/GPU detection, thermal/power/activity monitors |
| MLXInference | MLX wrapper, HF downloader, tokenizer adapter |
| ModelManager | Model catalog, cache, download service |
| InferenceEngine | Provider-agnostic engine manager + adaptive throttler |
| ClusterKit | LAN discovery, transport, cluster orchestration, routing |
| LocalAPI | Hummingbird HTTP server, OpenAI-compatible endpoints |
| InferencePoolApp | SwiftUI MenuBarExtra app (executable) |

## Key Patterns

- `InferenceProvider` protocol is the core abstraction — MLXProvider and ClusterProvider both conform
- `InferenceEngineManager` accepts `any InferenceProvider`, swappable at runtime
- ClusterKit uses Network.framework (NWListener/NWBrowser/NWConnection) with custom NWProtocolFramer
- All inter-node messages are length-prefixed JSON over persistent TCP connections

## Building

```bash
swift build          # CLI build (works, 86MB binary)
# Open Package.swift in Xcode for full app experience (MenuBarExtra needs app bundle)
```

## Dependencies

- mlx-swift (0.31.x) — Apple's ML framework for Apple Silicon
- mlx-swift-lm (main) — LLM/VLM model loading and generation
- swift-transformers (0.1.x) — Tokenizer + HuggingFace Hub
- hummingbird (2.x) — HTTP server

## Notes

- Targets macOS 14+ (Sonoma) for SwiftData compatibility
- SwiftPM can't compile Metal shaders — use Xcode for full builds
- Tests require Xcode SDK (XCTest not available with Command Line Tools only)
- Conversation persistence uses in-memory store (SwiftData version needs Xcode)
