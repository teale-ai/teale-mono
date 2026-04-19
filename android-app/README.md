# teale-android

Kotlin + Jetpack Compose client for the Teale WAN. Ships chat, a
Teale-credit wallet, multiplayer groups with `@teale` AI presence, and a
supply mode that runs `llama.cpp` + `teale-node` on the device to serve
inference and earn credits.

For end-users / testers, see [`SIDELOAD.md`](SIDELOAD.md).

## Build

Requirements: JDK 17, Android SDK (compileSdk 34 / minSdk 29), Android
NDK 26 for supply-mode cross-compilation.

```bash
# Debug build (auto debug keystore)
./gradlew assembleDebug

# Release build (uses teale-release.keystore in the repo — swap before
# Play Store submission)
./gradlew assembleRelease

# One-shot: rebuild teale-node for aarch64-linux-android, strip, stage
# into jniLibs, push the Gemma 3 1B GGUF, reinstall, launch
./scripts/deploy-pixel.sh
```

## Layout

```
android-app/
├── app/
│   ├── build.gradle.kts                      # Compose / Room / AppCompat / serialization
│   ├── teale-release.keystore                # Pre-release signing key (see SIDELOAD.md)
│   └── src/main/
│       ├── AndroidManifest.xml               # extractNativeLibs=true, localeConfig, services
│       ├── res/                              # Material3 theme, brain icon, 5 locales
│       └── kotlin/com/teale/android/
│           ├── MainActivity.kt               # AppCompatActivity hosting Compose
│           ├── TealeApplication.kt
│           ├── data/                         # identity, auth, chat, wallet, groups, settings
│           ├── service/                      # SupplyService + foreground node spawner
│           ├── skills/                       # CalendarSkill (first skill)
│           └── ui/                           # Compose screens + theme
├── scripts/
│   └── deploy-pixel.sh                       # end-to-end NDK build + adb push + install
├── SIDELOAD.md                               # Tester install guide
└── README.md                                 # This file
```

## Features (current, post-PR #8)

- **Chats** — SSE streaming against `/v1/chat/completions`; WhatsApp-style
  bubbles, animated typing dots, timestamps.
- **Wallet** — 1 000-credit welcome bonus on first auth, balance + full
  ledger view auto-refreshing every 5 s.
- **Groups** — create, invite, `@teale` mentions pull the AI into the
  thread as an AI-tinted bubble. 2-second poll.
- **Settings** — username alias (PATCHed to the gateway), preferred
  model, supply toggle, in-app Language picker (5 locales).
- **Supply mode** — foreground service spawns `libllamaserver.so`
  (llama.cpp Android release b8840) + `libtealenode.so`. Unified ed25519
  identity means earnings land in the same wallet the app reads from.
- **Calendar skill** — permission-gated; triggers on `@calendar` +
  localized equivalents of "this week / next week / tomorrow" and
  injects next-7-day events as system-prompt context.

## i18n

Strings live in `app/src/main/res/values/strings.xml`. Translations:
`values-pt-rBR/`, `values-zh-rCN/`, `values-fil/`, `values-es/`.
Adding a locale:

1. Add entries to the new `values-<tag>/strings.xml` (copy from the
   English base as a starting point).
2. Add `<locale android:name="xx-YY" />` to `res/xml/locales_config.xml`.
3. Add a `Language` entry in `ui/settings/SettingsScreen.kt`
   (`SUPPORTED_LANGUAGES`) and a native-script label in the English
   `strings.xml` (`lang_xx_yy`).

The LLM replies in whatever language the user writes in (Hermes-3,
Llama-3.1, Gemma all handle the current five natively).

## Where native binaries live

`app/src/main/jniLibs/arm64-v8a/` is **gitignored** — the bundled APK at
`~/Downloads/teale-v0.1.0-pre-release.apk` already contains them, and
`deploy-pixel.sh` regenerates the dir from `/tmp/teale-models/llama-android/`
+ a fresh `cargo build --target aarch64-linux-android -p teale-node`.

Files expected there after `deploy-pixel.sh` runs:

```
libllamaserver.so      # llama-server binary renamed to lib*.so for Android packaging
libtealenode.so        # teale-node binary, same trick
libllama.so libllama-common.so libmtmd.so
libggml*.so            # one per ARM micro-arch (v8.0 … v9.2)
```

## Known pitfalls

Read `~/.claude/projects/-Users-thou48-conductor-repos-teale-mono-v1/memory/reference_android_sideload.md`
if you're hitting weirdness with scoped storage, native-binary exec,
APK-signature mismatches, or Doze blocking UI automation — each bullet
cost hours during PR #8 bring-up.
