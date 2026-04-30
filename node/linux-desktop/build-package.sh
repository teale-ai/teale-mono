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
mkdir -p "$OUTPUT_DIR/bin" "$OUTPUT_DIR/config" "$OUTPUT_DIR/share"

install -m 0755 "$NODE_BIN" "$OUTPUT_DIR/bin/teale-node"
install -m 0755 "$TRAY_BIN" "$OUTPUT_DIR/bin/teale-tray"
install -m 0755 "$LLAMA_BIN" "$OUTPUT_DIR/bin/llama-server"
install -m 0755 "$SCRIPT_DIR/install.sh" "$OUTPUT_DIR/install.sh"
install -m 0755 "$SCRIPT_DIR/uninstall.sh" "$OUTPUT_DIR/uninstall.sh"
install -m 0644 "$REPO_ROOT/mac-app/scripts/icon_1024.png" "$OUTPUT_DIR/share/teale.png"

python3 - "$OUTPUT_DIR/config/supabase-config.json" <<'PY'
import json
import os
import sys

with open(sys.argv[1], "w", encoding="utf-8") as handle:
    json.dump(
        {
            "supabase_url": os.environ.get("TEALE_SUPABASE_URL", ""),
            "supabase_anon_key": os.environ.get("TEALE_SUPABASE_ANON_KEY", ""),
            "supabase_redirect_url": os.environ.get(
                "TEALE_SUPABASE_REDIRECT_URL", "teale://auth/callback"
            ),
        },
        handle,
        indent=2,
    )
    handle.write("\n")
PY
