#!/bin/sh
#
# Teale for macOS - one-line installer.
#
# Installs the newest GitHub release whose tag starts with `mac-v` and that
# carries Teale.zip (mac-v* and teale-* desktop tags share one release list,
# so `releases/latest` is often a Windows/Linux-only release). The zip is
# verified against that release's checksums.txt before anything is touched.
#
# Environment:
#   TEALE_TAG=mac-vYYYY.MM.DD.HHMM   install exactly this release
#   TEALE_BUILD_FROM_SOURCE=1        skip releases and build with Xcode
#
# The copy of this script attached to each mac-v* release has PINNED_TAG set
# to that release's tag by the release workflow.
set -e

REPO="teale-ai/teale-mono"
APP_NAME="Teale"
APP_DIR="/Applications/${APP_NAME}.app"
PINNED_TAG=""

echo ""
echo "  Installing Teale..."
echo ""

# ── Preflight ──

if [ "$(uname)" != "Darwin" ]; then
    echo "Error: Teale requires macOS. See https://github.com/$REPO for other platforms."
    exit 1
fi

ARCH=$(uname -m)
if [ "$ARCH" != "arm64" ]; then
    echo "Error: Teale requires Apple Silicon (M1 or later)."
    echo "Your architecture: $ARCH"
    exit 1
fi

OS_VERSION=$(sw_vers -productVersion | cut -d. -f1)
if [ "$OS_VERSION" -lt 14 ] 2>/dev/null; then
    echo "Error: Teale requires macOS 14 Sonoma or later."
    echo "Your version: $(sw_vers -productVersion)"
    exit 1
fi

# ── Optional: Rapid-MLX backend (Apache 2.0, ~25% faster than llama.cpp) ──
#
# Asks once after a successful install. Reads from /dev/tty so the prompt
# works under `curl … | sh`. In genuinely headless contexts (no tty), it
# silently prints a hint and skips the install.
offer_rapid_mlx_install() {
    if command -v rapid-mlx >/dev/null 2>&1; then
        return 0   # already installed
    fi

    if [ ! -t 1 ] && [ ! -e /dev/tty ]; then
        echo ""
        echo "  Optional: install Rapid-MLX for ~25% faster inference:"
        echo "    brew install raullenchai/rapid-mlx/rapid-mlx"
        return 0
    fi

    echo ""
    echo "  Optional: Rapid-MLX is a faster MLX engine (~25% higher TPS"
    echo "  than llama.cpp on Apple Silicon, Apache 2.0)."
    printf "  Install Rapid-MLX now via Homebrew? [y/N] "

    answer=""
    if [ -e /dev/tty ]; then
        read answer </dev/tty || answer=""
    else
        read answer || answer=""
    fi

    case "$answer" in
        y|Y|yes|YES|Yes)
            if ! command -v brew >/dev/null 2>&1; then
                echo "  Homebrew not found. Install it from https://brew.sh and re-run:"
                echo "    brew install raullenchai/rapid-mlx/rapid-mlx"
                return 0
            fi
            echo "  Installing Rapid-MLX (this can take a few minutes)..."
            if brew install raullenchai/rapid-mlx/rapid-mlx; then
                echo ""
                echo "  Rapid-MLX installed. In Teale, open Settings → Inference"
                echo "  Engine → Rapid-MLX, then pick a model alias (try qwen3.6-35b)."
            else
                echo "  Rapid-MLX install failed. You can retry later with:"
                echo "    brew install raullenchai/rapid-mlx/rapid-mlx"
            fi
            ;;
        *)
            echo "  Skipped. Install later with:"
            echo "    brew install raullenchai/rapid-mlx/rapid-mlx"
            ;;
    esac
}

