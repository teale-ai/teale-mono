# mac-app

The Teale macOS app (and the iOS companion) as a Swift package. On a Mac it
turns the machine into a supply node for the Teale inference network and
serves an OpenAI-compatible API on `127.0.0.1:11435`.

Architecture, module map and history: [TEALE.md](TEALE.md).
Release/signing: [docs/apple-deployment.md](docs/apple-deployment.md).

## Requirements

- Apple Silicon Mac, macOS 14+
- Xcode 16 or newer (Swift 6.1+; `mlx-swift-lm` needs it). The MLX Metal
  shaders only compile under Xcode/xcodebuild, not plain SwiftPM.

## Build and test

All commands run from `mac-app/` in a checkout of the monorepo:

```bash
cd mac-app
swift build            # compiles every target (what CI runs on macos-15)
swift test             # unit tests (needs Xcode, not just Command Line Tools)
```

CI: `.github/workflows/mac-app.yml` runs `swift build` and `swift test` for
every change under `mac-app/`.

## Run the app

`swift build` produces a bare executable; the menu bar extra, URL scheme
(`teale://`) and MLX Metal library need a real `.app` bundle:

```bash
cd mac-app
./bundle.sh            # xcodebuild Release -> .build/Teale.app (ad-hoc signed)
open .build/Teale.app
```

`bundle.sh` stamps the version into `Info.plist` (the values checked in are
placeholders) and copies the SwiftPM resource bundles. To include the
`teale` CLI, build it first from the repo root and point the script at it:

```bash
cargo build --release -p teale-cli            # from the repo root
TEALE_CLI_BINARY=../target/release/teale ./bundle.sh
```

Logs: `~/Library/Logs/Teale/teale-stderr.log`; updater log:
`~/Library/Application Support/Teale/updater.log`.

## Desktop UI

The main window is the shared desktop companion web bundle in
`Sources/InferencePoolApp/Resources/DesktopCompanionWeb/` (`index.html`,
`app.js`, `app.css`) loaded from `teale://localhost/`. The Windows/Linux tray
(`node/teale-tray`) embeds the same files, so changes there affect every
desktop platform. For UI development you can point the Mac app at an https
copy with `TEALE_DESKTOP_WEB_URL=https://...` (http URLs are ignored).

## Releases

Pushing a `mac-v<YYYY.MM.DD.HHMM>` tag runs
`.github/workflows/mac-app-release.yml`, which builds, signs and publishes
`Teale.zip`, `Teale.dmg` and `checksums.txt`. The in-app updater picks the
newest `mac-v*` release that has `Teale.zip` and verifies it against
`checksums.txt` before installing.
