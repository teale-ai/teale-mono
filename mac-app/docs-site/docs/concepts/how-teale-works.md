# How Teale Works

Teale is a decentralized AI inference network that turns Apple Silicon Macs into compute nodes and connects them peer-to-peer with zero central servers.

## The big picture

Every Teale node can run inference locally, share it with nearby devices over LAN, or serve it across the internet to anyone in the network. There is no cloud backend. The relay server exists only for discovery and signaling --- it never sees your prompts or completions.

- **Mac = supply.** Macs run inference and earn USDC for serving requests.
- **iPhone = demand.** iPhones consume inference from local models or remote Macs.
- **No central storage.** Conversations, wallets, and keys live on-device. Nothing is stored on a server.

## The InferenceProvider chain

When you send a prompt, Teale tries to handle it as close to you as possible. The request flows through a chain of providers, each implementing the same `InferenceProvider` protocol, until one handles it:

```
Request
  |
  v
[MLXProvider] ---- On-device Apple MLX inference
  | (model not loaded or throttled)
  v
[LlamaCppProvider] ---- On-device llama.cpp subprocess
  | (no local capacity)
  v
[ClusterProvider] ---- LAN peer with model loaded and lower load
  | (no LAN peers available)
  v
[WANProvider] ---- WAN peer via relay or direct QUIC
  | (complex multi-model request)
  v
[Compiler] ---- Mixture of Models: decompose across multiple models
```

Each provider either handles the request and returns a streaming response, or passes it down the chain. The caller sees the same interface regardless of where inference actually runs.

## Module architecture

Teale is built as 24 Swift modules in a single Swift Package Manager workspace, plus a Rust cross-platform binary (`teale-node`) for Linux, Windows, and Android.

### Core modules

| Module | Purpose |
|--------|---------|
| **SharedTypes** | Protocols, API types, hardware types. Zero dependencies. |
| **HardwareProfile** | Chip/RAM/GPU detection, thermal and power monitors |
| **InferenceEngine** | Provider-agnostic engine manager and adaptive throttler |
| **MLXInference** | Apple MLX wrapper, HuggingFace downloader, tokenizer adapter |
| **LlamaCppKit** | llama.cpp subprocess management via HTTP, GGUF support |
| **ModelManager** | Model catalog, cache, and download service |

### Networking modules

| Module | Purpose |
|--------|---------|
| **ClusterKit** | LAN discovery (Bonjour), NWConnection transport, routing |
| **WANKit** | WAN P2P via QUIC, STUN/NAT traversal, relay signaling |
| **TealeNetKit** | Private TealeNet (PTN) certificate authority and membership |

### Economy and identity modules

| Module | Purpose |
|--------|---------|
| **CreditKit** | Credit economy, pricing, local ledger, wallet, analytics |
| **WalletKit** | Solana/USDC settlement, BIP39 key generation, deposit/withdrawal |
| **AuthKit** | Supabase auth, device management, Sign in with Apple + Phone OTP |

### Intelligence modules

| Module | Purpose |
|--------|---------|
| **CompilerKit** | Mixture of Models request compilation and fan-out execution |
| **AgentKit** | Agent-to-agent protocol, negotiation, directory |
| **ChatKit** | Encrypted group chat, message sync, tool connections |

### Interface modules

| Module | Purpose |
|--------|---------|
| **LocalAPI** | Hummingbird HTTP server, OpenAI-compatible endpoints at `localhost:11435` |
| **AppCore** | Shared app logic between macOS and iOS targets |
| **TealeSDK** | Embeddable SDK for third-party apps |
| **TealeSDKUI** | Pre-built SwiftUI components for TealeSDK |
| **InferencePoolApp** | macOS MenuBarExtra app (executable target) |
| **TealeCompanion** | iOS companion app (executable target) |
| **TealeCLI** | Command-line interface |

## Network tiers

Teale organizes connections into four tiers, keeping traffic as close to the user as possible:

1. **Local** --- On-device inference via MLX or llama.cpp. Zero latency, zero cost.
2. **LAN** --- Peers on the same local network, discovered via Bonjour/mDNS. Sub-millisecond latency, no internet required.
3. **PTN (Private TealeNet)** --- A private subnet of trusted nodes with CA-signed certificates. Gets 70% of scheduling priority.
4. **WWTN (Wider World Teale Network)** --- The public network of all Teale nodes. Market-priced via reverse auction.

## Key design decisions

**Protocol-first architecture.** The `InferenceProvider` protocol is the single abstraction that every backend implements. Adding a new inference source (CoreML, remote API, hardware accelerator) means implementing one protocol.

**Length-prefixed JSON over TCP.** All inter-node messages use a custom `NWProtocolFramer` that length-prefixes JSON payloads over persistent TCP connections. Simple, debuggable, and efficient.

**No tokens, no speculation.** The economy runs on USDC stablecoins. Providers earn 95% of the inference cost. There is no native token and no speculative element.

## Related pages

- [Inference Providers](inference-providers.md) --- deep dive into each provider
- [Networking](networking.md) --- LAN, WAN, and relay protocols
- [Credit Economy](credit-economy.md) --- pricing, auctions, and electricity floors
- [Security Model](security-model.md) --- encryption, identity, and trust