# ── teale CLI symlink ──
#
# The release bundles the teale CLI inside the app at
# Contents/MacOS/teale-cli (named teale-cli because case-insensitive APFS
# collides "teale" with the "Teale" app binary).
# Link it into /usr/local/bin so `teale` is on PATH. /usr/local/bin is
# root-owned on a stock macOS install, so use sudo when it is not writable
# (sudo reads the password from /dev/tty, which works under `curl … | sh`).
# In genuinely headless contexts, fall back to ~/.local/bin with a PATH hint.
install_cli_symlink() {
    CLI="$APP_DIR/Contents/MacOS/teale-cli"
    if [ ! -x "$CLI" ]; then
        return 0   # older build without a bundled CLI
    fi

    TARGET_DIR="/usr/local/bin"
    LINK="$TARGET_DIR/teale"

    if [ -L "$LINK" ] && [ "$(readlink "$LINK")" = "$CLI" ]; then
        echo "  teale CLI already linked at $LINK"
        return 0
    fi

    echo ""
    if { [ -d "$TARGET_DIR" ] && [ -w "$TARGET_DIR" ]; } || [ -w /usr/local ]; then
        mkdir -p "$TARGET_DIR" && ln -sf "$CLI" "$LINK"
    elif [ -e /dev/tty ]; then
        echo "  Linking the teale CLI to $LINK (may ask for your password)..."
        if ! sudo mkdir -p "$TARGET_DIR" || ! sudo ln -sf "$CLI" "$LINK"; then
            echo "  Could not link into $TARGET_DIR. To do it later:"
            echo "    sudo ln -sf $CLI $LINK"
            return 0
        fi
    else
        mkdir -p "$HOME/.local/bin" && ln -sf "$CLI" "$HOME/.local/bin/teale"
        echo "  teale CLI linked at ~/.local/bin/teale"
        echo "  (add ~/.local/bin to your PATH, or run: sudo ln -sf $CLI $LINK)"
        return 0
    fi

    echo "  teale CLI linked at $LINK - try: teale status"
}


fail() {
    echo "" >&2
    echo "Error: $1" >&2
    shift
    for line in "$@"; do
        echo "  $line" >&2
    done
    exit 1
}

finish_install() {
    install_cli_symlink

    offer_rapid_mlx_install

    echo ""
    echo "  Launching..."
    open "$APP_DIR"
    echo ""
    echo "  Look for the brain icon in your menu bar (top-right)."
    echo ""
}

MAC_RELEASES_URL="https://github.com/$REPO/releases?q=mac-v&expanded=true"

# ── Build from source (explicit opt-in only) ──

if [ "${TEALE_BUILD_FROM_SOURCE:-}" = "1" ]; then
    echo "  TEALE_BUILD_FROM_SOURCE=1: building from source."
    echo "  This requires Xcode and takes a few minutes."
    echo ""

    if ! command -v xcodebuild >/dev/null 2>&1; then
        fail "Xcode is required to build from source." "Install it from the App Store, then retry."
    fi

    WORKDIR=$(mktemp -d)
    trap 'rm -rf "$WORKDIR"' EXIT

    git clone --depth 1 "https://github.com/$REPO.git" "$WORKDIR/teale"
    cd "$WORKDIR/teale/mac-app"

    echo "  Building (this takes a few minutes)..."
    ./bundle.sh

    if [ ! -d ".build/Teale.app" ]; then
        fail "build failed. Please open an issue at:" "https://github.com/$REPO/issues"
    fi

    rm -rf "$APP_DIR" 2>/dev/null || true
    cp -R ".build/Teale.app" "$APP_DIR"
    xattr -cr "$APP_DIR" 2>/dev/null || true

    echo ""
    echo "  Teale installed (built from source)."
    finish_install
    exit 0
fi

