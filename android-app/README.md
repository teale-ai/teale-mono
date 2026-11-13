# teale-android

Kotlin + Jetpack Compose client for the Teale WAN. Ships chat, a
Teale-credit wallet, multiplayer groups with `@teale` AI presence, and a
supply mode that runs `llama.cpp` + `teale-node` on the device to serve
inference and earn credits. Android supply is intentionally `beta`,
charging-first, and tuned for small-model overflow capacity rather than
always-on backbone throughput.

For end-users / testers, see [`SIDELOAD.md`](SIDELOAD.md).

## Build

Requirements: JDK 17, Android SDK (compileSdk 34 / minSdk 29), Android
NDK 26 for supply-mode cross-compilation.

```bash
# Debug build (auto debug keystore). This is what CI builds.
./gradlew testDebugUnitTest lintDebug assembleDebug

# Release build — needs signing config, see below
./gradlew assembleRelease

# One-shot: rebuild teale-node for aarch64-linux-android, strip, stage
# into jniLibs, push the Gemma 3 1B GGUF, reinstall, launch
./scripts/deploy-pixel.sh

# Record a 30-minute docked supply run (battery, thermal, local health,
# and Android logs) while supply is already enabled on the phone
./scripts/benchmark-pixel-supply.sh 30
```

CI: `.github/workflows/android.yml` runs unit tests, lint and a debug
build on every PR that touches `android-app/`.

### Release signing

No keystore or password is committed. Release builds read the signing
config from `android-app/keystore.properties` (gitignored):

```properties
storeFile=app/teale-release.keystore
storePassword=...
keyAlias=teale
keyPassword=...
```

or from the environment (CI secrets): `TEALE_RELEASE_STORE_FILE`,
`TEALE_RELEASE_STORE_PASSWORD`, `TEALE_RELEASE_KEY_ALIAS`,
`TEALE_RELEASE_KEY_PASSWORD`. Without either, `assembleRelease` fails
with an explanation; `-Pteale.allowDebugSignedRelease=true` builds a
debug-signed release APK for local testing (it cannot update an install
signed with the real key). The published certificate fingerprint is in
[`SIDELOAD.md`](SIDELOAD.md).

`deploy-pixel.sh` options (all optional): `TEALE_MODELS_DIR` (default
`~/.cache/teale-models`, holds the GGUF and the unpacked llama.cpp Android
release), `GGUF_SRC`, `LLAMA_BIN_DIR`, `ANDROID_NDK_VERSION`,
`ANDROID_NDK_HOME`, `DEVICE`. The llama.cpp release comes from
`.github/llama-cpp-version` (fallback `b8840`); the NDK host tag is
detected from `uname`.

## Layout

```
android-app/
├── app/
│   ├── build.gradle.kts                      # Compose / Room / AppCompat / serialization, signing, lint
│   └── src/
│       ├── main/
│       │   ├── AndroidManifest.xml           # services, boot receiver, localeConfig, network security config
│       │   ├── res/                          # Material3 theme, icon, 5 locales, xml/ configs
│       │   └── kotlin/com/teale/android/
│       │       ├── MainActivity.kt           # AppCompatActivity hosting Compose
│       │       ├── TealeApplication.kt
│       │       ├── data/                     # identity, auth, chat, wallet, groups, tasks, settings
│       │       ├── service/                  # SupplyService, process manager, node config, tile, boot receiver
│       │       ├── skills/                   # CalendarSkill (first skill)
│       │       ├── tasks/                    # WorkManager assistant tasks
│       │       └── ui/                       # Compose screens + theme
│       └── test/                             # JVM unit tests (supply policy, node config)
├── scripts/
│   ├── deploy-pixel.sh                       # end-to-end NDK build + adb push + install
│   └── benchmark-pixel-supply.sh             # docked supply soak test
├── SIDELOAD.md                               # Tester install guide + signing fingerprint
└── README.md                                 # This file
```

## Features

- **Chats** — SSE streaming against `/v1/chat/completions`; separate
  threads, per-thread network model picker, token counts.
- **Wallet** — balance + full ledger view, device ID copy, send credits
  to another device wallet.
- **Groups** — create, invite, `@teale` mentions pull the AI into the
  thread as an AI-tinted bubble. 2-second poll.
- **Tasks** — scheduled assistant jobs run through WorkManager.
- **Settings** — username alias (PATCHed to the gateway), preferred
  model, supply toggle and options, in-app Language picker (5 locales).
- **Supply mode** — foreground service spawns `libllamaserver.so`
  (llama.cpp Android release, version from `.github/llama-cpp-version`) +
  `libtealenode.so` from the APK's native library dir. On phones with
  Vulkan 1.1+ it tries an accelerated profile first (waiting for
  llama-server's `/health` to report ready) and falls back to CPU if that
  fails. It pauses when the phone is unplugged (configurable) or
  thermally constrained (stops at SEVERE, resumes at LIGHT or cooler
  after at least 5 minutes), restarts crashed processes with exponential
  backoff (5 attempts, then an error state), and restarts after reboot
  when left enabled. The Home card shows the real state from teale-node's
  local `/status`, with Pause / Resume. Unified ed25519 identity means
  earnings land in the same wallet the app reads from; the identity seed
  is only written to disk while teale-node starts.
- **Calendar skill** — asks for calendar access the first time a message
  needs it; triggers on `@calendar` + localized equivalents of "this week /
  next week / tomorrow" and injects next-7-day events as system-prompt
  context.

## i18n

Strings live in `app/src/main/res/values/strings.xml`. Translations:
`values-pt-rBR/`, `values-zh-rCN/`, `values-fil/`, `values-es/`. Lint
fails the build on any string missing from a locale (`MissingTranslation`).
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

`app/src/main/jniLibs/arm64-v8a/` is **gitignored**. `deploy-pixel.sh`
regenerates it from the llama.cpp Android release under
`$TEALE_MODELS_DIR/llama-android/` plus a fresh
`cargo build --target aarch64-linux-android -p teale-node`. The binaries
must ship inside the APK: Android 10+ only allows executing them from the
app's native library dir, not from external storage or `/data/local/tmp`.

Files expected there after `deploy-pixel.sh` runs:

```
libllamaserver.so      # llama-server binary renamed to lib*.so for Android packaging
libtealenode.so        # teale-node binary, same trick
libllama.so libllama-common.so libmtmd.so
libggml*.so            # one per ARM micro-arch (v8.0 … v9.2)
```

## Known pitfalls

- **Native-binary exec**: binaries are only executable from
  `nativeLibraryDir`, which requires `packaging.jniLibs.useLegacyPackaging
  = true` (already set) so they are extracted on install.
- **Scoped storage**: the app cannot list files `adb push`ed into its
  external files dir; push the model to `/data/local/tmp/gemma.gguf`.
- **APK signature mismatch**: an APK signed with a different key cannot
  update an existing install; uninstall first (this loses the device
  wallet key).
- **Doze**: UI automation and background network can be blocked while
  the screen is off; keep the phone docked and awake when testing.

For realistic supply testing, treat Android phones as docked/charging
nodes. Unplugged screen-off supply is much less reliable because Android
can gate network and background execution aggressively.
