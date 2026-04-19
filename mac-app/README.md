# teale-mac-app (archived)

> **This repository has been consolidated into
> [teale-ai/teale-mono](https://github.com/teale-ai/teale-mono).**
>
> All history was preserved in the new repo via `git filter-repo`:
>
> - Swift macOS + iOS app sources → [`teale-mono/mac-app/`](https://github.com/teale-ai/teale-mono/tree/main/mac-app)
> - Relay server (Bun/TypeScript) → [`teale-mono/relay/`](https://github.com/teale-ai/teale-mono/tree/main/relay)
>
> `git log --follow` in `teale-mono` on any moved file traces back to the
> original commits here.
>
> The monorepo also adds new Rust components (protocol, node supply agent,
> OpenAI-compatible gateway, stress harness) alongside the Swift and
> TypeScript code. See the [teale-mono README](https://github.com/teale-ai/teale-mono#readme).
>
> Open issues / PRs here are read-only. Continue new work in `teale-mono`.

---

## Former README (for reference)

Native macOS and iOS app for [Teale](https://teale.com) — decentralized AI
inference on Apple Silicon. 13 Swift modules powering on-device MLX inference,
LAN cluster discovery, WAN relay peer-to-peer, wallet + credits, and an
OpenAI-compatible local API.

See [`teale-mono/mac-app/TEALE.md`](https://github.com/teale-ai/teale-mono/blob/main/mac-app/TEALE.md)
for the detailed architecture doc (moved from this repo's root).
