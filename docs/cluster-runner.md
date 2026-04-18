# Cluster runner — paired Mac Studio Ultra 1 TB setup

Phase C1: serve models that don't fit on a single Mac (Kimi K2 1T, DeepSeek
V3/R1 at Q8, Llama 405B at Q8) across two M3 Ultra 512 GB Studios paired
via `exo` or `llama.cpp` RPC. From the gateway's perspective the pair
looks like a single very-large supply node.

## Why this matters

These models have almost no supply on OpenRouter today. Being one of the
few self-hosted providers that can serve Kimi K2 at production latency is
a meaningful differentiator. Per `docs/openrouter-open-weight-catalog.md`
they're all in the "Tier 5 — cluster only" row.

## Hardware prerequisites

- Two Mac Studio M3 Ultra, each with 512 GB unified memory.
- Thunderbolt Bridge or 10GbE between them. **Wi-Fi is not acceptable** —
  exo transfers hidden-state tensors on every token; Wi-Fi latency/loss
  cripples throughput.
- Shared storage holding the GGUFs, mounted on both machines. Either:
  - NFS from a NAS on the same LAN, or
  - Thunderbolt-attached external SSD mounted on the head, re-shared
    via SMB to the leaf.

## Software prerequisites

**Both machines:**
- macOS 15+
- Homebrew
- Python 3.12+ (`brew install python@3.12`)

**Head machine only:**
- Passwordless SSH to the leaf (`ssh-copy-id leaf-ip`)
- exo: `pip install exo` (https://github.com/exo-explore/exo)
- teale-node agent (built from this workspace)

## Start the cluster

On the head Mac:

```bash
export HEAD_IP=10.0.0.10        # this Mac
export LEAF_IP=10.0.0.11        # the other Mac
bash scripts/cluster-runner.sh moonshotai/kimi-k2
```

The script:
1. Verifies SSH to the leaf.
2. Starts `exo serve` on the leaf (background, via SSH).
3. Starts `exo serve` on the head (foreground), which joins the mesh.
4. exo auto-shards Kimi K2's MoE weights so each machine holds ~50% of
   the experts. Runtime spreads hidden-state tensors between them.

Verify locally:

```bash
curl -s http://127.0.0.1:52415/v1/models
# expect: { "data": [ { "id": "moonshotai/kimi-k2", ... } ] }

curl -s http://127.0.0.1:52415/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"moonshotai/kimi-k2","messages":[{"role":"user","content":"hi"}],"stream":false}'
```

## Connect to the relay as a node

Start a second terminal on the head Mac:

```bash
teale-node --config teale-node.cluster.toml --no-backend
```

`--no-backend` tells teale-node **not** to spawn llama-server itself
(the cluster runner is already serving on port 52415). The node
just proxies OpenAI-compat requests to it, then streams results back
through the relay.

From the gateway's `/v1/models` the cluster appears as a single entry
(`moonshotai/kimi-k2`) with the head Mac's node identity.

## Running as a daemon

`scripts/cluster-runner.sh` is foreground by design (easy to stop).
For production, wrap it in a launchd plist so it starts at boot:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>com.teale.cluster-runner</string>
  <key>ProgramArguments</key>
  <array>
    <string>/usr/local/bin/bash</string>
    <string>/Users/teale/teale-node/scripts/cluster-runner.sh</string>
    <string>moonshotai/kimi-k2</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>LEAF_IP</key><string>10.0.0.11</string>
    <key>HEAD_IP</key><string>10.0.0.10</string>
  </dict>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>/var/log/teale-cluster-runner.out</string>
  <key>StandardErrorPath</key><string>/var/log/teale-cluster-runner.err</string>
</dict>
</plist>
```

Save as `~/Library/LaunchAgents/com.teale.cluster-runner.plist` and:

```bash
launchctl load ~/Library/LaunchAgents/com.teale.cluster-runner.plist
```

## Health / failure semantics

- If either Mac reboots or crashes, exo aborts the current inference
  with a 5xx upstream error. The teale-node agent surfaces that to the
  relay as an `inferenceError`, and the gateway retries once on the
  next-best device (which for Kimi K2 is... probably no-one — see the
  per-model fleet floor in `gateway/gateway.toml`, set to 1 for Tier-5
  cluster models; we'll list them as "degraded" rather than "healthy"
  until a second paired cluster comes online).
- To detect leaf-crash early, the head's exo emits discovery pings
  every 1 s. If 5 are missed the head short-circuits to an error.
- Thermal throttling on either Mac drops overall throughput but doesn't
  break the session. Watch the `gateway_ttft_seconds` histogram for
  Tier-5 entries — a climb beyond p95 5 s means one Mac is thermal-bound.

## Alternatives to exo

If exo's MoE sharding proves unreliable in production, `llama.cpp`'s
built-in RPC server is a more conservative fallback:

```bash
# On leaf:
rpc-server -p 50052 -t 8

# On head:
llama-server \
  --model /models/kimi-k2-q4_k_m.gguf \
  --rpc leaf-ip:50052 \
  --port 52415 \
  --host 127.0.0.1 \
  -ngl 999
```

Lower abstraction but fewer moving parts than exo's Python dependency
stack. Kimi K2 MoE routing is not as clean without exo's expert-aware
sharding; expect worse throughput but more predictable behavior.

## Adding more models to the cluster

Once one Kimi K2 cluster is healthy, add a second paired cluster for
DeepSeek V3 Q8 (~713 GB) — same recipe, different `--models` flag. Each
pair presents as its own teale-node to the relay. The gateway's
per-model fleet floor then lifts DeepSeek from "degraded" to "healthy"
once two independent clusters are online.
