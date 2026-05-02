#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  mesh-cluster-inventory.sh --head HEAD_HOST [--path MODEL_PATH ...] host1 host2 ...

Collect a TSV inventory from the candidate mesh machines. The script SSHes to
each host, records memory / storage / mesh runtime status, and measures RTT
from that host to the intended head node.

Columns:
  ssh_host
  hostname
  memory_gb
  mesh_version
  rtt_to_head_ms
  api_models_52415
  storage_paths

Examples:
  scripts/mesh-cluster-inventory.sh --head ultra-head tailor16 tailor64 tailor96 \
    > runs/mesh-inventory.tsv

  scripts/mesh-cluster-inventory.sh --head ultra-head \
    --path '$HOME/Library/Application Support/Teale/models' \
    --path '$HOME/.mesh-llm' \
    ultra-head leaf-a leaf-b
EOF
}

die() {
  echo "error: $*" >&2
  exit 1
}

head_host=""
paths=(
  '$HOME/Library/Application Support/Teale/models'
  '$HOME/Library/Application Support/Teale/huggingface'
  '$HOME/.mesh-llm'
  '$HOME/.cache/huggingface'
)

while [[ $# -gt 0 ]]; do
  case "$1" in
    --head)
      [[ $# -ge 2 ]] || die "--head requires a value"
      head_host=$2
      shift 2
      ;;
    --path)
      [[ $# -ge 2 ]] || die "--path requires a value"
      paths+=("$2")
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --)
      shift
      break
      ;;
    -*)
      die "unknown option: $1"
      ;;
    *)
      break
      ;;
  esac
done

[[ -n "$head_host" ]] || die "--head is required"
[[ $# -ge 1 ]] || die "at least one SSH host is required"

echo -e "ssh_host\thostname\tmemory_gb\tmesh_version\trtt_to_head_ms\tapi_models_52415\tstorage_paths"

for ssh_host in "$@"; do
  {
    printf 'set -euo pipefail\n'
    printf 'ssh_host=%q\n' "$ssh_host"
    printf 'head_host=%q\n' "$head_host"
    printf 'paths=(\n'
    for path in "${paths[@]}"; do
      printf '  %q\n' "$path"
    done
    printf ')\n'
    cat <<'EOF'
set -euo pipefail

hostname_short=$(hostname -s 2>/dev/null || hostname)
mem_bytes=$(sysctl -n hw.memsize 2>/dev/null || echo 0)
mem_gb=$(awk -v bytes="$mem_bytes" 'BEGIN { printf "%.1f", bytes / 1073741824 }')
mesh_version=$(mesh-llm --version 2>/dev/null | head -n1 | tr '\t' ' ' || true)

rtt_ms=$({ ping -c 5 -q "$head_host" 2>/dev/null || true; } | awk -F'/' '/round-trip|rtt/ {print $5}')
if [[ -z "$rtt_ms" ]]; then
  rtt_ms="unreachable"
fi

api_models=$(
  {
    curl -s -m 4 http://127.0.0.1:52415/v1/models 2>/dev/null || true
  } | { grep -o '"id"' || true; } | wc -l | tr -d ' '
)
if [[ -z "$api_models" ]]; then
  api_models=0
fi

storage=""
sep=""
for path_expr in "${paths[@]}"; do
  resolved_path=${path_expr//\$HOME/$HOME}
  resolved_path=${resolved_path//\$\{HOME\}/$HOME}
  if [[ -e "$resolved_path" ]]; then
    free_kb=$(df -Pk "$resolved_path" | tail -1 | awk '{print $4}')
    free_gb=$(awk -v kb="$free_kb" 'BEGIN { printf "%.1f", kb / 1048576 }')
    storage="${storage}${sep}${resolved_path}:${free_gb}GB"
    sep=';'
  fi
done

printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
  "$ssh_host" \
  "$hostname_short" \
  "$mem_gb" \
  "$mesh_version" \
  "$rtt_ms" \
  "$api_models" \
  "$storage"
EOF
  } | ssh -o BatchMode=yes -o ConnectTimeout=10 "$ssh_host" bash -s
done
