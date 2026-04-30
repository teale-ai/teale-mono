#!/usr/bin/env bash
# Benchmark the DeepSeek V4 deployment matrix behind OpenAI-compatible endpoints.
#
# This script does not manage exo lifecycles itself. Instead, point each case at an
# already-running endpoint:
#   - FLASH_SINGLE_* : single-node DeepSeek-V4-Flash on one 512 GB Ultra
#   - FLASH_TP_*     : 2-node tensor-parallel DeepSeek-V4-Flash
#   - PRO_TP_*       : 2-node tensor-parallel DeepSeek-V4-Pro
#
# A case is enabled only when both URL and MODEL are set.
#
# Example:
#   FLASH_SINGLE_URL=http://127.0.0.1:52415 \
#   FLASH_SINGLE_MODEL=mlx-community/DeepSeek-V4-Flash-4bit \
#   FLASH_TP_URL=http://127.0.0.1:52416 \
#   FLASH_TP_MODEL=mlx-community/DeepSeek-V4-Flash-4bit \
#   PRO_TP_URL=http://127.0.0.1:52417 \
#   PRO_TP_MODEL=unsloth/DeepSeek-V4-Pro \
#   bash scripts/bench-deepseek-v4-exo.sh
#
# Output:
#   runs/bench-deepseek-v4-<timestamp>/results.jsonl
#   runs/bench-deepseek-v4-<timestamp>/summary.json
#   runs/bench-deepseek-v4-<timestamp>/summary.txt

set -euo pipefail

cd "$(dirname "$0")/.."

WARM_RUNS="${WARM_RUNS:-3}"
MAX_OUTPUT_TOKENS="${MAX_OUTPUT_TOKENS:-96}"
REQUEST_TIMEOUT="${REQUEST_TIMEOUT:-180}"
CHAT_PROMPT="${CHAT_PROMPT:-In one concise sentence, explain what tensor parallelism does.}"
COMMON_TOKEN="${COMMON_TOKEN:-}"
USE_SERVER_BENCH="${USE_SERVER_BENCH:-1}"

PREFILL_TARGETS="${PREFILL_TARGETS:-8192 32768}"

TS=$(date '+%Y%m%dT%H%M%S')
OUT_DIR="runs/bench-deepseek-v4-${TS}"
mkdir -p "$OUT_DIR"
RESULTS="$OUT_DIR/results.jsonl"

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
    "exo_app": {
        "CFBundleShortVersionString": cmd(["defaults", "read", "/Applications/EXO.app/Contents/Info", "CFBundleShortVersionString"]),
        "CFBundleVersion": cmd(["defaults", "read", "/Applications/EXO.app/Contents/Info", "CFBundleVersion"]),
    },
    "benchmark": {
        "warm_runs": os.getenv("WARM_RUNS"),
        "max_output_tokens": os.getenv("MAX_OUTPUT_TOKENS"),
        "request_timeout_seconds": os.getenv("REQUEST_TIMEOUT"),
        "prefill_targets": os.getenv("PREFILL_TARGETS"),
        "use_server_bench": os.getenv("USE_SERVER_BENCH"),
        "flash_single_url": os.getenv("FLASH_SINGLE_URL"),
        "flash_single_model": os.getenv("FLASH_SINGLE_MODEL"),
        "flash_tp_url": os.getenv("FLASH_TP_URL"),
        "flash_tp_model": os.getenv("FLASH_TP_MODEL"),
        "pro_tp_url": os.getenv("PRO_TP_URL"),
        "pro_tp_model": os.getenv("PRO_TP_MODEL"),
    },
}

out.write_text(json.dumps(manifest, indent=2) + "\n")
PY

echo "==> bench-deepseek-v4-exo $TS"
echo "    warm runs:        $WARM_RUNS"
echo "    max output tok:   $MAX_OUTPUT_TOKENS"
echo "    request timeout:  $REQUEST_TIMEOUT s"
echo "    prefill targets:  $PREFILL_TARGETS"
echo "    out:              $OUT_DIR"
echo

