# Mesh-LLM Backend Evaluation

Evaluate `mesh-llm` as a **backend supplier cluster** while keeping
`gateway.teale.com` as the only public/frontend API.

The contract stays:

```text
client -> gateway.teale.com -> teale-node head -> mesh-llm local API
```

This is intentionally **not** a public raw `mesh-llm` deployment. The gateway
still owns auth, catalog, usage/accounting, and any client-protocol
normalization above plain supplier behavior.

## Scope

- Primary MoE target: `moonshotai/kimi-k2`
- Secondary dense target: `nousresearch/hermes-4-405b`
- Dense fallback: `meta-llama/llama-3.1-405b-instruct`
- 16 GB machines are admitted as full pilot participants, but dense-model pass
  contribution is still gated by measured RTT to the head plus observed TTFT.

## Artifacts

- Runner: [scripts/mesh-llm-cluster-runner.sh](../scripts/mesh-llm-cluster-runner.sh)
- Inventory: [scripts/mesh-cluster-inventory.sh](../scripts/mesh-cluster-inventory.sh)
- Head node template: [node/teale-node.mesh.toml](../node/teale-node.mesh.toml)
- Agentic scenarios:
  - [stress/scenarios/mesh_kimi_agentic_steady.toml](../stress/scenarios/mesh_kimi_agentic_steady.toml)
  - [stress/scenarios/mesh_kimi_agentic_burst.toml](../stress/scenarios/mesh_kimi_agentic_burst.toml)
  - [stress/scenarios/mesh_dense405_agentic_steady.toml](../stress/scenarios/mesh_dense405_agentic_steady.toml)
  - [stress/scenarios/mesh_kimi_fault_head.toml](../stress/scenarios/mesh_kimi_fault_head.toml)
  - [stress/scenarios/mesh_kimi_fault_participant.toml](../stress/scenarios/mesh_kimi_fault_participant.toml)

## 1. Inventory The Candidate Fleet

Run this before admitting nodes so RTT and storage are captured from the real
hosts, not guessed from the spreadsheet:

```bash
scripts/mesh-cluster-inventory.sh \
  --head ultra-head \
  ultra-head leaf-a leaf-b tailor16 \
  > runs/mesh-inventory.tsv
```

What to record from the TSV:

- per-machine memory
- mesh version
- RTT from each participant to the intended head
- whether the local mesh API is already live on `:52415`
- free space on the candidate model-storage paths

Interpretation:

- MoE meshes may still benefit from slower / smaller participants.
- Dense pipeline meshes should treat high-RTT or obviously constrained 16 GB
  nodes as admitted-but-non-contributing unless the measured TTFT says
  otherwise.

## 2. Start The Mesh

On the head:

```bash
scripts/mesh-llm-cluster-runner.sh \
  head \
  --model moonshotai/kimi-k2 \
  --port 52415 \
  --console 53131 \
  --log logs/mesh-kimi-head.jsonl
```

The runner forces `--log-format json`. The head emits an `invite_token` event.
Use that token on the other machines:

```bash
scripts/mesh-llm-cluster-runner.sh \
  join \
  --model moonshotai/kimi-k2 \
  --join-token '<invite-token>' \
  --port 52415 \
  --console 53131 \
  --log logs/mesh-kimi-leaf.jsonl
```

Client-only participant:

```bash
scripts/mesh-llm-cluster-runner.sh \
  client \
  --join-token '<invite-token>' \
  --port 52415 \
  --console 53131 \
  --log logs/mesh-kimi-client.jsonl
```

Health checks on the head:

```bash
curl -s http://127.0.0.1:52415/v1/models
curl -s http://127.0.0.1:53131/api/status
```

Dense target:

```bash
scripts/mesh-llm-cluster-runner.sh head --model nousresearch/hermes-4-405b --log logs/mesh-h405-head.jsonl
```

Fallback if Hermes 405B is unavailable:

```bash
scripts/mesh-llm-cluster-runner.sh head --model meta-llama/llama-3.1-405b-instruct --log logs/mesh-l405-head.jsonl
```

## 3. Put The Head Behind The Gateway

On the head machine:

```bash
teale-node --config node/teale-node.mesh.toml --no-backend
```

Then verify the gateway-facing supplier path:

```bash
curl -s http://127.0.0.1:52415/v1/models
curl -s -H "Authorization: Bearer $GATEWAY_DEV_TOKEN" \
  https://gateway.teale.com/v1/models
```

Important boundary:

- keep external agent traffic on `gateway.teale.com/v1/chat/completions`
- do not point clients directly at the raw mesh API for this pilot
- if a client needs Responses-style normalization, keep that at the gateway

## 4. Run The A/B Workloads

Build the load generator:

```bash
cargo build -p teale-stress --release
```

Run each scenario three times:

1. current non-mesh supplier path
2. mesh without 16 GB participants
3. same mesh with the 16 GB participants admitted

Kimi steady-state:

```bash
target/release/teale-stress run \
  --scenario stress/scenarios/mesh_kimi_agentic_steady.toml \
  --out runs/
```

Kimi burst:

```bash
target/release/teale-stress run \
  --scenario stress/scenarios/mesh_kimi_agentic_burst.toml \
  --out runs/
```

Dense 405B steady-state:

```bash
target/release/teale-stress run \
  --scenario stress/scenarios/mesh_dense405_agentic_steady.toml \
  --out runs/
```

The new scenarios intentionally send:

- `OpenClaw/1.0` user-agent
- multi-turn agentic messages
- tool definitions via `tool_profile = "repo_probe"`
- longer contexts than the basic readiness scenarios

## 5. Run The Fault Tests

Replace the placeholder SSH targets first, then run:

```bash
target/release/teale-stress run \
  --scenario stress/scenarios/mesh_kimi_fault_head.toml \
  --out runs/

target/release/teale-stress run \
  --scenario stress/scenarios/mesh_kimi_fault_participant.toml \
  --out runs/
```

These cover:

- kill one non-head participant before first token
- kill the head/coordinator before first token

For the 16 GB dropout check, point `mesh_kimi_fault_participant.toml` at the
16 GB participant specifically.

## Pass / Fail

The backend mesh is realistic only if all of these hold:

- steady-state success rate `>= 0.995`
- no manual restarts during the 15-minute steady run
- no runaway TTFT / queue spiral during the burst run
- the mesh-backed path matches or beats the non-mesh baseline on success rate
- the topology with 16 GB participants does not worsen p95 TTFT by more than
  15% versus the same mesh without them

Recommendation rule:

- if 16 GB nodes help MoE but hurt dense latency, keep them in MoE meshes and
  exclude them from dense pass-contributor sets

## Notes

- Existing repo context already treats `kimi-k2` and 405B-class models as
  cluster-only territory; this workflow is the concrete follow-through.
- The stress harness does not assume transparent mid-stream failover. Once a
  stream has started, first-token success is the retry boundary unless the
  gateway grows stronger semantics above the supplier.
