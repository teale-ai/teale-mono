#!/usr/bin/env bash
# Cross-fleet inference benchmark.
#
# For each fleet Mac we measure:
#   - local: curl its own 127.0.0.1:11435 using the model it has locally loaded
#   - gateway-auto: curl the production gateway with model=teale-auto
#   - gateway-kimi: only on tailor512g* — curl gateway with moonshotai/kimi-k2
#
# Output: runs/bench-mac-<timestamp>/<host>.jsonl + summary.json + summary.txt
# Each JSON record carries TTFT (ms), total latency (ms), TPS, and token counts.

set -euo pipefail

cd "$(dirname "$0")/.."

GATEWAY_URL="${GATEWAY_URL:-https://gateway.teale.com}"
GATEWAY_TOKEN="${GATEWAY_TOKEN:-tok_dev_1aae940b6028bb79da1c04a598b2a14d}"
PROMPT="${PROMPT:-Write one concise sentence explaining what Teale does.}"
REQUESTS_PER_CASE="${REQUESTS_PER_CASE:-3}"
MAX_TOKENS="${MAX_TOKENS:-96}"
REQ_TIMEOUT="${REQ_TIMEOUT:-90}"

TARGETS=(
  tailor16s-mac-mini
  tailor64
  tailor96s-mac-studio
  tailor512g1
  tailor512g8
  tailor8s-macbook-air
)

TS=$(date '+%Y%m%dT%H%M%S')
OUT="runs/bench-mac-${TS}"
mkdir -p "$OUT"

echo "==> bench-mac-fleet $TS"
echo "    gateway:  $GATEWAY_URL"
echo "    prompt:   $PROMPT"
echo "    requests: $REQUESTS_PER_CASE per case"
echo "    max_tok:  $MAX_TOKENS"
echo "    out:      $OUT"
echo

# Remote script: one request, emits a single JSON line to stdout.
# Streams SSE, first-token wall clock is taken when we see the first data chunk.
REMOTE_SCRIPT='#!/usr/bin/env bash
set -eu
host="$1"; case_name="$2"; base_url="$3"; model="$4"; bearer="$5"
prompt="$6"; max_tokens="$7"; timeout_s="$8"

body_file=$(mktemp); trap "rm -f $body_file" EXIT
cat > "$body_file" <<JSON
{"model":"$model","messages":[{"role":"user","content":"$prompt"}],"stream":true,"max_tokens":$max_tokens}
JSON

hdrs=(-H "Content-Type: application/json")
if [ -n "$bearer" ]; then
  hdrs+=(-H "Authorization: Bearer $bearer")
fi

stream_tmp=$(mktemp); trap "rm -f $stream_tmp $body_file" EXIT

python3 - "$base_url" "$timeout_s" "$stream_tmp" "$body_file" "$host" "$case_name" "$model" "${bearer}" <<PY
import json, os, re, sys, time, urllib.request, urllib.error
base, to_s, outpath, body_path, host, case_name, model, bearer = sys.argv[1:9]
to_s = float(to_s)
body = open(body_path, "rb").read()
url = base.rstrip("/") + "/v1/chat/completions"
req = urllib.request.Request(url, data=body, method="POST")
req.add_header("Content-Type", "application/json")
if bearer:
    req.add_header("Authorization", "Bearer " + bearer)

t0 = time.time()
first_t = None
tokens = 0
prompt_tokens = None
completion_tokens = None
ok = 1
err = ""
content_re = re.compile(r"\"content\":\"")
usage_re = re.compile(r"\"usage\"\s*:\s*(\{[^}]*\})")

import http.client as _hc
buf = b""
try:
    r = urllib.request.urlopen(req, timeout=to_s)
    while True:
        try:
            chunk = r.read(1024)
        except _hc.IncompleteRead as ire:
            # Server closed without Content-Length — SSE streams do this.
            # Treat partial payload as success if we have any content bytes.
            chunk = ire.partial or b""
            if chunk:
                buf += chunk
                if first_t is None and content_re.search(chunk.decode(errors="ignore")):
                    first_t = time.time() - t0
                tokens += chunk.count(b"\"content\":\"")
            break
        if not chunk: break
        buf += chunk
        if first_t is None and content_re.search(chunk.decode(errors="ignore")):
            first_t = time.time() - t0
        tokens += chunk.count(b"\"content\":\"")
    text = buf.decode(errors="ignore")
    for m in usage_re.finditer(text):
        try:
            u = json.loads(m.group(1))
            prompt_tokens = u.get("prompt_tokens") or prompt_tokens
            completion_tokens = u.get("completion_tokens") or completion_tokens
        except Exception:
            pass
except urllib.error.HTTPError as e:
    ok = 0; err = "HTTP " + str(e.code) + " " + e.reason
    try: err = err + " " + e.read().decode(errors="ignore")[:200]
    except Exception: pass
except Exception as e:
    ok = 0; err = str(e)[:200]

# Bench success criteria: ok still 1, and we got either content tokens or usage tokens.
if ok == 1 and tokens == 0 and not completion_tokens:
    ok = 0
    if not err: err = "no-tokens-received"

total = time.time() - t0
record = {
  "host": host, "case": case_name, "model": model,
  "ttft_ms": round((first_t or 0) * 1000) if ok else 0,
  "total_ms": round(total * 1000),
  "completion_tokens": completion_tokens if completion_tokens is not None else tokens,
  "prompt_tokens": prompt_tokens if prompt_tokens is not None else 0,
  "tps": round(((completion_tokens if completion_tokens else tokens) / total) if total > 0 else 0, 2),
  "ok": ok,
}
if err: record["err"] = err
print(json.dumps(record))
PY
'

