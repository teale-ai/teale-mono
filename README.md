# teale-mono

Monorepo for Teale's OpenRouter provider stack. Five deployable components
plus one shared protocol crate.

## Layout

```
teale-mono/
├── protocol/    # Rust crate — wire types shared across node, gateway, relay
├── node/        # Rust binary — supply-side agent (Mac / Linux / Windows / Android)
├── gateway/     # Rust binary — OpenAI-compat HTTP gateway at gateway.teale.com
│                 (SQLite ledger, device auth, wallet, groups — see
│                  `gateway/src/ledger.rs`)
├── stress/      # Rust binary — load + fault-injection test runner
├── relay/       # TypeScript (Bun) — WebSocket rendezvous server at relay.teale.com
├── mac-app/     # Swift — macOS/iOS client app
└── android-app/ # Kotlin / Jetpack Compose — Android client (chat + wallet +
                 # groups + supply mode with llama.cpp + teale-node bundled)
```

Rust components form one Cargo workspace (`cargo build --workspace` at root).
Relay is a pnpm/bun package. Mac-app is a SwiftPM package (`swift build` from
`mac-app/`). Android-app is a Gradle project (`./gradlew assembleDebug` from
`android-app/`).

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

# Relay
cd relay && bun install && bun run server.ts

# Mac app
cd mac-app && swift build

# Android app (debug APK on a plugged-in device)
cd android-app && ./gradlew installDebug
# Full pre-release flow (cross-compile node + push Gemma GGUF + install):
./scripts/deploy-pixel.sh
```

## CI

Path-filtered — a Rust-only PR does NOT trigger the Swift build.

| Path                                         | Workflow                         |
|----------------------------------------------|----------------------------------|
| `protocol/`, `node/`, `gateway/`, `stress/`  | `.github/workflows/rust.yml`     |
| `relay/`                                     | `.github/workflows/relay.yml`    |
| `mac-app/`                                   | `.github/workflows/mac-app.yml`  |
| `gateway/`, `protocol/`  → Fly.io auto-deploy on `main` | `.github/workflows/gateway-deploy.yml` |
| `android-app/`                               | _no CI yet_ — build locally, sideload via `android-app/SIDELOAD.md` |

## Deploying

### gateway.teale.com

```bash
cd gateway
flyctl launch                                  # first time
flyctl secrets set GATEWAY_TOKENS="tok_...:openrouter,tok_...:dev"
flyctl deploy
```

### relay.teale.com

```bash
cd relay
flyctl deploy
```

### Supply nodes (Mac)

```bash
brew install teale-ai/teale/teale-node        # (formula TBD)
# or from source:
cargo build --release -p teale-node
# then point at a teale-node.toml with your config
```

### Android client (sideload)

The current pre-release APK ships in `android-app/`; see
`android-app/SIDELOAD.md` for install instructions and
`android-app/scripts/deploy-pixel.sh` for the one-shot
build + push + install flow. Five UI locales ship out of the box:
en, pt-BR, zh-CN, fil, es.

## Docs

Research and planning artifacts live in `.context/` (gitignored in the
source repos; consolidated here under `docs/`).

- `docs/openrouter-open-weight-catalog.md` — demand side (162 open-weight models)
- `docs/mac-fleet-configurations.md` — supply side (chip × RAM × bandwidth)
- `docs/device-model-matrix.md` — routing source of truth
- `docs/device-earnings-cards.md` — recruiting pitch (per-config $/mo)
- `docs/openrouter-provider-gap-analysis.md` — applicable-requirements tracker
- `docs/openrouter-application-rehearsal.md` — submission draft
- `docs/openrouter-oncall-runbook.md` — first-2-weeks playbook
- `docs/protocol.md` — relay + cluster wire protocol spec
