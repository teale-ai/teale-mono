# teale-stress — load + fault-injection for the gateway

Binary for exercising `gateway.teale.com` end-to-end before submitting the
OpenRouter application. Scenarios declare request mix, RPS, duration, and
optional scheduled faults; results land as JSONL + a summary JSON.

## Build

```bash
cargo build -p teale-stress --release
```

## Run

Point at a dev gateway and supply a token:

```bash
export GATEWAY_DEV_TOKEN=tok_dev_xxxxxxxx
target/release/teale-stress run --scenario stress/scenarios/cold_start.toml --out runs/
```

The run creates `runs/<scenario>_<uuid>/` containing:

| File           | Description                                 |
|----------------|---------------------------------------------|
| `scenario.toml`| Copy of the scenario file (reproducibility) |
| `records.jsonl`| One JSON record per request (see `record.rs`)|
| `summary.json` | Aggregate: success rate, TTFT/latency percentiles, pass flag |

## Scenario fields

Each `[[requests]]` entry can now shape more agent-like traffic:

- `user_agent = "OpenClaw/1.0"` to exercise gateway auto-routing heuristics
- `message_profile = "plain" | "agentic_coding" | "agentic_long_context"`
- `tool_profile = "none" | "repo_probe"` to send OpenAI-style tool schemas
- `tool_choice = "auto"` (or another OpenAI-compatible string) when the
  request should explicitly include a `tool_choice`

The new mesh evaluation scenarios under `stress/scenarios/mesh_*` use these
fields to drive tool-bearing, multi-turn, longer-context requests through the
same `/v1/chat/completions` path as the existing readiness tests.

## Pass criteria (per scenario)

| Scenario           | Must hit                                                          |
|--------------------|-------------------------------------------------------------------|
| `cold_start`       | success_rate ≥ 0.995, p95 TTFT ≤ 5 s                              |
| `steady_state`     | success_rate ≥ 0.995, p95 TTFT ≤ 2 s (small) / 5 s (70B)          |
| `burst`            | success_rate ≥ 0.97, gateway RSS growth ≤ 100 MB, recovery < 60 s |
| `fault_kill_backend` | recovery TTR ≤ 30 s, in-flight success ≥ 0.80 during fault window |
| `soak_24h`         | success_rate ≥ 0.995, RSS growth ≤ 100 MB, no operator intervention |

Phase A gate: all scenarios except `soak_24h` pass.
Phase B gate: add `soak_24h`.
Phase D gate: re-run every scenario on a fresh deploy, then 48 h unattended.

## Fault injection

`scenarios/fault_*.toml` declare faults that fire at specific offsets:

| Kind              | Effect                                                 |
|-------------------|--------------------------------------------------------|
| `kill_backend`    | `pkill llama-server` on the target host (supervisor should restart it) |
| `kill_node`       | `pkill teale-node` (simulates crash)                   |
| `block_ws`        | Block outbound TCP :443 via pfctl for N seconds        |
| `pause_heartbeat` | `SIGSTOP` the node process for N seconds, then `SIGCONT` |
| `malformed_chunk` | Requires the fault-injection proxy (see below)         |

Requires passwordless SSH to targets. For macOS targets use `ssh-host-*`
aliases in `~/.ssh/config`.

## Analyzing

```bash
target/release/teale-stress analyze --run runs/steady_state_abc123
```

Prints `summary.json`. For deeper digs, the `records.jsonl` is one line per
request — pipe through `jq`:

```bash
jq -c 'select(.status != "ok") | {model, status, error}' runs/*/records.jsonl | sort | uniq -c | sort -rn
```

## Malformed-chunk proxy (not in this build)

To inject bad JSON mid-stream, put a tiny TCP proxy between the node's
local llama-server port (11436) and the node process. When `malformed_chunk`
fires, flip the proxy to corrupt the `data:` line of the next SSE event.
Scaffold is TBD in a follow-up — this harness logs the attempt so runs can
be paired with manual corruption.

## CI / automation

For a nightly regression, wrap in a shell script:

```bash
#!/usr/bin/env bash
set -e
cargo build -p teale-stress --release
for s in stress/scenarios/*.toml; do
    target/release/teale-stress run --scenario "$s" --out runs/
done
```

Check every `summary.json` for `"pass_steady_state": true` before green.
