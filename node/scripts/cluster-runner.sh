#!/usr/bin/env bash
# cluster-runner.sh — start a dedicated 2-Mac EXO Kimi cluster from the head Mac.
#
# Prerequisites on BOTH Macs:
#   - macOS 15+, M3 Ultra with 512 GB unified memory (or compatible)
#   - Homebrew, Python 3.12+
#   - SSH access from head to leaf (passwordless key)
#   - Connected via Thunderbolt Bridge or 10GbE (not Wi-Fi — exo tensor
#     transfers saturate interconnects fast and Wi-Fi hurts latency/loss)
#
# Prerequisites on the head Mac only:
#   - EXO.app installed in /Applications/EXO.app or EXO_BIN set explicitly
#   - Model artifacts on shared storage or in a shared exo cache location
#
# Usage:
#   LEAF_HOST=10.0.0.11 LEAF_SSH_TARGET=teale@10.0.0.11 \
#     EXO_MODEL_ID=teale/Kimi-K2.6-32k \
#     bash node/scripts/cluster-runner.sh
#
# The script:
#   1. Verifies SSH to leaf
#   2. Starts EXO on leaf (background, via SSH)
#   3. Starts EXO on head (foreground), joining the mesh
#   4. Waits for the chosen model to be truly placed before returning success
#
# Stability defaults:
#   - one pinned model (`unsloth/Kimi-K2.6`)
#   - no continuous batching by default
#   - no runtime downloads by default
#   - expects both Macs to be dedicated to the cluster

set -euo pipefail

MODEL_INPUT="${EXO_MODEL_ID:-${1:-moonshotai/kimi-k2.6}}"
LEAF_HOST="${LEAF_HOST:-${LEAF_IP:-}}"
LEAF_SSH_TARGET="${LEAF_SSH_TARGET:-$LEAF_HOST}"
API_PORT="${API_PORT:-52415}"
LEAF_API_PORT="${LEAF_API_PORT:-$API_PORT}"
LIBP2P_PORT="${LIBP2P_PORT:-52416}"
NAMESPACE="${EXO_LIBP2P_NAMESPACE:-teale-kimi-2x512}"
LOG_DIR="${LOG_DIR:-$HOME/Library/Logs/TealeCluster}"
EXO_OFFLINE="${EXO_OFFLINE:-1}"
EXO_NO_DOWNLOADS="${EXO_NO_DOWNLOADS:-1}"
EXO_NO_BATCH="${EXO_NO_BATCH:-1}"
EXO_NO_FAST_SYNCH="${EXO_NO_FAST_SYNCH:-1}"
EXO_PREFERRED_SHARDING="${EXO_PREFERRED_SHARDING:-Pipeline}"
EXO_PREFERRED_INSTANCE_META="${EXO_PREFERRED_INSTANCE_META:-MlxJaccl}"

if [[ -z "${LEAF_HOST}" ]]; then
  echo "LEAF_HOST (or LEAF_IP) must be set to the second Mac." >&2
  exit 1
fi

normalize_model() {
  case "$1" in
    unsloth/Kimi-K2.6|moonshotai/kimi-k2.6|kimi-k2.6|kimi2.6|kimi|k2.6)
      printf '%s\n' "unsloth/Kimi-K2.6"
      ;;
    teale/Kimi-K2.6-32k|teale/kimi-k2.6-32k|kimi-k2.6-32k|kimi32k)
      printf '%s\n' "teale/Kimi-K2.6-32k"
      ;;
    *)
      printf '%s\n' "$1"
      ;;
  esac
}

resolve_exo_bin() {
  if [[ -n "${EXO_BIN:-}" && -x "${EXO_BIN}" ]]; then
    printf '%s\n' "${EXO_BIN}"
    return 0
  fi
  if command -v exo >/dev/null 2>&1; then
    command -v exo
    return 0
  fi
  if [[ -x "/Applications/EXO.app/Contents/Resources/exo/exo" ]]; then
    printf '%s\n' "/Applications/EXO.app/Contents/Resources/exo/exo"
    return 0
  fi
  echo "EXO binary not found. Set EXO_BIN explicitly." >&2
  exit 1
}

exo_support_dir() {
  local exo_bin="$1"
  printf '%s\n' "$(cd "$(dirname "${exo_bin}")/_internal" && pwd)"
}

build_exo_args() {
  local args=("--api-port" "${API_PORT}" "--libp2p-port" "${LIBP2P_PORT}")
  if [[ "${EXO_NO_BATCH}" == "1" ]]; then
    args+=("--no-batch")
  fi
  if [[ "${EXO_NO_DOWNLOADS}" == "1" ]]; then
    args+=("--no-downloads")
  fi
  if [[ "${EXO_OFFLINE}" == "1" ]]; then
    args+=("--offline")
  fi
  if [[ "${EXO_NO_FAST_SYNCH}" == "1" ]]; then
    args+=("--no-fast-synch")
  fi
  printf '%s\n' "${args[@]}"
}

