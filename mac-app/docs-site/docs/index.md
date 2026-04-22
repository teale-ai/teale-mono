---
slug: /
title: Teale Docs
---

# Teale

Turn your Mac into an AI inference node. Run models locally, earn by sharing compute, build on an open API.

---

## Get started

### Use Teale

Run AI models locally on your Mac with zero configuration. Chat with state-of-the-art models in seconds.

[Get started with chat](getting-started/quickstart-chat.md)

### Earn with Teale

Share your idle compute with the network and earn USDC. Your Mac works while you sleep.

[Start earning](getting-started/quickstart-earn.md)

### Build on Teale

OpenAI-compatible API at `localhost:11435`. Drop-in replacement for any app that speaks OpenAI.

[Explore the API](getting-started/quickstart-api.md)

### Use Teale from Conductor

Point Conductor workspace tools at `gateway.teale.com` and use hosted fleet models such as Kimi once they are available.

[Set up Conductor](guides/use-with-conductor.md)

---

## What is Teale?

Teale is a decentralized AI inference network. Macs run inference, iPhones consume it, all peer-to-peer with no central servers.

**Apple Silicon native.** Teale runs optimized inference on M1 and later chips, taking full advantage of the unified memory architecture and Neural Engine. Cross-platform support is available via [teale-node](getting-started/install-cross-platform.md), a Rust binary that runs on Linux, Windows, and Android with support for NVIDIA, AMD, and Intel GPUs.

**No central servers.** Every node connects directly to peers. There is no cloud backend, no data collection, no single point of failure. Your conversations never leave your device unless you explicitly route them through the network.

**End-to-end encrypted.** All network traffic between nodes uses E2E encryption with Ed25519 identities. No one --- not even relay operators --- can read your prompts or completions.

**USDC economy.** Providers earn 95% of inference costs, paid in USDC. Pricing is transparent and market-driven, based on compute cost. No tokens, no speculation.

**Open API.** Teale exposes an OpenAI-compatible API on `localhost:11435`. Any tool that works with OpenAI --- LangChain, LlamaIndex, Continue.dev, custom apps --- works with Teale out of the box.

---

## How it works

1. **Install Teale** on your Mac ([download](getting-started/install-mac.md)) or any platform ([cross-platform](getting-started/install-cross-platform.md)).
2. **Models download automatically** based on your available RAM.
3. **Chat locally** through the menu bar app, CLI, or API.
4. **Optionally join the network** to serve inference to others and earn USDC.

Teale organizes nodes into four network tiers --- local, LAN, personal trusted network, and the wider Teale network --- so traffic stays as close to you as possible.

---

## Next steps

- [Install on Mac](getting-started/install-mac.md)
- [Install the CLI](getting-started/install-cli.md)
- [Install on Linux/Windows](getting-started/install-cross-platform.md)
- [Quickstart: Chat](getting-started/quickstart-chat.md)
- [Quickstart: API](getting-started/quickstart-api.md)
- [Quickstart: Earn](getting-started/quickstart-earn.md)
- [Use with Conductor](guides/use-with-conductor.md)
