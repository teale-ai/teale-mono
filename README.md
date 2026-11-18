# teale-mono

Monorepo for Teale: a distributed inference network that serves open-weight
models through an OpenAI-compatible gateway (including as an OpenRouter
provider), plus the desktop, mobile and node clients that supply and consume it.

## Layout

```
teale-mono/
├── Cargo.toml / Cargo.lock   # Rust workspace: node, node/teale-tray, protocol,
│                             # gateway, stress, cli
├── protocol/    # Rust crate (teale-protocol): wire types shared by node, gateway, cli
├── node/        # Rust binary (teale-node): supply-side agent (Mac / Linux / Windows / Android)
│   ├── teale-tray/     # Rust binary: Windows/Linux tray + desktop companion window
│   ├── installer/      # Inno Setup script + PowerShell for the Windows Teale.exe
│   └── linux-desktop/  # Linux desktop bundle packaging (build-package.sh, install.sh)
├── gateway/     # Rust binary (teale-gateway): OpenAI-compatible HTTP gateway at
│                # gateway.teale.com (SQLite ledger, device auth, wallet, PINs)
├── stress/      # Rust binary (teale-stress): load + fault-injection test runner
├── cli/         # Rust binary (`teale`, crate teale-cli): status, supply, models,
│                # wallet, PINs, `teale mcp`; bundled into the Mac app
├── relay/       # TypeScript (Bun): WebSocket rendezvous server at relay.teale.com
├── mac-app/     # Swift: macOS app + iOS companion (SwiftPM); docs-site/ is the
│                # Docusaurus user documentation
├── android-app/ # Kotlin / Jetpack Compose: Android client (chat, wallet, groups,
│                # supply mode with llama.cpp + teale-node bundled)
├── tools/       # goose-pilot (goose agent on Teale dogfood), perf-gate (canary bench)
├── scripts/     # Fleet benchmarks, mesh cluster runner, calibration observer,
│                # network visualiser (one-off ops scripts, not part of any build)
├── docs/        # Design docs, runbooks, protocol specs, planning notes
└── .github/     # Workflows, llama-cpp-version pin, CODEOWNERS, dependabot, PR template
```

Rust components form one Cargo workspace (`cargo build --workspace` at the
root). Relay is a Bun package (`bun install` in `relay/`). Mac-app is a SwiftPM
package (`swift build` from `mac-app/`). Android-app is a Gradle project
(`./gradlew assembleDebug` from `android-app/`).

## Consuming inference

Anyone can call the gateway - no invite: `docs/consuming-inference.md`
(self-serve device key -> welcome credits -> OpenAI-compatible API ->
earn-by-supplying or USDC top-up at zero).

## Quick start

```bash
# Build every Rust binary
cargo build --workspace --release

# Run the gateway locally (expects a running relay + nodes)
GATEWAY_TOKENS=tok_dev:internal cargo run -p teale-gateway -- --config gateway/gateway.toml

# Run a stress scenario against a deployed gateway
export GATEWAY_DEV_TOKEN=tok_dev_xxx
cargo run -p teale-stress --release -- run \
  --scenario stress/scenarios/steady_state.toml --out runs/

# Node + backend (local)
cargo run -p teale-node -- --config node/teale-node.example.toml

# CLI
cargo run -p teale-cli -- status

# Relay
cd relay && bun install && bun run server.ts

# Mac app
cd mac-app && swift build

# Android app (debug APK on a plugged-in device)
cd android-app && ./gradlew installDebug
# Full pre-release flow (cross-compile node + push Gemma GGUF + install),
# still from android-app/:
./scripts/deploy-pixel.sh
```

## CI and release workflows

Path-filtered: a Rust-only PR does not trigger the Swift build.