run_case() {
  local case_name="$1"
  local phase="$2"
  local base_url="$3"
  local model="$4"
  local bearer="$5"
  local prompt_mode="$6"
  local prompt_target="$7"

  python3 - "$case_name" "$phase" "$base_url" "$model" "$bearer" "$prompt_mode" "$prompt_target" "$MAX_OUTPUT_TOKENS" "$REQUEST_TIMEOUT" "$CHAT_PROMPT" "$USE_SERVER_BENCH" <<'PY'
import json
import re
import sys
import time
import urllib.error
import urllib.request

case_name, phase, base_url, model, bearer, prompt_mode, prompt_target, max_output_tokens, timeout_s, chat_prompt, use_server_bench = sys.argv[1:12]
prompt_target = int(prompt_target)
max_output_tokens = int(max_output_tokens)
timeout_s = float(timeout_s)
use_server_bench = use_server_bench == "1"


def build_prompt(mode: str, target: int) -> str:
    if mode == "chat":
        return chat_prompt

    if target <= 0:
        raise ValueError(f"non-chat prompt requires positive target, got {target}")

    intro = (
        "Benchmark prefill and first-token latency only. "
        "Read the context and answer with exactly ACK.\n\n"
        "Context:\n"
    )
    # We overshoot slightly on word count; the server's usage block is the source
    # of truth for actual prompt tokens.
    unit = "tpbench"
    repeats = max(target, 1)
    body = " ".join(f"{unit}{i % 1000:03d}" for i in range(repeats))
    return intro + body + "\n\nRespond with exactly: ACK"


prompt = build_prompt(prompt_mode, prompt_target)
common_payload = {
    "model": model,
    "messages": [{"role": "user", "content": prompt}],
    "max_tokens": max_output_tokens,
    "temperature": 0,
    "use_prefix_cache": False,
}


def make_request(path: str, payload: dict):
    req = urllib.request.Request(
        base_url.rstrip("/") + path,
        data=json.dumps(payload).encode(),
        method="POST",
    )
    req.add_header("Content-Type", "application/json")
    if bearer:
        req.add_header("Authorization", f"Bearer {bearer}")
    return req

t0 = time.time()
first_t = None
content_events = 0
prompt_tokens = None
completion_tokens = None
status_code = None
err = ""
ok = 1

content_re = re.compile(r'"content"\s*:\s*"')
usage_re = re.compile(r'"usage"\s*:\s*(\{[^}]*\})')

buf = b""
try:
    with urllib.request.urlopen(make_request("/v1/chat/completions", dict(common_payload, stream=True)), timeout=timeout_s) as resp:
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
    "case": case_name,
    "phase": phase,
    "model": model,
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

if ok == 1 and use_server_bench:
    bench_buf = b""
    bench_err = ""
    bench_status = None
    bench_t0 = time.time()
    try:
        with urllib.request.urlopen(make_request("/bench/chat/completions", dict(common_payload, stream=False)), timeout=timeout_s) as resp:
            bench_status = getattr(resp, "status", None)
            bench_buf = resp.read()
    except urllib.error.HTTPError as e:
        bench_status = e.code
        bench_err = f"HTTP {e.code} {e.reason}"
        try:
            bench_buf = e.read()
        except Exception:
            pass
    except Exception as e:
        bench_err = str(e)[:200]

    record["bench_http_status"] = bench_status
    record["bench_total_ms"] = round((time.time() - bench_t0) * 1000)
    if bench_err:
        record["bench_err"] = bench_err
    else:
        try:
            bench = json.loads(bench_buf.decode())
            gen = bench.get("generation_stats") or {}
            usage = bench.get("usage") or {}
            peak = gen.get("peak_memory_usage") or {}
            power = bench.get("power_usage") or {}
            record["server_prompt_tps"] = gen.get("prompt_tps")
            record["server_generation_tps"] = gen.get("generation_tps")
            record["server_prompt_tokens"] = gen.get("prompt_tokens", usage.get("prompt_tokens"))
            record["server_generation_tokens"] = gen.get("generation_tokens", usage.get("completion_tokens"))
            record["server_peak_memory_bytes"] = peak.get("inBytes")
            record["server_prefix_cache_hit"] = gen.get("prefix_cache_hit")
            record["server_avg_power_watts"] = power.get("total_avg_sys_power_watts")
            record["server_energy_joules"] = power.get("total_energy_joules")
            record["server_elapsed_seconds"] = power.get("elapsed_seconds")
        except Exception as e:
            record["bench_err"] = f"parse-error: {e}"

print(json.dumps(record))
PY
}

append_case_records() {
  local case_name="$1"
  local base_url="$2"
  local model="$3"
  local bearer="$4"

  echo "-- $case_name → $base_url $model"

  run_case "$case_name" "cold-chat" "$base_url" "$model" "$bearer" "chat" "0" | tee -a "$RESULTS"

  local i target
  for i in $(seq 1 "$WARM_RUNS"); do
    run_case "$case_name" "warm-chat" "$base_url" "$model" "$bearer" "chat" "0" | tee -a "$RESULTS"
  done

  for target in $PREFILL_TARGETS; do
    for i in $(seq 1 "$WARM_RUNS"); do
      run_case "$case_name" "warm-prefill-${target}" "$base_url" "$model" "$bearer" "prefill" "$target" | tee -a "$RESULTS"
    done
  done

  echo
}