# Discover locally-loaded model ID on each host (first non-teale-auto entry).
# macOS bash 3.2 lacks associative arrays; we use a pipe-delimited list instead.
LOCAL_MODEL_LIST=""
for h in "${TARGETS[@]}"; do
  m=$(ssh -o ConnectTimeout=10 "$h" 'curl -s -m 8 http://127.0.0.1:11435/v1/models 2>/dev/null' \
      | python3 -c '
import sys, json
try:
    data = json.load(sys.stdin)
    # Prefer canonical slugs over filesystem paths — the local API recognizes both,
    # but catalog-matched slugs give cleaner bench labels.
    cand_slug = None
    cand_path = None
    for m in data.get("data", []):
        mid = m.get("id", "")
        if not mid or mid == "teale-auto": continue
        if mid.startswith("/"): cand_path = cand_path or mid
        else: cand_slug = cand_slug or mid
    print(cand_slug or cand_path or "")
except Exception:
    print("")' 2>/dev/null)
  LOCAL_MODEL_LIST="${LOCAL_MODEL_LIST}${h}=${m}"$'\n'
  echo "  discovered local model on $h: ${m:-<none>}"
done
echo

local_model_for() {
  local host="$1"
  echo "$LOCAL_MODEL_LIST" | awk -F'=' -v h="$host" '$1==h {print $2; exit}'
}

for host in "${TARGETS[@]}"; do
  outfile="$OUT/${host}.jsonl"
  : > "$outfile"
  echo "-- $host"

  cases=()
  local_model="$(local_model_for "$host")"
  if [ -n "$local_model" ]; then
    cases+=("local|http://127.0.0.1:11435|${local_model}|")
  fi
  cases+=("gateway-auto|${GATEWAY_URL}|teale-auto|${GATEWAY_TOKEN}")
  case "$host" in
    tailor512g*) cases+=("gateway-kimi|${GATEWAY_URL}|moonshotai/kimi-k2.6|${GATEWAY_TOKEN}") ;;
  esac

  for c in "${cases[@]}"; do
    IFS="|" read -r name base_url model bearer <<< "$c"
    echo "    case $name → $base_url $model"
    for iter in $(seq 1 "$REQUESTS_PER_CASE"); do
      out=$(ssh -o ConnectTimeout=15 "$host" \
        "bash -s '$host' '$name' '$base_url' '$model' '$bearer' '$PROMPT' $MAX_TOKENS $REQ_TIMEOUT" \
        <<< "$REMOTE_SCRIPT" 2>/dev/null) || out=""
      if [ -z "$out" ]; then
        out='{"host":"'"$host"'","case":"'"$name"'","model":"'"$model"'","ok":0,"err":"ssh failed"}'
      fi
      # Add iter field
      out=$(python3 -c "import json,sys; d=json.loads(sys.argv[1]); d['iter']=$iter; print(json.dumps(d))" "$out" 2>/dev/null || echo "$out")
      echo "$out" >> "$outfile"
    done
  done
done

echo
echo "==> summary"
python3 - "$OUT" <<'PY' | tee "$OUT/summary.txt"
import json, os, sys, statistics
outdir = sys.argv[1]
rows = []
for f in sorted(os.listdir(outdir)):
    if not f.endswith(".jsonl"): continue
    for line in open(os.path.join(outdir, f)):
        line=line.strip()
        if not line.startswith("{"): continue
        try: rows.append(json.loads(line))
        except: pass

from collections import defaultdict
buckets = defaultdict(list)
for r in rows:
    buckets[(r.get("host"), r.get("case"))].append(r)

print(f"{'host':28} {'case':14} {'ok/tot':>7} {'p50 ttft':>9} {'p95 ttft':>9} {'p50 ms':>8} {'p95 ms':>8} {'p50 tps':>8}  model")
print("-" * 130)
summary = {}
for (host, case), items in sorted(buckets.items()):
    oks = [r for r in items if r.get("ok") == 1]
    ttfts = [r.get("ttft_ms") or 0 for r in oks]
    totals = [r.get("total_ms") or 0 for r in oks]
    tpss = [r.get("tps") or 0 for r in oks]
    model = items[0].get("model", "?")
    def p(vals, q):
        if not vals: return 0
        if q == 50: return statistics.median(vals)
        s = sorted(vals); idx = min(len(s)-1, max(0, int(round(q/100*len(s))-1)))
        return s[idx]
    model_short = (model[:40] + "...") if len(model) > 40 else model
    print(f"{str(host):28} {str(case):14} {f'{len(oks)}/{len(items)}':>7} {p(ttfts,50):>9.0f} {p(ttfts,95):>9.0f} {p(totals,50):>8.0f} {p(totals,95):>8.0f} {p(tpss,50):>8.2f}  {model_short}")
    summary.setdefault(host, {})[case] = {
        "ok": len(oks), "total": len(items),
        "p50_ttft_ms": p(ttfts, 50), "p95_ttft_ms": p(ttfts, 95),
        "p50_total_ms": p(totals, 50), "p95_total_ms": p(totals, 95),
        "p50_tps": p(tpss, 50),
        "model": model,
    }

with open(os.path.join(outdir, "summary.json"), "w") as f:
    json.dump(summary, f, indent=2)
print()
print(f"wrote {outdir}/summary.json")
PY
