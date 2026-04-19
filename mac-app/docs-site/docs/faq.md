# Frequently Asked Questions

Common questions about Teale.

## Models and Hardware

### What models can I run?

It depends on your device's RAM. Teale reserves 4 GB for the OS, and the rest is available for models:

| RAM | Recommended Models |
|-----|-------------------|
| 8 GB | Llama 3.2 1B, Llama 3.2 3B |
| 16 GB | Llama 3.1 8B, Qwen 3 8B, Phi 4 14B |
| 32 GB | Mistral Small 24B, Gemma 3 27B, Qwen 3 32B |
| 64 GB+ | Llama 4 Scout 109B (MoE), or multiple large models simultaneously |

See [Supported Models](reference/supported-models.md) for the full catalog.

### Does it work without internet?

Yes. Local inference always works -- Teale runs models directly on your device with no network required. The internet is only needed for WAN features: discovering remote peers, earning USDC, and accessing models on other devices.

### Can I use this with ChatGPT-compatible tools?

Yes. Teale exposes an OpenAI-compatible API at `localhost:11435`. Any tool that works with the OpenAI API can point to Teale instead:

```python
from openai import OpenAI

client = OpenAI(
    base_url="http://localhost:11435/v1",
    api_key="your-teale-api-key"
)
```

This works with LangChain, LlamaIndex, Continue.dev, Cursor, and other OpenAI-compatible tools. See [Use with OpenAI SDK](guides/use-with-openai-sdk.md) for details.

## App and CLI

### What is the difference between the app and CLI?

Full feature parity. The macOS app has a GUI (menu bar extra) for managing models, peers, and settings visually. The CLI (`teale`) is for headless servers, automation, and terminal workflows. Both use the same local HTTP API under the hood.

### How do I run on Linux?

Use `teale-node`, the Rust cross-platform binary. It provides the same inference capabilities using llama.cpp with GGUF models instead of MLX.

```bash
curl -fsSL https://teale.com/install.sh | sh
teale up
```

## Networking

### Is the relay server a single point of failure?

No. The relay is optional. LAN discovery works without it (via Bonjour/mDNS). WAN connections work peer-to-peer when NAT allows direct connections. The relay is only needed for WAN discovery and for fallback data transport when both peers are behind symmetric NAT.

If the relay goes down, existing peer connections continue working. Only new peer discovery over WAN is affected.

### What is a PTN?

A Private TealeNet (PTN) is an invite-only subnet with certificate-based membership. PTNs allow teams or organizations to create a private inference network with:

- **Controlled access** -- only invited members can join
- **Fixed pricing** -- no auction, predictable costs
- **Priority scheduling** -- PTN traffic gets 70% weight in WFQ scheduling
- **Certificate-based trust** -- Ed25519 CA signs membership certificates

See [Private TealeNet](concepts/private-tealenet.md) for details.

## Earnings and Pricing

### How much can I earn?

Earnings depend on your hardware, loaded models, uptime, and network demand. Providers earn 95% of the inference cost. Factors:

- **Larger models earn more per token** (8B earns 8x more than 1B per token)
- **More uptime = more requests served**
- **Better hardware attracts more traffic** (tier 1 and tier 2 nodes are preferred)
- **PTN membership provides steady demand**

Use `teale wallet` or the app's wallet view to track your earnings in real time.

### How does pricing work?

Token-based pricing with an electricity cost floor:

1. **Base price** = `(tokens / 1K) * (parameterCountB * 0.1) * quantMultiplier / 10,000`
2. **Electricity floor** = actual power cost + 20% margin
3. **Effective price** = max(base price, electricity floor)

Providers always earn at least enough to cover their electricity. See [Credit Economy](concepts/credit-economy.md) and [Pricing Tables](reference/pricing-tables.md) for details.

## Privacy and Security

### Is my data private?

Yes. Teale stores nothing centrally. All inference happens on-device or is routed peer-to-peer. When encryption is enabled (both peers support Noise protocol), communication is end-to-end encrypted with `Noise_IK_25519_ChaChaPoly_BLAKE2s`. The relay server sees only encrypted blobs -- it cannot read message contents.

There are no user accounts, no central databases, and no telemetry. Your prompts never leave your device unless you explicitly send them to a remote peer, and even then they are encrypted in transit.

### How does identity work?

Each node has an Ed25519 keypair. The public key is your node ID -- a 64-character hex string. There are no usernames, emails, or accounts. Identity is cryptographic and self-sovereign. See [Ed25519 Identity](protocol/ed25519-identity.md) for details.
