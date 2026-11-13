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

### Experimental scenarios

`stress/scenarios/experimental/` holds scenarios that cannot run as-is and
are excluded from the nightly loop (which only globs the top-level
`stress/scenarios/*.toml`):

- `mesh_dense405_agentic_steady.toml` targets `nousresearch/hermes-4-405b`,
  which is not in `gateway/models.yaml`.
- `mesh_kimi_fault_head.toml` / `mesh_kimi_fault_participant.toml` carry
  `REPLACE_WITH_*` SSH targets. `teale-stress` refuses to load a scenario
  whose fault target still starts with `REPLACE_WITH`; copy the file and set
  a real host first.

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
| `kill_backend`    | `pkill -TERM llama-server` (or `mnn_llm`) on the target host (supervisor should restart it) |
| `kill_node`       | `pkill -KILL teale-node` (SIGKILL, simulates a crash)  |
| `block_ws`        | Block outbound TCP :443 for N seconds: pfctl anchor `teale-stress` on macOS, an iptables `OUTPUT` REJECT rule tagged `teale-stress` on Linux (removed afterwards) |
| `pause_heartbeat` | `SIGSTOP` the node process for N seconds, then `SIGCONT` |
| `malformed_chunk` | Not implemented: logs a warning only (needs the proxy described below) |

Requires passwordless SSH (key auth, plus passwordless `sudo` for
`block_ws`) to targets. For macOS targets use `ssh-host-*` aliases in
`~/.ssh/config`. Host keys are verified: the harness runs `ssh -o
BatchMode=yes`, so every target must already be in `~/.ssh/known_hosts`
(connect once by hand, or set `StrictHostKeyChecking accept-new` for those
hosts in your SSH config). On macOS, pf only evaluates the `teale-stress`
anchor if `/etc/pf.conf` references it (`anchor "teale-stress"`).

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

For a nightly regression, wrap in a shell script (top-level scenarios only;
`experimental/` is skipped on purpose):

```bash
#!/usr/bin/env bash
set -e
cargo build -p teale-stress --release
for s in stress/scenarios/*.toml; do
    target/release/teale-stress run --scenario "$s" --out runs/
done
```

Check every `summary.json` for `"pass_steady_state": true` before green.
