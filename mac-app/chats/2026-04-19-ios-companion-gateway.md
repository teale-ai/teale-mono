# 2026-04-19 · iOS TealeCompanion → gateway-backed Teale tab

Added a new top-level tab in `TealeCompanion` that talks to the gateway
endpoints shipped in PR #8 (Android parity pass). The tab is visible
without Supabase sign-in so testers can get from install to a working
group chat without any onboarding friction.

## What shipped

- **`Sources/TealeCompanion/TealeNet/`** — cross-platform-identical
  clients to the Android app:
  - `GatewayIdentity.swift` — Curve25519 via CryptoKit, Keychain-backed
    seed. `deviceID = hex(publicKey)` matches `android-app/.../WanIdentity.kt`
    + `node/src/identity.rs`.
  - `GatewayAuthClient.swift` — challenge/exchange actor with 24h token
    cache + refresh-at-60s-left.
  - `GatewayGroupsClient.swift` — `/v1/groups/*` REST
    (create/mine/members/messages/memory).
  - `GatewayChatClient.swift` — `/v1/chat/completions` streaming via
    `URLSession.bytes`, drain helper for the single-reply AI path.
  - `GatewayWalletClient.swift` — `/v1/wallet/{balance,transactions}`.
  - `TealeNetState.swift` — `@MainActor @Observable` glue with 2-second
    group message polling, 5-second wallet refresh when idle, proactive
    AI reply triggers (`@teale`, trailing `?`, planning phrases), + an
    auto-greeting when the user opens an empty group for the first time.
  - `Haptics.swift` — thin iOS wrapper.

- **`Sources/TealeCompanion/Views/TealeNetworkTabView.swift`** — iOS UI:
  - Hero identity card (gradient avatar, short device ID, Copy/Invite/
    credits-pill) that doubles as the wallet entry point.
  - Groups list with per-group gradient avatar, last-message preview
    (prefixed "You:" / "@xxxxxx:" / "Teale:"), relative timestamp,
    members pill, and a polished empty state.
  - iMessage-style group chat: tail bubbles with sender grouping,
    spring-in animations, long-press → copy context menu, per-sender
    timestamps, animated "Teale is typing…" row, pill composer with
    sparkles-nudge + round send button that spring-scales on enable.
  - Nav bar shows "N members · Teale on ✨" (or "Teale is typing…").
  - Wallet sheet with balance/earned/spent/USDC + typed ledger rows.
  - Create-group + invite sheets with live device-ID validation.
  - `UIActivityViewController` bridge so Invite posts a ready-to-send
    message with the user's device ID.

- **`Sources/TealeCompanion/TealeCompanionApp.swift`** — pass-through
  no-auth access to the new Teale tab; Supabase sign-in is now just
  another tab (not a gate). Existing ChatKit/Wallet/Me tabs only show
  once signed in, preserving prior behavior.

- **`Sources/HardwareProfile/UserProfileOverrides.swift`** — iOS path
  fix (`homeDirectoryForCurrentUser` is unavailable there; fall back to
  Application Support).

- **`android-app/.../SettingsStore.kt`** — default model bumped to
  `meta-llama/llama-3.1-8b-instruct` so Android + iOS converge on the
  same fleet-served model.

## Proactive AI behaviour

- First-open of an empty group: Teale auto-posts a one-sentence greet
  + one concrete offer to help (once per group, ever).
- Subsequent messages: AI chimes in when the user writes `@teale`, ends
  a sentence with `?`, or uses planning phrases ("let's", "should we",
  "what about", "recommend", …).
- Explicit ✨ button in the composer nudges Teale without a message.

## Verified

- `swift build --target TealeCompanion` — clean.
- Installed on HouPhone (iPhone 17 Pro, iOS 26.5) via standalone xcodegen
  wrapper project. Runs ed25519 auth → gateway → groups + wallet on
  first launch.
- End-to-end: Pixel 9 Pro Fold + iPhone both see the same group over
  `gateway.teale.com`; AI reply goes through `/v1/chat/completions` on
  meta-llama/llama-3.1-8b-instruct (2 supply nodes live) and lands as
  `type="ai"` messages visible on both phones.

## Known gaps

- TealeCompanion SwiftPM target still doesn't produce an `.app` bundle
  from `swift build` alone — we build via a standalone xcodegen project
  for distribution. That's a follow-up when we set up real iOS CI.
- The entire new tab is iOS-only (`#if os(iOS)` on every file). macOS
  parity for this UX is a separate pass.