kill_stale_local_exo() {
  local exo_bin="$1"
  local port="$2"
  local stale_pids
  stale_pids="$(pgrep -f "${exo_bin}.*--api-port ${port}" || true)"
  if [[ -n "${stale_pids}" ]]; then
    while IFS= read -r pid; do
      [[ -n "${pid}" ]] || continue
      kill "${pid}" >/dev/null 2>&1 || true
    done <<< "${stale_pids}"
    sleep 2
  fi
}

start_leaf() {
  local ssh_target="$1"
  shift
  local exo_bin="$1"
  shift
  local exo_support_dir="$1"
  shift
  local exo_macmon_path="$1"
  shift
  ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 "${ssh_target}" \
    env \
      API_PORT="${LEAF_API_PORT}" \
      LIBP2P_PORT="${LIBP2P_PORT}" \
      EXO_LIBP2P_NAMESPACE="${NAMESPACE}" \
      EXO_BIN="${exo_bin}" \
      EXO_SUPPORT_DIR="${exo_support_dir}" \
      EXO_MACMON_PATH="${exo_macmon_path}" \
      EXO_NO_BATCH="${EXO_NO_BATCH}" \
      EXO_NO_DOWNLOADS="${EXO_NO_DOWNLOADS}" \
      EXO_OFFLINE="${EXO_OFFLINE}" \
      EXO_NO_FAST_SYNCH="${EXO_NO_FAST_SYNCH}" \
      /bin/bash -s <<'EOF'
set -euo pipefail

resolve_exo_bin() {
  if [[ -n "${EXO_BIN:-}" && -x "${EXO_BIN}" ]]; then
    printf '%s\n' "${EXO_BIN}"
    return 0
  fi
  if command -v exo >/dev/null 2>&1; then
    command -v exo
    return 0
  fi
  if [[ -x "/Applications/EXO.app/Contents/Resources/exo/exo" ]]; then
    printf '%s\n' "/Applications/EXO.app/Contents/Resources/exo/exo"
    return 0
  fi
  echo "EXO binary not found on leaf." >&2
  exit 1
}

build_args() {
  local args=("--api-port" "${API_PORT}" "--libp2p-port" "${LIBP2P_PORT}")
  if [[ "${EXO_NO_BATCH}" == "1" ]]; then
    args+=("--no-batch")
  fi
  if [[ "${EXO_NO_DOWNLOADS}" == "1" ]]; then
    args+=("--no-downloads")
  fi
  if [[ "${EXO_OFFLINE}" == "1" ]]; then
    args+=("--offline")
  fi
  if [[ "${EXO_NO_FAST_SYNCH}" == "1" ]]; then
    args+=("--no-fast-synch")
  fi
  printf '%s\n' "${args[@]}"
}

kill_stale_exo() {
  local exo_bin="$1"
  local port="$2"
  local stale_pids
  stale_pids="$(pgrep -f "${exo_bin}.*--api-port ${port}" || true)"
  if [[ -n "${stale_pids}" ]]; then
    while IFS= read -r pid; do
      [[ -n "${pid}" ]] || continue
      kill "${pid}" >/dev/null 2>&1 || true
    done <<< "${stale_pids}"
    sleep 2
  fi
}

EXO_RESOLVED="$(resolve_exo_bin)"
EXO_MACMON_PATH="${EXO_MACMON_PATH:-${EXO_SUPPORT_DIR}/macmon}"
kill_stale_exo "${EXO_RESOLVED}" "${API_PORT}"
LEAF_LOG_DIR="${HOME}/Library/Logs/TealeCluster"
mkdir -p "${LEAF_LOG_DIR}"
EXO_ARGS=()
while IFS= read -r arg; do
  EXO_ARGS+=("${arg}")
done < <(build_args)
PATH="${EXO_SUPPORT_DIR}:$(dirname "${EXO_RESOLVED}"):${PATH}" \
nohup env PATH="${PATH}" EXO_LIBP2P_NAMESPACE="${EXO_LIBP2P_NAMESPACE}" EXO_MACMON_PATH="${EXO_MACMON_PATH}" \
  "${EXO_RESOLVED}" "${EXO_ARGS[@]}" >"${LEAF_LOG_DIR}/exo-leaf.out.log" 2>"${LEAF_LOG_DIR}/exo-leaf.err.log" &
EOF
}

leaf_node_id() {
  curl -fsS "http://${LEAF_HOST}:${LEAF_API_PORT}/node_id" | tr -d '"'
}

wait_for_leaf_api() {
  for _ in $(seq 1 90); do
    if curl -fsS "http://${LEAF_HOST}:${LEAF_API_PORT}/node_id" >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
  done
  echo "leaf EXO API did not become ready on ${LEAF_HOST}:${LEAF_API_PORT}" >&2
  return 1
}