# ── Pick the release ──
#
# Walk the release list newest-first (paginated) and take the first release
# whose Teale.zip asset lives under a mac-v* tag. The asset download URL embeds
# the tag, so no JSON parser is needed.
find_latest_mac_tag() {
    page=1
    while [ "$page" -le 10 ]; do
        body=$(curl -fsSL -H "Accept: application/vnd.github+json" \
            "https://api.github.com/repos/$REPO/releases?per_page=100&page=$page") || return 1
        tag=$(printf '%s\n' "$body" \
            | grep -o "\"browser_download_url\": *\"https://github.com/$REPO/releases/download/mac-v[^\"/]*/Teale.zip\"" \
            | head -n 1 \
            | sed -E 's#.*/releases/download/([^/]+)/Teale\.zip"$#\1#')
        if [ -n "$tag" ]; then
            echo "$tag"
            return 0
        fi
        # An empty page means we ran out of releases.
        if ! printf '%s\n' "$body" | grep -q '"tag_name"'; then
            return 0
        fi
        page=$((page + 1))
    done
    return 0
}

TAG="${TEALE_TAG:-$PINNED_TAG}"
if [ -z "$TAG" ]; then
    echo "  Looking up the newest macOS release..."
    if ! TAG=$(find_latest_mac_tag); then
        fail "could not query the GitHub releases API (network problem or rate limit)." \
            "Retry in a few minutes, or download Teale.dmg manually from:" \
            "$MAC_RELEASES_URL"
    fi
    if [ -z "$TAG" ]; then
        fail "no mac-v* release with a Teale.zip asset was found." \
            "See $MAC_RELEASES_URL" \
            "To build from source instead (requires Xcode):" \
            "curl -fsSL <this script URL> | TEALE_BUILD_FROM_SOURCE=1 sh"
    fi
fi

case "$TAG" in
    mac-v*) ;;
    *) fail "TEALE_TAG must be a mac-v* release tag (got '$TAG')." "See $MAC_RELEASES_URL" ;;
esac

# ── Download and verify ──

BASE_URL="https://github.com/$REPO/releases/download/$TAG"
WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT

echo "  Downloading Teale $TAG..."
if ! curl -fsSL "$BASE_URL/Teale.zip" -o "$WORKDIR/Teale.zip"; then
    fail "could not download $BASE_URL/Teale.zip" "See $MAC_RELEASES_URL"
fi
if ! curl -fsSL "$BASE_URL/checksums.txt" -o "$WORKDIR/checksums.txt"; then
    fail "release $TAG has no checksums.txt; refusing to install an unverified download." \
        "Download Teale.dmg manually from https://github.com/$REPO/releases/tag/$TAG"
fi

EXPECTED=$(awk '$2 == "Teale.zip" || $2 == "*Teale.zip" { print $1; exit }' "$WORKDIR/checksums.txt" \
    | tr 'A-F' 'a-f')
if [ -z "$EXPECTED" ]; then
    fail "checksums.txt in $TAG has no entry for Teale.zip; refusing to install."
fi
ACTUAL=$(shasum -a 256 "$WORKDIR/Teale.zip" | awk '{ print $1 }' | tr 'A-F' 'a-f')
if [ "$EXPECTED" != "$ACTUAL" ]; then
    fail "SHA-256 mismatch for Teale.zip from $TAG; refusing to install." \
        "expected: $EXPECTED" \
        "actual:   $ACTUAL"
fi
echo "  SHA-256 verified."

# ── Install ──

mkdir -p "$WORKDIR/unpacked"
# Unzip preserving macOS metadata
ditto -x -k "$WORKDIR/Teale.zip" "$WORKDIR/unpacked"
if [ ! -d "$WORKDIR/unpacked/$APP_NAME.app" ]; then
    fail "Teale.zip from $TAG does not contain $APP_NAME.app."
fi

echo "  Installing to $APP_DIR..."
if [ -d "$APP_DIR" ]; then
    rm -rf "$APP_DIR"
fi
ditto "$WORKDIR/unpacked/$APP_NAME.app" "$APP_DIR"

# Strip quarantine flag (safety net for edge cases)
xattr -cr "$APP_DIR" 2>/dev/null || true

echo ""
echo "  Teale $TAG installed."
finish_install
