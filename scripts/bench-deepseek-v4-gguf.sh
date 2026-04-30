#!/usr/bin/env bash
# Single-machine DeepSeek V4 GGUF benchmark harness for llama.cpp-style servers.
#
# Intended for reproducible Apple Silicon runs where we want to pin:
#   - exact llama.cpp checkout / branch
#   - exact GGUF file
#   - mmap on/off
#   - Metal GPU layering / ctx size
#   - TTFT + sustained TPS
#
# Example:
#   LLAMA_CPP_DIR="$HOME/.context/deepseek-v4-gguf/llama.cpp" \
#   MODEL_PATH="$HOME/.context/deepseek-v4-gguf/models/tecaprovn--deepseek-v4-flash-gguf/DeepSeekV4-Flash-158B-Q4_K_M.gguf" \
#   PORT=11436 \
#   bash scripts/bench-deepseek-v4-gguf.sh

set -euo pipefail

cd "$(dirname "$0")/.."

LLAMA_CPP_DIR="${LLAMA_CPP_DIR:-$HOME/.context/deepseek-v4-gguf/llama.cpp}"
SERVER_BIN="${SERVER_BIN:-$LLAMA_CPP_DIR/build/bin/llama-server}"
MODEL_PATH="${MODEL_PATH:-}"
HOST="${HOST:-127.0.0.1}"
PORT="${PORT:-11436}"
CTX_SIZE="${CTX_SIZE:-8192}"
N_GPU_LAYERS="${N_GPU_LAYERS:-999}"
THREADS="${THREADS:-16}"
PARALLEL="${PARALLEL:-1}"
MMAP="${MMAP:-1}"
WARM_RUNS="${WARM_RUNS:-3}"
MAX_OUTPUT_TOKENS="${MAX_OUTPUT_TOKENS:-96}"
REQUEST_TIMEOUT="${REQUEST_TIMEOUT:-180}"
START_SERVER="${START_SERVER:-1}"
CHAT_PROMPT="${CHAT_PROMPT:-In one concise sentence, explain what tensor parallelism does.}"
PREFILL_TARGETS="${PREFILL_TARGETS:-8192 32768}"

export LLAMA_CPP_DIR SERVER_BIN MODEL_PATH HOST PORT CTX_SIZE N_GPU_LAYERS
export THREADS PARALLEL MMAP WARM_RUNS MAX_OUTPUT_TOKENS REQUEST_TIMEOUT
export START_SERVER CHAT_PROMPT PREFILL_TARGETS

if [ -z "$MODEL_PATH" ]; then
  echo "MODEL_PATH is required" >&2
  exit 1
fi

if [ ! -x "$SERVER_BIN" ]; then
  echo "llama-server not found at $SERVER_BIN" >&2
  exit 1
fi

if [ ! -f "$MODEL_PATH" ]; then
  echo "model file not found at $MODEL_PATH" >&2
  exit 1
fi

TS=$(date '+%Y%m%dT%H%M%S')
OUT_DIR="runs/bench-deepseek-v4-gguf-${TS}"
mkdir -p "$OUT_DIR"
RESULTS="$OUT_DIR/results.jsonl"
SERVER_LOG="$OUT_DIR/llama-server.log"
SERVER_PID=""

cleanup() {
  if [ -n "$SERVER_PID" ] && kill -0 "$SERVER_PID" 2>/dev/null; then
    kill "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
  fi
}
trap cleanup EXIT

python3 - "$OUT_DIR/manifest.json" <<'PY'
import json
import os
import platform
import socket
import subprocess
import sys
from pathlib import Path

out = Path(sys.argv[1])

def cmd(args):
    try:
        return subprocess.check_output(args, text=True).strip()
    except Exception:
        return None

model_path = Path(os.environ["MODEL_PATH"]).expanduser()
llama_cpp_dir = Path(os.environ["LLAMA_CPP_DIR"]).expanduser()
server_bin = Path(os.environ["SERVER_BIN"]).expanduser()

