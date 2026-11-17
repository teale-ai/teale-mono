#!/usr/bin/env bash
# Push the locally-built Teale.app to every Mac in the Tailscale fleet.
# Usage:
#   ./scripts/fleet-deploy-mac.sh                # deploy to every configured host
#   ./scripts/fleet-deploy-mac.sh my-mac-mini    # deploy to one host
#   ./scripts/fleet-deploy-mac.sh --skip-build   # reuse existing .build/Teale.app
#
# Fleet hosts are NOT kept in the repo. Provide them, in priority order, via:
#   TEALE_FLEET_HOSTS="host-a host-b"            # space- or comma-separated
#   TEALE_FLEET_HOSTS_FILE=/path/to/hosts        # one SSH alias per line
#   ~/.config/teale/fleet-hosts                  # default hosts file
# Hosts files ignore blank lines and '#' comments.
#
# Requires: Tailscale SSH aliases for the fleet hosts, local Xcode (for
# bundle.sh), and an ad-hoc or Developer ID signing identity.

set -euo pipefail

cd "$(dirname "$0")/.."

HOSTS_FILE="${TEALE_FLEET_HOSTS_FILE:-$HOME/.config/teale/fleet-hosts}"
TARGETS=()
if [ -n "${TEALE_FLEET_HOSTS:-}" ]; then
  read -r -a TARGETS <<< "${TEALE_FLEET_HOSTS//,/ }"
elif [ -f "$HOSTS_FILE" ]; then
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%%#*}"
    line="$(echo "$line" | tr -d '[:space:]')"
    [ -n "$line" ] && TARGETS+=("$line")
  done < "$HOSTS_FILE"
fi

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

if [ ${#TARGETS[@]} -eq 0 ]; then
  echo "ERROR: no fleet hosts. Set TEALE_FLEET_HOSTS, or list SSH aliases in $HOSTS_FILE," >&2
  echo "       or pass a single host as an argument." >&2
  exit 2
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
LA_PLIST="$HOME/Library/LaunchAgents/com.teale.fleet-supply.plist"
LA_DOMAIN="gui/$(id -u)"
LA_SERVICE="$LA_DOMAIN/com.teale.fleet-supply"

# If fleet supply is managed by LaunchAgent, stop it first so KeepAlive does
# not race the bundle swap or start a second copy beside the manual restart.
launchctl bootout "$LA_SERVICE" >/dev/null 2>&1 || true
launchctl remove com.teale.fleet-supply >/dev/null 2>&1 || true

# Kill running instances and wait for the old listener to release :11435.
# A slow shutdown can otherwise leave the old build serving while the new
# binary starts as a second process without the API port.
pkill -TERM -f '/Applications/Teale.app/Contents/MacOS/Teale' 2>/dev/null || true
for _ in 1 2 3 4 5; do
  pgrep -f '/Applications/Teale.app/Contents/MacOS/Teale' >/dev/null 2>&1 || break
  sleep 1
done
if pgrep -f '/Applications/Teale.app/Contents/MacOS/Teale' >/dev/null 2>&1; then
  pkill -KILL -f '/Applications/Teale.app/Contents/MacOS/Teale' 2>/dev/null || true
  sleep 1
fi

# Swap app bundle
sudo -n rm -rf /Applications/Teale.app 2>/dev/null || rm -rf /Applications/Teale.app
mv /tmp/Teale.app.new /Applications/Teale.app

# Clear quarantine so ad-hoc signed apps run without right-click-open
xattr -dr com.apple.quarantine /Applications/Teale.app 2>/dev/null || true

# Prefer the persistent LaunchAgent when present; otherwise boot the binary
# directly for ad-hoc hosts that have not installed fleet-supply persistence.
if [ -f "$LA_PLIST" ]; then
  launchctl bootstrap "$LA_DOMAIN" "$LA_PLIST" >/dev/null 2>&1 || launchctl load "$LA_PLIST"
  launchctl kickstart -k "$LA_SERVICE" >/dev/null 2>&1 || true
  sleep 2
  PID=$(launchctl print "$LA_SERVICE" 2>/dev/null | awk '/pid =/ { print $3; exit }')
  echo "deployed $(date -u '+%Y-%m-%dT%H:%M:%SZ') launchagent_pid=${PID:-unknown}"
else
  nohup /Applications/Teale.app/Contents/MacOS/Teale --fleet-supply \
    >/tmp/teale-fleet.log 2>&1 </dev/null &
  sleep 2
  echo "deployed $(date -u '+%Y-%m-%dT%H:%M:%SZ') pid=$!"
fi
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
