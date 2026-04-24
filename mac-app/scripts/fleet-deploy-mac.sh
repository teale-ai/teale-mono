#!/usr/bin/env bash
# Push the locally-built Teale.app to every Mac in the Tailscale fleet.
# Usage:
#   ./scripts/fleet-deploy-mac.sh                # deploy to all 6 Macs
#   ./scripts/fleet-deploy-mac.sh tailor64       # deploy to one host
#   ./scripts/fleet-deploy-mac.sh --skip-build   # reuse existing .build/Teale.app
#
# Requires: Tailscale SSH aliases for the fleet hosts, local Xcode (for
# bundle.sh), and an ad-hoc or Developer ID signing identity.

set -euo pipefail

cd "$(dirname "$0")/.."

TARGETS=(
  tailor16s-mac-mini
  tailor64
  tailor96s-mac-studio
  tailor512g1
  tailor512g8
  tailor8s-macbook-air
)
# thou24s-mac-mini skipped: SSH key not enrolled yet.

SKIP_BUILD=0
SELECTED=""
for arg in "$@"; do
  case "$arg" in
    --skip-build) SKIP_BUILD=1 ;;
    -*)           echo "unknown flag: $arg"; exit 2 ;;
    *)            SELECTED="$arg" ;;
  esac
done

if [ -n "$SELECTED" ]; then
  TARGETS=("$SELECTED")
fi

APP=".build/Teale.app"

if [ "$SKIP_BUILD" -eq 0 ]; then
  echo "==> Building Teale.app (bundle.sh)"
  bash ./bundle.sh
fi

if [ ! -d "$APP" ]; then
  echo "ERROR: $APP not found. Run ./bundle.sh first or drop --skip-build."
  exit 1
fi

SIZE=$(du -sh "$APP" | cut -f1)
echo "==> Deploying $APP ($SIZE) to ${#TARGETS[@]} host(s)"
echo

FAIL=()
SUCCESS=()

for host in "${TARGETS[@]}"; do
  echo "  [$host] rsync .app..."
  if ! rsync -az --delete \
         --exclude '.DS_Store' \
         -e 'ssh -o ConnectTimeout=15 -o StrictHostKeyChecking=accept-new' \
         "$APP"/ "$host:/tmp/Teale.app.new/" 2>&1 \
         | sed "s/^/    /"; then
    echo "  [$host] rsync FAILED"
    FAIL+=("$host")
    continue
  fi

  echo "  [$host] installing + restarting..."
  if ! ssh -o ConnectTimeout=15 "$host" 'bash -s' <<'REMOTE' | sed "s/^/    /"; then
set -e
# Kill running instance
pkill -f '/Applications/Teale.app/Contents/MacOS/Teale' 2>/dev/null || true
sleep 1

# Swap app bundle
sudo -n rm -rf /Applications/Teale.app 2>/dev/null || rm -rf /Applications/Teale.app
mv /tmp/Teale.app.new /Applications/Teale.app

# Clear quarantine so ad-hoc signed apps run without right-click-open
xattr -dr com.apple.quarantine /Applications/Teale.app 2>/dev/null || true

# Boot the binary directly. This is more reliable than `open -a` over SSH and
# still starts the same app bundle in fleet-supply mode.
nohup /Applications/Teale.app/Contents/MacOS/Teale --fleet-supply \
  >/tmp/teale-fleet.log 2>&1 </dev/null &
sleep 2
echo "deployed $(date -u '+%Y-%m-%dT%H:%M:%SZ') pid=$!"
REMOTE
    echo "  [$host] install FAILED"
    FAIL+=("$host")
    continue
  fi

  SUCCESS+=("$host")
  echo "  [$host] OK"
  echo
done

echo "==================================================================="
echo "Deployed: ${SUCCESS[*]:-<none>}"
if [ ${#FAIL[@]} -gt 0 ]; then
  echo "Failed:   ${FAIL[*]}"
  exit 1
fi
echo "All fleet hosts updated."