manifest = {
    "timestamp": cmd(["date", "-u", "+%Y-%m-%dT%H:%M:%SZ"]),
    "hostname": socket.gethostname(),
    "platform": platform.platform(),
    "python": platform.python_version(),
    "sw_vers": {
        "ProductName": cmd(["sw_vers", "-productName"]),
        "ProductVersion": cmd(["sw_vers", "-productVersion"]),
        "BuildVersion": cmd(["sw_vers", "-buildVersion"]),
    },
    "benchmark": {
        "host": os.getenv("HOST"),
        "port": os.getenv("PORT"),
        "ctx_size": os.getenv("CTX_SIZE"),
        "n_gpu_layers": os.getenv("N_GPU_LAYERS"),
        "threads": os.getenv("THREADS"),
        "parallel": os.getenv("PARALLEL"),
        "mmap": os.getenv("MMAP"),
        "warm_runs": os.getenv("WARM_RUNS"),
        "max_output_tokens": os.getenv("MAX_OUTPUT_TOKENS"),
        "request_timeout_seconds": os.getenv("REQUEST_TIMEOUT"),
        "prefill_targets": os.getenv("PREFILL_TARGETS"),
        "start_server": os.getenv("START_SERVER"),
    },
    "llama_cpp": {
        "dir": str(llama_cpp_dir),
        "git_remote": cmd(["git", "-C", str(llama_cpp_dir), "remote", "get-url", "origin"]),
        "git_branch": cmd(["git", "-C", str(llama_cpp_dir), "rev-parse", "--abbrev-ref", "HEAD"]),
        "git_commit": cmd(["git", "-C", str(llama_cpp_dir), "rev-parse", "HEAD"]),
        "server_bin": str(server_bin),
        "server_version": cmd([str(server_bin), "--version"]),
    },
    "model": {
        "path": str(model_path),
        "basename": model_path.name,
        "size_bytes": model_path.stat().st_size,
        "du_h": cmd(["du", "-sh", str(model_path)]),
    },
}

out.write_text(json.dumps(manifest, indent=2) + "\n")
PY

echo "==> bench-deepseek-v4-gguf $TS"
echo "    model:            $MODEL_PATH"
echo "    server:           $SERVER_BIN"
echo "    port:             $PORT"
echo "    ctx size:         $CTX_SIZE"
echo "    gpu layers:       $N_GPU_LAYERS"
echo "    mmap:             $MMAP"
echo "    out:              $OUT_DIR"
echo

if [ "$START_SERVER" = "1" ]; then
  server_args=(
    "$SERVER_BIN"
    --host "$HOST"
    --port "$PORT"
    -m "$MODEL_PATH"
    --ctx-size "$CTX_SIZE"
    --parallel "$PARALLEL"
    --threads "$THREADS"
    --n-gpu-layers "$N_GPU_LAYERS"
    --jinja
  )

  if [ "$MMAP" = "1" ]; then
    server_args+=(--mmap)
  else
    server_args+=(--no-mmap)
  fi

  "${server_args[@]}" >"$SERVER_LOG" 2>&1 &
  SERVER_PID=$!
  echo "    started llama-server pid=$SERVER_PID"

  python3 - "$HOST" "$PORT" "$REQUEST_TIMEOUT" <<'PY'
import json
import sys
import time
import urllib.request

host, port, timeout_s = sys.argv[1:4]
deadline = time.time() + float(timeout_s)
url = f"http://{host}:{port}/health"
last_err = None
while time.time() < deadline:
    try:
        with urllib.request.urlopen(url, timeout=5) as resp:
            body = resp.read().decode(errors="ignore").strip()
            if resp.status == 200:
                print(body or "ok")
                sys.exit(0)
    except Exception as e:
        last_err = str(e)
        time.sleep(1)
print(last_err or "server did not become healthy", file=sys.stderr)
sys.exit(1)
PY
fi

