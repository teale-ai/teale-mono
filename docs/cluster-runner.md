# Cluster runner — paired Mac Studio Ultra 1 TB setup

Phase C1: serve models that do not fit on a single Mac across two M3 Ultra
512 GB Studios paired via EXO or `llama.cpp` RPC. The current production
target is `moonshotai/kimi-k2.6`, presented to the gateway as one dedicated
very-large supply node.

## Why this matters

These models have almost no supply on OpenRouter today. Being one of the
few self-hosted providers that can serve Kimi K2.6 at production latency is
a meaningful differentiator. Per `docs/openrouter-open-weight-catalog.md`
they are in the "Tier 5 — cluster only" row.

## Hardware prerequisites

- Two Mac Studio M3 Ultra, each with 512 GB unified memory.
- Thunderbolt Bridge or 10GbE between them. **Thunderbolt 5 RDMA is the
  intended tensor-parallel path.** 10GbE is acceptable for capacity-driven
  sharding, but expect worse TTFT and weaker scaling. **Wi-Fi is not
  acceptable** —
  exo transfers hidden-state tensors on every token; Wi-Fi latency/loss
  cripples throughput.
- Both Macs should be dedicated to the cluster while Kimi is running.
  Do not leave another 300 GB to 600 GB local model loaded in the Teale app
  or you will starve EXO before placement completes.

## Software prerequisites

**Both machines:**
- macOS 15+
- Homebrew
- Python 3.12+ (`brew install python@3.12`)
- EXO.app installed in `/Applications/EXO.app`

**Head machine only:**
- Passwordless SSH to the leaf (`ssh-copy-id leaf-ip`)
- teale-node agent (built from this workspace)

## Start the cluster

On the head Mac:

```bash
export LEAF_HOST=10.0.0.11                # the other Mac's routable EXO/libp2p IP
export LEAF_SSH_TARGET=teale@10.0.0.11    # optional if SSH target differs from LEAF_HOST
export EXO_MODEL_ID=teale/Kimi-K2.6-32k   # lower-context alias for more runtime headroom
bash node/scripts/cluster-runner.sh
```

The script:
1. Verifies SSH to the leaf.
2. Starts the leaf EXO worker through the EXO.app CLI.
3. Exports EXO's bundled `_internal` tools onto `PATH` so `macmon` is available
   and placement uses the better Apple Silicon memory monitor instead of falling
   back to `psutil`.
4. Starts the head EXO master with a fixed libp2p peer.
4. Repeatedly calls `/instance/previews` and `/instance` until
   `teale/Kimi-K2.6-32k` is actually placed, rather than trusting a bare
   `200` from `:52415`.
5. Defaults to `--offline`, `--no-downloads`, and `--no-batch` to leave
   more headroom for one flagship model instead of chasing peak throughput.
6. Keeps the gateway-facing model id canonical (`moonshotai/kimi-k2.6`) even
   though EXO itself loads the lower-context local alias.

Verify locally:

```bash
curl -s http://127.0.0.1:52415/ollama/api/ps
# expect to see teale/Kimi-K2.6-32k in the returned models list

curl -s http://127.0.0.1:52415/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"teale/Kimi-K2.6-32k","messages":[{"role":"user","content":"hi"}],"stream":false}'
```

Once the gateway catalog includes Kimi, clients may also target the
Conductor-friendly alias `kimi2.6`; the supply side should still advertise
the canonical model id `moonshotai/kimi-k2.6`.

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
(`moonshotai/kimi-k2.6`) with the head Mac's node identity. Client-facing
aliases such as `kimi2.6` are resolved by the gateway catalog, not by the
cluster runner.

## DeepSeek V4 matrix

For the 2× 512 GB setup, benchmark `DeepSeek-V4-Flash` and `DeepSeek-V4-Pro`
as separate deployment shapes instead of treating "fits in cluster RAM" as the
only question:

- `DeepSeek-V4-Flash` single-node — baseline on one 512 GB Ultra. This is the
  control case because Flash should fit on one node without tensor parallelism.
- `DeepSeek-V4-Flash` 2-node tensor parallel — only worth promoting if it beats
  the single-node baseline on warm TTFT and sustained decode after paying the
  inter-node communication tax.
- `DeepSeek-V4-Pro` 2-node tensor parallel — capacity-only candidate. Do not
  promote it unless the current `exo + MLX` stack proves it can load
  `model_type=deepseek_v4` cleanly.

Use [docs/deepseek-v4-exo-benchmarks.md](./deepseek-v4-exo-benchmarks.md) for
the exact benchmark matrix and [scripts/bench-deepseek-v4-exo.sh](../scripts/bench-deepseek-v4-exo.sh)
to capture TTFT/TPS summaries from any OpenAI-compatible endpoint.

## Running as a daemon

`node/scripts/cluster-runner.sh` is foreground by design (easy to stop).
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
    <string>/Users/teale/teale-node/node/scripts/cluster-runner.sh</string>
    <string>moonshotai/kimi-k2.6</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>LEAF_HOST</key><string>10.0.0.11</string>
    <key>LEAF_SSH_TARGET</key><string>teale@10.0.0.11</string>
    <key>EXO_MODEL_ID</key><string>teale/Kimi-K2.6-32k</string>
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
  next-best device (which for Kimi K2.6 is probably no-one — see the
  per-model fleet floor in `gateway/gateway.toml`, set to 1 for Tier-5
  cluster models; we'll list them as "degraded" rather than "healthy"
  until a second paired cluster comes online).
- To detect leaf-crash early, the head's exo emits discovery pings
  every 1 s. If 5 are missed the head short-circuits to an error.
- Thermal throttling on either Mac drops overall throughput but doesn't
  break the session. Watch the `gateway_ttft_seconds` histogram for
  Tier-5 entries — a climb beyond p95 5 s means one Mac is thermal-bound.

## Alternatives to exo

If EXO's MoE sharding still proves unreliable in production, `llama.cpp`'s
built-in RPC server is a more conservative fallback:

```bash
# On leaf:
rpc-server -p 50052 -t 8

# On head:
llama-server \
  --model /models/kimi-k2.6-q4_k_m.gguf \
  --rpc leaf-ip:50052 \
  --port 52415 \
  --host 127.0.0.1 \
  -ngl 999
```

Lower abstraction but fewer moving parts than EXO's dependency stack.
Kimi K2.6 MoE routing is not as clean without EXO's expert-aware
sharding; expect worse throughput but more predictable behavior.

## Adding more models to the cluster

Once one Kimi K2.6 cluster is healthy, add a second paired cluster for
DeepSeek V3 Q8 (~713 GB) — same recipe, different `--models` flag. Each
pair presents as its own teale-node to the relay. The gateway's
per-model fleet floor then lifts DeepSeek from "degraded" to "healthy"
once two independent clusters are online.