case_count=0

maybe_run_case() {
  local case_name="$1"
  local url="$2"
  local model="$3"
  local token="$4"

  if [ -n "$url" ] && [ -n "$model" ]; then
    append_case_records "$case_name" "$url" "$model" "$token"
    case_count=$((case_count + 1))
  fi
}

maybe_run_case "flash-single" "${FLASH_SINGLE_URL:-}" "${FLASH_SINGLE_MODEL:-}" "${FLASH_SINGLE_TOKEN:-$COMMON_TOKEN}"
maybe_run_case "flash-tp" "${FLASH_TP_URL:-}" "${FLASH_TP_MODEL:-}" "${FLASH_TP_TOKEN:-$COMMON_TOKEN}"
maybe_run_case "pro-tp" "${PRO_TP_URL:-}" "${PRO_TP_MODEL:-}" "${PRO_TP_TOKEN:-$COMMON_TOKEN}"

if [ "$case_count" -eq 0 ]; then
  echo "No cases enabled. Set at least one *_URL and *_MODEL pair." >&2
  exit 1
fi

echo "==> summary"
python3 - "$RESULTS" "$OUT_DIR" <<'PY' | tee "$OUT_DIR/summary.txt"
import json
import statistics
import sys
from collections import defaultdict
from pathlib import Path

results_path = Path(sys.argv[1])
out_dir = Path(sys.argv[2])

rows = [json.loads(line) for line in results_path.read_text().splitlines() if line.strip()]
buckets = defaultdict(list)
for row in rows:
    buckets[(row["case"], row["phase"])].append(row)


def pct(values, q):
    if not values:
        return 0
    if q == 50:
        return statistics.median(values)
    s = sorted(values)
    idx = min(len(s) - 1, max(0, int(round(q / 100 * len(s)) - 1)))
    return s[idx]


summary = {}
print(
    f"{'case':14} {'phase':18} {'ok/tot':>7} {'p50 prompt':>10} {'p50 ttft':>9} "
    f"{'p95 ttft':>9} {'p50 tps':>8} {'srv pre':>8} {'srv gen':>8} {'peak GB':>8}  model"
)
print("-" * 120)
for (case_name, phase), items in sorted(buckets.items()):
    oks = [r for r in items if r.get("ok") == 1]
    prompt_toks = [r.get("prompt_tokens") or 0 for r in oks]
    ttfts = [r.get("ttft_ms") or 0 for r in oks]
    tpss = [r.get("tps") or 0 for r in oks]
    server_prompt_tps = [r.get("server_prompt_tps") for r in oks if isinstance(r.get("server_prompt_tps"), (int, float))]
    server_generation_tps = [r.get("server_generation_tps") for r in oks if isinstance(r.get("server_generation_tps"), (int, float))]
    peak_mem = [r.get("server_peak_memory_bytes") for r in oks if isinstance(r.get("server_peak_memory_bytes"), int)]
    model = items[0]["model"]
    model_short = model if len(model) <= 38 else model[:35] + "..."
    print(
        f"{case_name:14} {phase:18} {f'{len(oks)}/{len(items)}':>7} "
        f"{pct(prompt_toks,50):>10.0f} {pct(ttfts,50):>9.0f} {pct(ttfts,95):>9.0f} "
        f"{pct(tpss,50):>8.2f} {pct(server_prompt_tps,50):>8.2f} {pct(server_generation_tps,50):>8.2f} "
        f"{(pct(peak_mem,50) / (1024 ** 3)) if peak_mem else 0:>8.1f}  {model_short}"
    )
    summary.setdefault(case_name, {})[phase] = {
        "ok": len(oks),
        "total": len(items),
        "p50_prompt_tokens": pct(prompt_toks, 50),
        "p50_ttft_ms": pct(ttfts, 50),
        "p95_ttft_ms": pct(ttfts, 95),
        "p50_tps": pct(tpss, 50),
        "p50_server_prompt_tps": pct(server_prompt_tps, 50),
        "p50_server_generation_tps": pct(server_generation_tps, 50),
        "p50_server_peak_memory_bytes": pct(peak_mem, 50),
        "model": model,
    }

(out_dir / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
PY