run_case() {
  local phase="$1"
  local prompt_mode="$2"
  local prompt_target="$3"

  python3 - "$phase" "$prompt_mode" "$prompt_target" "$HOST" "$PORT" "$MAX_OUTPUT_TOKENS" "$REQUEST_TIMEOUT" "$CHAT_PROMPT" <<'PY'
import json
import re
import sys
import time
import urllib.error
import urllib.request

phase, prompt_mode, prompt_target, host, port, max_output_tokens, timeout_s, chat_prompt = sys.argv[1:9]
prompt_target = int(prompt_target)
max_output_tokens = int(max_output_tokens)
timeout_s = float(timeout_s)
base_url = f"http://{host}:{port}"


def build_prompt(mode: str, target: int) -> str:
    if mode == "chat":
        return chat_prompt

    intro = (
        "Benchmark prefill and first-token latency only. "
        "Read the context and answer with exactly ACK.\n\n"
        "Context:\n"
    )
    unit = "tpbench"
    body = " ".join(f"{unit}{i % 1000:03d}" for i in range(max(target, 1)))
    return intro + body + "\n\nRespond with exactly: ACK"


payload = {
    "model": "DeepSeek-V4-Flash-GGUF",
    "messages": [{"role": "user", "content": build_prompt(prompt_mode, prompt_target)}],
    "max_tokens": max_output_tokens,
    "temperature": 0,
    "stream": True,
}

req = urllib.request.Request(
    base_url + "/v1/chat/completions",
    data=json.dumps(payload).encode(),
    method="POST",
)
req.add_header("Content-Type", "application/json")

t0 = time.time()
first_t = None
content_events = 0
prompt_tokens = None
completion_tokens = None
status_code = None
err = ""
ok = 1
buf = b""

content_re = re.compile(r'"content"\s*:\s*"')
usage_re = re.compile(r'"usage"\s*:\s*(\{[^}]*\})')

try:
    with urllib.request.urlopen(req, timeout=timeout_s) as resp:
        status_code = getattr(resp, "status", None)
        while True:
            chunk = resp.read(16384)
            if not chunk:
                break
            buf += chunk
            if first_t is None and content_re.search(chunk.decode(errors="ignore")):
                first_t = time.time() - t0
            content_events += chunk.count(b'"content":"')
except urllib.error.HTTPError as e:
    ok = 0
    status_code = e.code
    err = f"HTTP {e.code} {e.reason}"
    try:
        buf += e.read()
    except Exception:
        pass
except Exception as e:
    ok = 0
    err = str(e)[:200]

text = buf.decode(errors="ignore")
for match in usage_re.finditer(text):
    try:
        usage = json.loads(match.group(1))
        prompt_tokens = usage.get("prompt_tokens") or prompt_tokens
        completion_tokens = usage.get("completion_tokens") or completion_tokens
    except Exception:
        pass

if ok == 1 and content_events == 0 and not completion_tokens:
    ok = 0
    err = err or "no-tokens-received"

total_s = time.time() - t0
record = {
    "phase": phase,
    "prompt_mode": prompt_mode,
    "prompt_target": prompt_target,
    "prompt_tokens": prompt_tokens if prompt_tokens is not None else 0,
    "completion_tokens": completion_tokens if completion_tokens is not None else content_events,
    "ttft_ms": round((first_t or 0) * 1000) if ok else 0,
    "total_ms": round(total_s * 1000),
    "tps": round(((completion_tokens if completion_tokens else content_events) / total_s) if total_s > 0 else 0, 2),
    "http_status": status_code,
    "ok": ok,
}
if err:
    record["err"] = err

print(json.dumps(record))
PY
}

for iter in $(seq 1 "$WARM_RUNS"); do
  run_case "warm_${iter}" "chat" 0 | tee -a "$RESULTS"
done

for target in $PREFILL_TARGETS; do
  run_case "prefill_${target}" "prefill" "$target" | tee -a "$RESULTS"
done

echo
echo "==> summary"
python3 - "$RESULTS" "$OUT_DIR/summary.json" <<'PY' | tee "$OUT_DIR/summary.txt"
import json
import math
import statistics
import sys
from pathlib import Path

results_path = Path(sys.argv[1])
summary_path = Path(sys.argv[2])
rows = [json.loads(line) for line in results_path.read_text().splitlines() if line.strip()]

def pct(values, p):
    if not values:
        return None
    vals = sorted(values)
    if len(vals) == 1:
        return vals[0]
    idx = (len(vals) - 1) * (p / 100.0)
    lo = math.floor(idx)
    hi = math.ceil(idx)
    if lo == hi:
        return vals[lo]
    frac = idx - lo
    return vals[lo] * (1 - frac) + vals[hi] * frac

summary = {}
for phase in sorted({r["phase"] for r in rows}):
    bucket = [r for r in rows if r["phase"] == phase]
    oks = [r for r in bucket if r.get("ok") == 1]
    summary[phase] = {
        "runs": len(bucket),
        "ok_runs": len(oks),
        "p50_ttft_ms": pct([r["ttft_ms"] for r in oks], 50),
        "p95_ttft_ms": pct([r["ttft_ms"] for r in oks], 95),
        "p50_tps": pct([r["tps"] for r in oks], 50),
        "p95_tps": pct([r["tps"] for r in oks], 95),
    }

summary_path.write_text(json.dumps(summary, indent=2) + "\n")

print("phase                ok/runs  p50_ttft_ms  p95_ttft_ms  p50_tps  p95_tps")
for phase, data in summary.items():
    print(
        f"{phase:20} "
        f"{data['ok_runs']:>2}/{data['runs']:<4} "
        f"{(data['p50_ttft_ms'] or 0):>11.0f} "
        f"{(data['p95_ttft_ms'] or 0):>12.0f} "
        f"{(data['p50_tps'] or 0):>8.2f} "
        f"{(data['p95_tps'] or 0):>8.2f}"
    )
PY
