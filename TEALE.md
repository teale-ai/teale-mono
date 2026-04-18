# Teale — Project Overview

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

### Phase 3 — WAN P2P (Complete)
- WANKit module: pure-Swift WAN networking via QUIC (Network.framework)
- Ed25519 node identity (CryptoKit) with Keychain persistence
- Relay/signaling server client (WebSocket) for peer discovery
- STUN client for NAT type detection and public endpoint discovery
- NAT hole-punching with direct QUIC fallback to relay
- WANManager orchestrator, WANProvider implementing InferenceProvider
- WAN peer cards and status UI

### Phase 4 — Credit Economy (Complete)
- CreditKit module: local credit ledger with JSON persistence
- Token-based pricing: cost = (tokens/1K) * model_complexity * quant_multiplier
- Model complexity scales at 0.1x per billion params; earners get 95% (5% network fee)
- CreditWallet (@Observable) for SwiftUI, CreditAwareProvider middleware
- Welcome bonus of 100 credits for new users
- Wallet UI with balance, transactions, earning/spending summary
- CreditAnalytics for daily/weekly/monthly summaries

### Phase 5 — iOS Companion App (Complete)
- TealeCompanion executable target (iOS 17+)
- Dual-mode: on-device MLX inference + remote via HTTP API
- Bonjour discovery of LAN Macs, remote inference via URLSession
- Chat UI, Models tab, Network view, Wallet view, Settings
- On-device inference via MLXInference, ModelManager, InferenceEngine, HardwareProfile

### Phase 6 — Agent Protocol (Complete)
- AgentKit module: agent-to-agent communication protocol
- AgentProfile (personal/business/service), AgentCapability (8 well-known types)
- AgentMessage with 10 types: intent, offer, counterOffer, accept, reject, complete, review, chat, capability, status
- AgentConversation: state machine (initiated -> negotiating -> accepted -> completed)
- AgentNegotiator: auto-accept/reject within delegation rules, flag ambiguous for human
- AgentDirectory: discover agents by capability, ratings
- AgentRouter: transport-agnostic message routing with signing
- AgentManager: central orchestrator wiring everything together
- Agent UI: conversation list, message bubbles, directory view

### Phase 8 — Authentication & Device Management (Complete)
- AuthKit module: Supabase integration for user auth and device management
- Sign in with Apple + Phone/SMS OTP (no passwords)
- Anonymous mode: app works without account, local wallet only
- Device registration: devices auto-register to Supabase on sign-in
- Device management view: list devices, remove, transfer ownership
- Device transfer: atomic transfer via Supabase RPC, future credits go to new owner
- Auth gate on both macOS and iOS apps (login screen on first launch)
- Account section in Settings with sign-in/sign-out
- Supabase schema: profiles, devices, device_transfers tables with RLS
- SQL migration at supabase/migrations/001_auth_schema.sql

## Architecture

13 Swift modules in a single Package.swift:

| Module | Purpose |
|--------|---------|
| SharedTypes | Protocols, API types, hardware types (no deps) |
| HardwareProfile | Chip/RAM/GPU detection, thermal/power/activity monitors |
| MLXInference | MLX wrapper, HF downloader, tokenizer adapter |
| ModelManager | Model catalog, cache, download service |
| InferenceEngine | Provider-agnostic engine manager + adaptive throttler |
| ClusterKit | LAN discovery, transport, cluster orchestration, routing |
| WANKit | WAN P2P via QUIC, STUN/NAT traversal, relay signaling |
| CreditKit | Credit economy, ledger, pricing, wallet, analytics |
| AgentKit | Agent-to-agent protocol, negotiation, directory, conversations |
| AuthKit | Supabase auth, device management, Sign in with Apple + Phone OTP |
| LocalAPI | Hummingbird HTTP server, OpenAI-compatible endpoints |
| InferencePoolApp | SwiftUI MenuBarExtra app (executable, macOS) |
| TealeCompanion | iOS companion app (executable, iOS) |

## Key Patterns

- `InferenceProvider` protocol is the core abstraction — MLXProvider and ClusterProvider both conform
- `InferenceEngineManager` accepts `any InferenceProvider`, swappable at runtime
- ClusterKit uses Network.framework (NWListener/NWBrowser/NWConnection) with custom NWProtocolFramer
- All inter-node messages are length-prefixed JSON over persistent TCP connections

## Dependencies

- mlx-swift (0.21.x) — Apple's ML framework for Apple Silicon
- mlx-swift-lm (main) — LLM/VLM model loading and generation
- swift-transformers (0.1.x) — Tokenizer + HuggingFace Hub
- hummingbird (2.x) — HTTP server
- supabase-swift (2.x) — Auth, database, realtime (Supabase BaaS)

## Build Notes

- Targets macOS 14+ (Sonoma) for SwiftData compatibility
- SwiftPM can't compile Metal shaders — use Xcode for full builds
- Tests require Xcode SDK (XCTest not available with Command Line Tools only)
- Conversation persistence uses in-memory store (SwiftData version needs Xcode)
