# Teale · sideload install (Android)

Pre-release build for testers. Not signed with a Play Store upload key — use for
internal testing only.

## Install

1. **Download** the APK on the device:
   - From the shared link, save `teale-v0.1.0-pre-release.apk` to Downloads.

2. **Enable unknown-source install** for the browser that downloaded it
   (Settings → Apps → [Chrome/Drive/etc.] → Install unknown apps → On).

3. **Tap the APK** and confirm the install prompt. ~57 MB; takes under 10 s on a
   recent Pixel.

4. **Launch Teale**. First run registers an Ed25519 device identity, exchanges
   for a bearer token, and credits the wallet with the 1 000-credit welcome
   bonus. No accounts, no passwords.

## Supply mode (optional — earn Teale Credits)

Supply mode makes the phone a tiny inference node serving `google/gemma-3-1b-it`
to the Teale network. This is a charging-first beta path for small-model
overflow capacity, not an always-on public-node mode. Bundled
`libllamaserver.so` + `libtealenode.so` launch when the toggle is on, but the
769-MB GGUF model has to be pushed once over USB:

```bash
adb push gemma-3-1b-it-Q4_K_M.gguf /data/local/tmp/gemma.gguf
adb shell chmod 644 /data/local/tmp/gemma.gguf
```

Then flip Settings → Supply inference. By default Teale only supplies while the
phone is charging and cool enough. On capable devices it tries an accelerated
Vulkan profile first and falls back to CPU if startup fails. When supply is
active, the phone registers with the relay, serves incoming requests, and earns
`DIRECT_EARN` + `AVAILABILITY_DRIP` entries visible on the Wallet tab.

(The Gemma 3 1B GGUF is available from Unsloth:
[`unsloth/gemma-3-1b-it-GGUF`](https://huggingface.co/unsloth/gemma-3-1b-it-GGUF).)

## What's in it

- **Chats** — 1-on-1 with the Teale AI, streaming tokens from the Teale WAN.
- **Groups** — multiplayer chat. Mention `@teale` to pull the AI into any
  thread; it reads the group history as context and posts a reply as an
  AI-tinted bubble.
- **Wallet** — Teale Credits balance, earn/spend split, full ledger history.
- **Settings** — username alias, preferred model, supply-inference toggle,
  in-app **Language** picker.
- **Calendar skill** — when you type "this week" / "next week" / "@calendar"
  (or equivalents in pt-BR / zh-CN / fil / es), the app silently grants the
  LLM access to upcoming events as context (permission-gated).

## Languages

Ships with 5 UI locales:
- English (default)
- Português (Brasil)
- 简体中文
- Filipino
- Español

The app follows the **system language** on first launch. Override per-app from
**Settings → Language** (or, on Android 13+, **Settings → System → Languages**
picks Teale up via the bundled `locales_config.xml`).

The AI replies in whichever language the user writes in — Hermes-3, Llama-3.1,
and Gemma all handle these five (and many more) natively.

## Signature fingerprint (for verification)

```
Keystore: teale-release.keystore
Alias   : teale
Validity: 10 years from 2026-04-19
```

## Uninstall

Settings → Apps → Teale → Uninstall. Wallet and supply state are device-local;
uninstalling clears the Ed25519 key, which means losing the current wallet
balance. A future release will add a recovery flow.

## Known limitations (pre-release)

- No contacts / location / photo skills yet (permissions declared, flows not
  wired). Calendar is the only skill in this build.
- Group chat uses a 2-second poll; SSE backlog replay is TBD.
- Supply mode caches the model in `/data/local/tmp/gemma.gguf` which Android
  may clear on reboot; reapply via `adb push` when it disappears.
- Supply mode is best when the phone is docked or on AC power. Unplugged
  screen-off supply is not considered reliable on stock Android.
- The gateway still uses a pre-release bearer key for static admin calls;
  device-token auth is the supported path for all app traffic.
