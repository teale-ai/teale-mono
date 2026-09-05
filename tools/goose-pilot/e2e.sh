#!/bin/bash
# goose x Teale end-to-end (README step 3): one real headless goose session
# on Teale inference. Pass = goose drives its developer tools through the
# gateway and the marker file round-trips.
#
# Usage: ./e2e.sh   (expects ~/.goose-bot-api-key.json on the machine)
set -uo pipefail

MARKER_FILE=/tmp/goose-e2e.txt
MARKER=teale-goose-e2e-ok

if ! command -v goose >/dev/null 2>&1; then
  echo "goose not found. Install: brew install block/tap/goose"
  exit 2
fi

mkdir -p ~/.config/goose/providers
cp "$(dirname "$0")/teale.json" ~/.config/goose/providers/teale.json

export TEALE_API_KEY=$(python3 -c "import json,os; d=json.load(open(os.path.expanduser('~/.goose-bot-api-key.json'))); print(d.get('secret') or d.get('key') or d.get('apiKey') or d.get('token') or '')")
if [ -z "$TEALE_API_KEY" ]; then echo "KEY-EXTRACT-FAILED"; exit 2; fi
export GOOSE_PROVIDER=teale
export GOOSE_MODEL="qwen/qwen3.6-35b-a3b"

rm -f "$MARKER_FILE"
echo "=== goose session start $(date -u +%H:%M:%SZ) ==="
goose run -t "Create the file $MARKER_FILE containing exactly the line $MARKER, then read the file back and tell me its content." 2>&1 | tee /tmp/goose-e2e.log
echo "=== goose session end $(date -u +%H:%M:%SZ) exit=$? ==="

if [ -f "$MARKER_FILE" ] && [ "$(cat "$MARKER_FILE")" = "$MARKER" ]; then
  echo "E2E PASS: goose created and read back $MARKER_FILE via Teale inference"
  exit 0
else
  echo "E2E FAIL: marker file missing or wrong content"
  [ -f "$MARKER_FILE" ] && cat "$MARKER_FILE"
  exit 1
fi
