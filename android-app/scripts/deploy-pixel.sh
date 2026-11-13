#!/usr/bin/env bash
# Pixel deploy: rebuild the debug APK with bundled native binaries + libs,
# push the Gemma 3 1B GGUF to /data/local/tmp, install and relaunch.
#
# Requires:
#   JAVA_HOME pointing at a JDK 17
#   ANDROID_HOME pointing at the Android SDK, with NDK $ANDROID_NDK_VERSION
#     installed (or ANDROID_NDK_HOME pointing at an NDK directly)
#   `adb` and `cargo` (with the aarch64-linux-android target) on PATH
#   A device attached via `adb devices`
#   The llama.cpp Android release and the Gemma 3 1B Q4_K_M GGUF unpacked under
#   $TEALE_MODELS_DIR (default: ~/.cache/teale-models):
#     $TEALE_MODELS_DIR/gemma-3-1b-it-Q4_K_M.gguf
#     $TEALE_MODELS_DIR/llama-android/llama-<version>/{llama-server,lib*.so}
#
# Overrides: DEVICE, TEALE_MODELS_DIR, GGUF_SRC, LLAMA_BIN_DIR,
#            ANDROID_NDK_VERSION, ANDROID_NDK_HOME, LLAMA_CPP_VERSION.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
APP_DIR="$REPO_ROOT/android-app"
APK="$APP_DIR/app/build/outputs/apk/debug/app-debug.apk"
JNI_DIR="$APP_DIR/app/src/main/jniLibs/arm64-v8a"

# llama.cpp release pin shared with the other deploy paths.
LLAMA_VERSION_FILE="$REPO_ROOT/.github/llama-cpp-version"
if [ -z "${LLAMA_CPP_VERSION:-}" ]; then
    if [ -f "$LLAMA_VERSION_FILE" ]; then
        LLAMA_CPP_VERSION="$(tr -d '[:space:]' < "$LLAMA_VERSION_FILE")"
    fi
    LLAMA_CPP_VERSION="${LLAMA_CPP_VERSION:-b8840}"
fi

MODELS_DIR="${TEALE_MODELS_DIR:-$HOME/.cache/teale-models}"
GGUF_SRC="${GGUF_SRC:-$MODELS_DIR/gemma-3-1b-it-Q4_K_M.gguf}"
LLAMA_BIN_DIR="${LLAMA_BIN_DIR:-$MODELS_DIR/llama-android/llama-$LLAMA_CPP_VERSION}"

DEVICE="${DEVICE:-$(adb devices | awk 'NR>1 && $2=="device" {print $1; exit}')}"
if [ -z "$DEVICE" ]; then
    echo "no device connected" >&2; exit 1
fi

for path in "$GGUF_SRC" "$LLAMA_BIN_DIR/llama-server"; do
    if [ ! -e "$path" ]; then
        echo "missing $path (set TEALE_MODELS_DIR, GGUF_SRC or LLAMA_BIN_DIR)" >&2
        exit 1
    fi
done

# NDK prebuilt host tag. NDK r23+ ships universal macOS binaries under
# darwin-x86_64, so Apple Silicon uses the same tag.
case "$(uname -s)" in
    Darwin) NDK_HOST_TAG="darwin-x86_64" ;;
    Linux) NDK_HOST_TAG="linux-x86_64" ;;
    MINGW* | MSYS* | CYGWIN*) NDK_HOST_TAG="windows-x86_64" ;;
    *) echo "unsupported host $(uname -s) for the Android NDK" >&2; exit 1 ;;
esac
ANDROID_NDK_VERSION="${ANDROID_NDK_VERSION:-26.1.10909125}"
if [ -z "${ANDROID_NDK_HOME:-}" ]; then
    : "${ANDROID_HOME:?set ANDROID_HOME (Android SDK) or ANDROID_NDK_HOME}"
    ANDROID_NDK_HOME="$ANDROID_HOME/ndk/$ANDROID_NDK_VERSION"
fi
NDK_BIN="$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/$NDK_HOST_TAG/bin"
if [ ! -d "$NDK_BIN" ]; then
    echo "NDK toolchain not found at $NDK_BIN" >&2; exit 1
fi

echo "[1/5] cross-compile teale-node for aarch64-linux-android (llama.cpp $LLAMA_CPP_VERSION)"
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
