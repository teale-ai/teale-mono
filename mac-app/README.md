# teale-mac-app

Native macOS and iOS app for [Teale](https://teale.com) — decentralized AI inference on Apple Silicon.

## What it does

- Run LLMs locally on your Mac using MLX (Apple's ML framework)
- Discover and connect to other Macs on your LAN for distributed inference
- Join the TealeNet WAN for peer-to-peer inference across the internet
- Earn credits by sharing your idle compute, spend them on remote inference
- OpenAI-compatible API at `localhost:11435`

## Platforms

- **macOS 14+** (Sonoma) — MenuBarExtra app
- **iOS 17+** — Companion app with on-device and remote inference

## Build

Requires Xcode (SwiftPM can't compile Metal shaders).

```bash
# CLI tool
swift build --product teale

# Full app — open in Xcode
open Package.swift
```

## Architecture

13 Swift modules: SharedTypes, HardwareProfile, MLXInference, ModelManager, InferenceEngine, ClusterKit, WANKit, CreditKit, AgentKit, AuthKit, LocalAPI, InferencePoolApp, TealeCompanion.

See [TEALE.md](TEALE.md) for detailed architecture and module documentation.

## Dependencies

- [mlx-swift](https://github.com/ml-explore/mlx-swift) — Apple's ML framework for Apple Silicon
- [mlx-swift-lm](https://github.com/ml-explore/mlx-swift-lm) — LLM/VLM model loading and generation
- [swift-transformers](https://github.com/huggingface/swift-transformers) — Tokenizer + HuggingFace Hub
- [hummingbird](https://github.com/hummingbird-project/hummingbird) — HTTP server
- [supabase-swift](https://github.com/supabase/supabase-swift) — Auth and database

## License

[AGPL-3.0](LICENSE)
