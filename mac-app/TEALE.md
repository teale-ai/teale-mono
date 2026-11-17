# Teale — Project Overview

Decentralized AI inference on Apple Silicon. Native macOS app that turns any Mac into a node in a peer-to-peer inference network.

The macOS UI is the shared desktop companion web bundle
(`Sources/InferencePoolApp/Resources/DesktopCompanionWeb/`: `index.html`,
`app.js`, `app.css`) rendered in a WKWebView, plus a SwiftUI MenuBarExtra
with quick supply controls. The same bundle is embedded by the Windows/Linux
tray (`node/teale-tray`), so UI changes there ship on all desktop platforms.
The bundle talks to the local API on `127.0.0.1:11435` (contract shared with
the Rust node; only the bundled `teale://localhost` origin may call it from a
browser context).

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
- AuthKit module: gateway-native passwordless email auth (code + magic link, tsess_ sessions)
- macOS: sign in from the companion's account view (email code, proxied by
  the local API) or by opening the emailed `teale://auth/session?token=…`
  magic link, which AuthManager adopts natively
- The session token is stored in the Keychain in release builds (a 0600 file
  under Application Support in debug builds); account links send it as
  `X-Teale-Account-Session` to prove account ownership
- Anonymous mode: the app works without an account (device wallet only)
- Supabase (Apple / phone / OAuth sign-in, device registry, transfer RPC) was
  removed in 2026.09 after the Supabase project was decommissioned, including
  the Supabase client in the web bundle; the device registry returns with
  gateway account endpoints.

## Architecture

25 targets in a single `Package.swift` (22 libraries, 3 executables) plus
15 test targets under `Tests/`:

| Target | Kind | Purpose |
|--------|------|---------|
| SharedTypes | library | Protocols, API types, hardware/model types (no deps) |
| HardwareProfile | library | Chip/RAM/GPU detection, thermal/power/activity monitors |
| MLXInference | library | MLX wrapper, HF downloader, tokenizer adapter |
| ModelManager | library | Model catalog, cache, download service |
| LlamaCppKit | library | llama.cpp subprocess + HTTP provider |
| RapidMLXKit | library | rapid-mlx subprocess + HTTP provider |
| InferenceEngine | library | Provider-agnostic engine manager + adaptive throttler |
| ClusterKit | library | LAN discovery, transport, cluster orchestration, routing |
| WANKit | library | WAN P2P (relay signaling, Noise sessions, NAT traversal) |
| CompilerKit | library | Mixture-of-models request compilation and fan-out |
| CreditKit | library | Local credit ledger, pricing, analytics |
| WalletKit | library | Solana USDC integration |
| AgentKit | library | Agent-to-agent protocol, negotiation, directory |
| ChatKit | library | P2P encrypted group chat |
| GatewayKit | library | Gateway device identity, device auth, account sessions |
| AuthKit | library | Gateway-native passwordless auth (AuthManager), iOS LoginView |
| PrivacyFilterKit | library | Desktop-local privacy filter orchestration |
| PINKit | library | Private Inference Networks client |
| LocalAPI | library | Hummingbird server on :11435: OpenAI-compatible + desktop companion routes |
| AppCore | library | Shared headless orchestration (AppState, RemoteControlBridge, updater) |
| TealeSDK | library | Third-party resource contribution SDK |
| TealeSDKUI | library | Pre-built SwiftUI views for TealeSDK |
| Teale | executable | macOS app (sources in `Sources/InferencePoolApp/`) |
| TealeCompanion | executable | iOS companion app |
| TealeEval | executable | KV-quantization eval harness (`teale-eval`) |

The `teale` command-line tool bundled into `Teale.app` as `teale-cli` is
the Rust CLI from the repo root (`cli/`), not a Swift target.

## Key Patterns

- `InferenceProvider` protocol is the core abstraction — MLXProvider and ClusterProvider both conform
- `InferenceEngineManager` accepts `any InferenceProvider`, swappable at runtime
- ClusterKit uses Network.framework (NWListener/NWBrowser/NWConnection) with custom NWProtocolFramer
- All inter-node messages are length-prefixed JSON over persistent TCP connections

## Dependencies

- mlx-swift (0.21.x) — Apple's ML framework for Apple Silicon
- mlx-swift-lm (main) — LLM/VLM model loading and generation
- swift-transformers (0.1.x) — Tokenizer + HuggingFace Hub
- hummingbird (2.x) + swift-http-types — local HTTP server
- solana-swift (5.x) — WalletKit USDC integration

## Build Notes

- Targets macOS 14+ (Sonoma) and iOS 17+
- `Info.plist` version keys are placeholders; `bundle.sh` stamps
  CFBundleShortVersionString / CFBundleVersion (YYYYMMDDHHMM) at bundle time,
  and the updater compares that build number with `mac-vYYYY.MM.DD.HHMM` tags
- SwiftPM can't compile Metal shaders — use Xcode for full builds
- Tests require Xcode SDK (XCTest not available with Command Line Tools only)
- Conversation persistence uses in-memory store (SwiftData version needs Xcode)
