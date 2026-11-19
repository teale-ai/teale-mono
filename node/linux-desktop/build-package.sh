#!/usr/bin/env bash
set -euo pipefail

if [[ "$#" -ne 4 ]]; then
  echo "usage: $0 <teale-node-bin> <teale-tray-bin> <llama-server-bin> <output-dir>" >&2
  exit 64
fi

NODE_BIN="$1"
TRAY_BIN="$2"
LLAMA_BIN="$3"
OUTPUT_DIR="$4"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

rm -rf "$OUTPUT_DIR"
mkdir -p "$OUTPUT_DIR/bin" "$OUTPUT_DIR/share"

install -m 0755 "$NODE_BIN" "$OUTPUT_DIR/bin/teale-node"
install -m 0755 "$TRAY_BIN" "$OUTPUT_DIR/bin/teale-tray"
install -m 0755 "$LLAMA_BIN" "$OUTPUT_DIR/bin/llama-server"
install -m 0755 "$SCRIPT_DIR/install.sh" "$OUTPUT_DIR/install.sh"
install -m 0755 "$SCRIPT_DIR/uninstall.sh" "$OUTPUT_DIR/uninstall.sh"
install -m 0644 "$REPO_ROOT/mac-app/scripts/icon_1024.png" "$OUTPUT_DIR/share/teale.png"

# Integrity manifest for install.sh: every shipped file except the manifest
# itself. The release also publishes Teale-linux-x86_64-checksums.txt for the
# tarball; verify that before extracting:
#   sha256sum -c Teale-linux-x86_64-checksums.txt
(
  cd "$OUTPUT_DIR"
  find . -type f ! -name SHA256SUMS -print0 | sort -z | xargs -0 sha256sum > SHA256SUMS
)