| Workflow | Trigger | What it does |
|---|---|---|
| `rust.yml` | push to `main` / PRs touching `cli/`, `node/`, `protocol/`, `gateway/`, `stress/`, `Cargo.toml`, `Cargo.lock` | fmt, clippy `-D warnings`, `cargo test --workspace`, release builds |
| `relay.yml` | push to `main` / PRs touching `relay/` | Bun install, type-check, `bun test` |
| `mac-app.yml` | push to `main` / PRs touching `mac-app/` | `swift build` + `swift test` on macos-15 |
| `gateway-deploy.yml` | after `rust` succeeds on `main` (only if gateway inputs changed), or manual | Fly deploy of the gateway (environment `production`) |
| `relay-deploy.yml` | after `relay` succeeds on `main` (only if `relay/` changed), or manual | Fly deploy of the relay (environment `production`) |
| `desktop-release.yml` | `teale-*` tag | creates the GitHub release, then calls the Windows and Linux builds |
| `windows-installer.yml` | called by `desktop-release.yml`, or manual (artifact only) | builds `Teale.exe` + `checksums.txt` |
| `linux-desktop.yml` | called by `desktop-release.yml`, or manual (artifact only) | builds `Teale-linux-x86_64.tar.gz` + checksums |
| `mac-app-release.yml` | `mac-v*` tag, or manual | Developer ID signed (not notarized) `Teale.dmg` / `Teale.zip`, standalone `teale` CLI, tag-pinned `install.sh`, `checksums.txt` |
| `mac-app-testflight.yml` | `ios-v*` tag, or manual | TestFlight upload of the iOS companion (skips with a notice until its secrets are configured) |
| `kv-eval.yml` | manual | MLX KV-quant eval on macos-15 |
| `gateway-log-capture.yml` | manual | captures a window of Fly gateway logs as an artifact |

The llama.cpp version bundled by the desktop and Android builds is pinned in
`.github/llama-cpp-version`.

## Deploying

Gateway and relay deploy automatically from `main` after CI passes (see
above). Manual deploys:

### gateway.teale.com

```bash
# from the repo root: the Dockerfile builds from the whole workspace
flyctl deploy --remote-only --config gateway/fly.toml --dockerfile gateway/Dockerfile
```

### relay.teale.com

```bash
cd relay
flyctl deploy --remote-only --config fly.toml --dockerfile Dockerfile
```

### Desktop and Mac releases

- Windows + Linux: push a `teale-YYYY.MM.DD.HHMM` tag.
- macOS: push a `mac-vYYYY.MM.DD.HHMM` tag.

`teale-*` and `mac-v*` releases share one GitHub release list, so
`releases/latest` may be either platform; link to tag-filtered lists instead.

### Supply nodes from source

```bash
cargo build --release -p teale-node
# then point at a teale-node.toml with your config (see node/teale-node.*.toml)
```

### Android client (sideload)

No APK is committed to the repo. Build one with Gradle (see above) or use
`android-app/scripts/deploy-pixel.sh` for the one-shot build + push +
install flow; `android-app/SIDELOAD.md` covers installing a provided APK.
Five UI locales ship out of the box: en, pt-BR, zh-CN, fil, es.

## Docs

- `docs/consuming-inference.md` - calling the gateway
- `docs/openrouter-open-weight-catalog.md` - demand side (open-weight models)
- `docs/mac-fleet-configurations.md` - supply side (chip x RAM x bandwidth)
- `docs/device-model-matrix.md` - routing source of truth
- `docs/device-earnings-cards.md` - recruiting pitch (per-config $/mo)
- `docs/openrouter-provider-gap-analysis.md` - applicable-requirements tracker
- `docs/openrouter-application-rehearsal.md` - submission draft
- `docs/openrouter-oncall-runbook.md` - on-call playbook
- `docs/protocol.md` - relay + cluster wire protocol spec
- `docs/ledger-verifiability.md` - Solana-anchored credit ledger (merkle roots, no token)
- `docs/passwordless-auth-migration.md` - email-code / gateway account sessions
- `mac-app/docs-site/` - end-user install and usage docs
