#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  mesh-llm-cluster-runner.sh head   --model MODEL [options] [-- extra mesh-llm args]
  mesh-llm-cluster-runner.sh join   --model MODEL --join-token TOKEN [options] [-- extra args]
  mesh-llm-cluster-runner.sh client --join-token TOKEN [options] [-- extra args]

Options:
  --model MODEL         Canonical model id or local model path to serve.
  --join-token TOKEN    Invite token emitted by the head node.
  --port PORT           Local OpenAI API port. Default: 52415
  --console PORT        Local management API / console port. Default: 53131
  --mesh-name NAME      Optional human-readable mesh name.
  --publish             Publish the mesh to Nostr discovery.
  --with-ui             Keep the embedded UI enabled. Default is headless.
  --log FILE            Tee JSON runtime events to FILE.
  -h, --help            Show this help.

Environment:
  MESH_LLM_BIN          mesh-llm binary to run. Default: mesh-llm

Notes:
  - The head and join roles both run the top-level `mesh-llm` runtime surface.
  - The client role runs `mesh-llm --client` and contributes no model weights.
  - The script forces `--log-format json` so invite-token and readiness events
    are machine-readable in the log output.
EOF
}

die() {
  echo "error: $*" >&2
  exit 1
}

[[ $# -ge 1 ]] || {
  usage
  exit 1
}

role=$1
shift

mesh_llm_bin=${MESH_LLM_BIN:-mesh-llm}
model=""
join_token=""
api_port=52415
console_port=53131
mesh_name=""
publish=0
headless=1
log_file=""
extra_args=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --model)
      [[ $# -ge 2 ]] || die "--model requires a value"
      model=$2
      shift 2
      ;;
    --join-token)
      [[ $# -ge 2 ]] || die "--join-token requires a value"
      join_token=$2
      shift 2
      ;;
    --port)
      [[ $# -ge 2 ]] || die "--port requires a value"
      api_port=$2
      shift 2
      ;;
    --console)
      [[ $# -ge 2 ]] || die "--console requires a value"
      console_port=$2
      shift 2
      ;;
    --mesh-name)
      [[ $# -ge 2 ]] || die "--mesh-name requires a value"
      mesh_name=$2
      shift 2
      ;;
    --publish)
      publish=1
      shift
      ;;
    --with-ui)
      headless=0
      shift
      ;;
    --log)
      [[ $# -ge 2 ]] || die "--log requires a value"
      log_file=$2
      shift 2
      ;;
    --)
      shift
      extra_args=("$@")
      break
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "unknown argument: $1"
      ;;
  esac
done

cmd=("$mesh_llm_bin")
case "$role" in
  head)
    [[ -n "$model" ]] || die "head mode requires --model"
    cmd+=(--model "$model")
    ;;
  join)
    [[ -n "$model" ]] || die "join mode requires --model"
    [[ -n "$join_token" ]] || die "join mode requires --join-token"
    cmd+=(--join "$join_token" --model "$model")
    ;;
  client)
    [[ -n "$join_token" ]] || die "client mode requires --join-token"
    cmd+=(--client --join "$join_token")
    ;;
  *)
    die "unknown role '$role' (expected: head, join, client)"
    ;;
esac

cmd+=(--port "$api_port" --console "$console_port" --log-format json)
if [[ $headless -eq 1 ]]; then
  cmd+=(--headless)
fi
if [[ -n "$mesh_name" ]]; then
  cmd+=(--mesh-name "$mesh_name")
fi
if [[ $publish -eq 1 ]]; then
  cmd+=(--publish)
fi
if [[ ${#extra_args[@]} -gt 0 ]]; then
  cmd+=("${extra_args[@]}")
fi

cat <<EOF
role:           $role
mesh-llm:       $mesh_llm_bin
api:            http://127.0.0.1:$api_port/v1
management:     http://127.0.0.1:$console_port/api/status
models check:   curl -s http://127.0.0.1:$api_port/v1/models
join token:     emitted as a JSON event with "event":"invite_token"
command:
  ${cmd[*]}
EOF

if [[ -n "$log_file" ]]; then
  mkdir -p "$(dirname "$log_file")"
  "${cmd[@]}" 2>&1 | tee "$log_file"
else
  exec "${cmd[@]}"
fi
