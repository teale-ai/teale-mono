#!/usr/bin/env bash
# Benchmark a DS4/OpenAI-compatible endpoint with streaming requests.
#
# Output: JSONL records plus a compact summary JSON. Token count is based on
# streamed content chunks, so use it for relative endpoint stats, not billing.

set -euo pipefail

BASE_URL="${BASE_URL:-http://127.0.0.1:11438}"
MODEL="${MODEL:-deepseek-v4-flash}"
PROMPT="${PROMPT:-Write one concise sentence explaining what Teale does.}"
REQUESTS="${REQUESTS:-3}"
MAX_TOKENS="${MAX_TOKENS:-96}"
THINK="${THINK:-false}"
REASONING_EFFORT="${REASONING_EFFORT:-}"
OUT_DIR="${OUT_DIR:-runs/bench-ds4-$(date '+%Y%m%dT%H%M%S')}"
TIMEOUT="${TIMEOUT:-600}"

mkdir -p "$OUT_DIR"
JSONL="$OUT_DIR/results.jsonl"
SUMMARY="$OUT_DIR/summary.json"
: > "$JSONL"

python3 - "$BASE_URL" "$MODEL" "$PROMPT" "$REQUESTS" "$MAX_TOKENS" "$THINK" "$REASONING_EFFORT" "$TIMEOUT" "$JSONL" "$SUMMARY" <<'PY'
import json
import statistics
import sys
import time
import urllib.error
import urllib.request

base, model, prompt, requests, max_tokens, think, reasoning_effort, timeout, jsonl_path, summary_path = sys.argv[1:11]
requests = int(requests)
max_tokens = int(max_tokens)
timeout = float(timeout)


def run_one(iteration):
    payload = {
        "model": model,
        "messages": [{"role": "user", "content": prompt}],
        "stream": True,
        "max_tokens": max_tokens,
    }
    if think.lower() in ("true", "false"):
        payload["think"] = think.lower() == "true"
    if reasoning_effort:
        payload["reasoning_effort"] = reasoning_effort
    body = json.dumps(payload).encode()
    req = urllib.request.Request(
        base.rstrip("/") + "/v1/chat/completions",
        data=body,
        method="POST",
        headers={"Content-Type": "application/json"},
    )
    start = time.perf_counter()
    first = None
    chunks = 0
    chars = 0
    text_parts = []
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        for raw in resp:
            line = raw.decode("utf-8", "replace").strip()
            if not line.startswith("data: "):
                continue
            payload = line[6:]
            if payload == "[DONE]":
                break
            data = json.loads(payload)
            delta = data.get("choices", [{}])[0].get("delta", {})
            content = delta.get("content") or ""
            if content:
                if first is None:
                    first = time.perf_counter()
                chunks += 1
                chars += len(content)
                text_parts.append(content)
    end = time.perf_counter()
    output_tokens_est = max(chunks, 1)
    gen_seconds = max(end - (first or start), 1e-9)
    return {
        "iter": iteration,
        "ok": True,
        "base_url": base,
        "model": model,
        "prompt_chars": len(prompt),
        "think": think,
        "reasoning_effort": reasoning_effort or None,
        "output_chunks": chunks,
        "output_chars": chars,
        "ttft_ms": round(((first or end) - start) * 1000, 2),
        "total_ms": round((end - start) * 1000, 2),
        "chunk_tps": round(output_tokens_est / gen_seconds, 2),
        "sample": "".join(text_parts)[:300],
    }


records = []
for i in range(1, requests + 1):
    try:
        rec = run_one(i)
    except Exception as exc:
        rec = {
            "iter": i,
            "ok": False,
            "base_url": base,
            "model": model,
            "error": str(exc),
        }
    records.append(rec)
    with open(jsonl_path, "a", encoding="utf-8") as f:
        f.write(json.dumps(rec) + "\n")
    print(json.dumps(rec))

ok = [r for r in records if r.get("ok")]
summary = {
    "base_url": base,
    "model": model,
    "think": think,
    "reasoning_effort": reasoning_effort or None,
    "requests": requests,
    "successes": len(ok),
}
if ok:
    summary.update({
        "ttft_ms_median": round(statistics.median(r["ttft_ms"] for r in ok), 2),
        "total_ms_median": round(statistics.median(r["total_ms"] for r in ok), 2),
        "chunk_tps_median": round(statistics.median(r["chunk_tps"] for r in ok), 2),
        "output_chars_median": round(statistics.median(r["output_chars"] for r in ok), 2),
    })
with open(summary_path, "w", encoding="utf-8") as f:
    json.dump(summary, f, indent=2)
print("summary=" + json.dumps(summary))
PY

echo "wrote $JSONL"
echo "wrote $SUMMARY"
