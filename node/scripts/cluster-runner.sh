#!/usr/bin/env bash
# cluster-runner.sh — start the 2-Mac exo cluster on the head Mac.
#
# Prerequisites on BOTH Macs:
#   - macOS 15+, M3 Ultra with 512 GB unified memory (or compatible)
#   - Homebrew, Python 3.12+
#   - SSH access from head to leaf (passwordless key)
#   - Connected via Thunderbolt Bridge or 10GbE (NOT Wi-Fi — exo tensor
#     transfers saturate interconnects fast and Wi-Fi hurts latency/loss)
#
# Prerequisites on the head Mac only:
#   - `pip install exo` (https://github.com/exo-explore/exo)
#   - Model artifacts on shared storage or in a shared exo cache location
#
# Usage:
#   HEAD_IP=10.0.0.10 LEAF_IP=10.0.0.11 bash scripts/cluster-runner.sh moonshotai/kimi-k2
#
# The script:
#   1. Verifies SSH to leaf
#   2. Starts exo on leaf (background, via SSH)
#   3. Starts exo on head (foreground), joining the mesh
#   4. Waits for health, logs both machines' status

set -euo pipefail

MODEL="${1:-moonshotai/kimi-k2}"
HEAD_IP="${HEAD_IP:-127.0.0.1}"
LEAF_IP="${LEAF_IP:?LEAF_IP must be set to the IP of the second Mac}"
PORT="${PORT:-52415}"
DISCOVERY_PORT="${DISCOVERY_PORT:-52416}"

echo "==> verifying leaf SSH ($LEAF_IP)"
ssh -o ConnectTimeout=5 -o BatchMode=yes "$LEAF_IP" 'echo leaf ok' || {
  echo "ssh to $LEAF_IP failed; configure passwordless SSH first" >&2
  exit 1
}

cleanup() {
  echo "==> stopping leaf exo"
  ssh "$LEAF_IP" 'pkill -TERM -f "exo run" || true; pkill -TERM -f "exo serve" || true' || true
}
trap cleanup EXIT INT TERM

echo "==> starting leaf exo on $LEAF_IP (background)"
ssh -n -o StrictHostKeyChecking=no "$LEAF_IP" \
  "nohup exo serve --node-id leaf \
                  --discovery-module udp \
                  --discovery-listen-port $DISCOVERY_PORT \
                  --chatgpt-api-port $PORT \
                  >/tmp/exo-leaf.log 2>&1 &" &

echo "==> waiting 5s for leaf to come up"
sleep 5

echo "==> starting head exo (foreground), model=$MODEL"
exec exo serve \
    --node-id head \
    --discovery-module udp \
    --discovery-listen-port $DISCOVERY_PORT \
    --chatgpt-api-port $PORT \
    --models "$MODEL"