wait_for_local_api() {
  for _ in $(seq 1 90); do
    if curl -fsS "http://127.0.0.1:${API_PORT}/node_id" >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
  done
  echo "head EXO API did not become ready on :${API_PORT}" >&2
  return 1
}

ensure_instance() {
  MODEL_ID="${MODEL_ID}" API_PORT="${API_PORT}" EXO_PREFERRED_SHARDING="${EXO_PREFERRED_SHARDING}" EXO_PREFERRED_INSTANCE_META="${EXO_PREFERRED_INSTANCE_META}" python3 - <<'PY'
import json
import os
import urllib.parse
import urllib.request

base = f"http://127.0.0.1:{os.environ['API_PORT']}"
model_id = os.environ["MODEL_ID"]

with urllib.request.urlopen(base + "/ollama/api/ps", timeout=60) as response:
    payload = json.load(response)

models = payload.get("models", payload if isinstance(payload, list) else [])
loaded = {
    model.get("model") or model.get("name")
    for model in models
    if isinstance(model, dict)
}
if model_id in loaded:
    raise SystemExit(0)

preview_url = base + "/instance/previews?" + urllib.parse.urlencode({"model_id": model_id})
with urllib.request.urlopen(preview_url, timeout=120) as response:
    previews = json.load(response).get("previews", [])

healthy = [preview for preview in previews if preview.get("error") is None]

def preview_rank(preview):
    sharding = preview.get("sharding")
    instance_meta = preview.get("instance_meta")
    return (
        0 if sharding == os.environ["EXO_PREFERRED_SHARDING"] else 1,
        0 if instance_meta == os.environ["EXO_PREFERRED_INSTANCE_META"] else 1,
        sharding or "",
        instance_meta or "",
    )

instance = next((preview.get("instance") for preview in sorted(healthy, key=preview_rank)), None)
if instance is None:
    raise SystemExit(f"no healthy placement preview for {model_id}")

request = urllib.request.Request(
    base + "/instance",
    data=json.dumps({"instance": instance}).encode(),
    headers={"Content-Type": "application/json"},
)
with urllib.request.urlopen(request, timeout=120) as response:
    print(json.dumps(json.load(response), ensure_ascii=True))
PY
}

MODEL_ID="$(normalize_model "${MODEL_INPUT}")"
EXO_BIN="$(resolve_exo_bin)"
EXO_SUPPORT_DIR="$(exo_support_dir "${EXO_BIN}")"
EXO_MACMON_PATH="${EXO_MACMON_PATH:-${EXO_SUPPORT_DIR}/macmon}"
mkdir -p "${LOG_DIR}"

echo "==> verifying leaf SSH (${LEAF_SSH_TARGET})"
ssh -o ConnectTimeout=5 -o BatchMode=yes "${LEAF_SSH_TARGET}" 'echo leaf ok' >/dev/null || {
  echo "ssh to ${LEAF_SSH_TARGET} failed; configure passwordless SSH first" >&2
  exit 1
}

cleanup() {
  if [[ -n "${HEAD_EXO_PID:-}" ]]; then
    kill "${HEAD_EXO_PID}" >/dev/null 2>&1 || true
  fi
  ssh "${LEAF_SSH_TARGET}" "pkill -f 'Contents/Resources/exo/exo.*--api-port ${LEAF_API_PORT}' >/dev/null 2>&1 || true" >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM

echo "==> starting leaf EXO on ${LEAF_HOST}:${LEAF_API_PORT}"
start_leaf "${LEAF_SSH_TARGET}" "${EXO_BIN}" "${EXO_SUPPORT_DIR}" "${EXO_MACMON_PATH}"
wait_for_leaf_api

LEAF_NODE_ID="$(leaf_node_id)"
BOOTSTRAP_PEER="/ip4/${LEAF_HOST}/tcp/${LIBP2P_PORT}/p2p/${LEAF_NODE_ID}"
EXO_ARGS=()
while IFS= read -r arg; do
  EXO_ARGS+=("${arg}")
done < <(build_exo_args)
kill_stale_local_exo "${EXO_BIN}" "${API_PORT}"

echo "==> starting head EXO with model=${MODEL_ID}"
PATH="${EXO_SUPPORT_DIR}:$(dirname "${EXO_BIN}"):${PATH}" \
env PATH="${PATH}" EXO_LIBP2P_NAMESPACE="${NAMESPACE}" EXO_MACMON_PATH="${EXO_MACMON_PATH}" \
  "${EXO_BIN}" \
  -m \
  "${EXO_ARGS[@]}" \
  --bootstrap-peers "${BOOTSTRAP_PEER}" >>"${LOG_DIR}/exo-head.out.log" 2>&1 &
HEAD_EXO_PID=$!

wait_for_local_api

while kill -0 "${HEAD_EXO_PID}" >/dev/null 2>&1; do
  ensure_instance || true
  sleep 30
done

wait "${HEAD_EXO_PID}"
