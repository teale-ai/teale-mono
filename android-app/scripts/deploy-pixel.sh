#!/usr/bin/env bash
# Pixel 9 Pro Fold deploy: rebuild APK (with bundled native binaries + libs),
# push the Gemma 3 1B GGUF to /data/local/tmp, install, grant permissions,
# and relaunch. Run from repo root.
#
# Requires:
#   JAVA_HOME pointing at a JDK 17
#   ANDROID_HOME pointing at ~/Library/Android/sdk (NDK 26.1.10909125+)
#   `adb` on PATH
#   A device attached via `adb devices`
#   llama.cpp Android build + Gemma 3 1B Q4_K_M GGUF unpacked at /tmp/teale-models/

set -euo pipefail

DEVICE="${DEVICE:-$(adb devices | awk 'NR>1 && $2=="device" {print $1; exit}')}"
if [ -z "$DEVICE" ]; then
    echo "no device connected" >&2; exit 1
fi

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
APP_DIR="$REPO_ROOT/android-app"
APK="$APP_DIR/app/build/outputs/apk/debug/app-debug.apk"
JNI_DIR="$APP_DIR/app/src/main/jniLibs/arm64-v8a"
GGUF_SRC="${GGUF_SRC:-/tmp/teale-models/gemma-3-1b-it-Q4_K_M.gguf}"
LLAMA_BIN_DIR="${LLAMA_BIN_DIR:-/tmp/teale-models/llama-android/llama-b8840}"

echo "[1/5] cross-compile teale-node for aarch64-linux-android"
NDK_BIN="$ANDROID_HOME/ndk/26.1.10909125/toolchains/llvm/prebuilt/darwin-x86_64/bin"
CC_aarch64_linux_android="$NDK_BIN/aarch64-linux-android29-clang" \
CXX_aarch64_linux_android="$NDK_BIN/aarch64-linux-android29-clang++" \
AR_aarch64_linux_android="$NDK_BIN/llvm-ar" \
CARGO_TARGET_AARCH64_LINUX_ANDROID_LINKER="$NDK_BIN/aarch64-linux-android29-clang" \
    cargo build --manifest-path "$REPO_ROOT/Cargo.toml" --release \
    --target aarch64-linux-android -p teale-node

echo "[2/5] stage native libs + binaries into jniLibs"
mkdir -p "$JNI_DIR"
cp "$LLAMA_BIN_DIR"/lib*.so "$JNI_DIR/"
cp "$LLAMA_BIN_DIR/llama-server" "$JNI_DIR/libllamaserver.so"
cp "$REPO_ROOT/target/aarch64-linux-android/release/teale-node" \
    "$JNI_DIR/libtealenode.so"
"$NDK_BIN/llvm-strip" --strip-unneeded "$JNI_DIR"/*.so 2>/dev/null || true

echo "[3/5] push GGUF to device"
adb -s "$DEVICE" push "$GGUF_SRC" /data/local/tmp/gemma.gguf
adb -s "$DEVICE" shell chmod 644 /data/local/tmp/gemma.gguf

echo "[4/5] build + install debug APK"
( cd "$APP_DIR" && ./gradlew assembleDebug )
adb -s "$DEVICE" install -r "$APK"

echo "[5/5] launch"
adb -s "$DEVICE" shell am force-stop com.teale.android
adb -s "$DEVICE" shell am start -n com.teale.android/.MainActivity
echo "deployed to $DEVICE"
