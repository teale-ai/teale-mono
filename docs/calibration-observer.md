# Isolated llama decode observer: proposed bounded campaign

This preparation does not authorize a launch. Fleet owns launch/stop and confirms
user scope, exact target, binary, machine, resident constraints and timing first.
Box 64 excluded; box 512g8 excluded until the Citadel boundary is cleared.
Daily-use 16/96/Air excluded. No model downloads/installs or production flips.

## Phase 0: 512g1 eligibility (reads only)

Resolve existing Hermes 8B GGUF and existing llama binary, record full digests,
build/OS identity, launch configuration, actual vm_stat/memory_pressure/swap and
existing server logs. Inactive/reclaimable RAM is not available-capacity proof.
No RSS-only value is labeled total Metal-inclusive peak. If current headroom,
model path, build or state accounting cannot be established, stop before load.

## Proposed launch envelope, pending approval and exact fleet facts

- Existing 8B Hermes, plain decode, no speculation/draft; unchanged residents.
- Own loopback port and PID, never gateway/relay registration or production port.
- Start ctx4096 per request, concurrency1, GPU placement reviewed against pinned
  binary. Expand only to ctx8192 and concurrency2 after first case is clean.
- Separate process-wide shared context/slot budget from per-request context;
  e.g. ctx8192 per request x2 can require combined ctx16384, depending on build.
- Maximum 30 minutes first phase including load; maximum 90 seconds per request,
  128 generated tokens, no retry after timeout/error. One request group at a time.
- Fleet samples memory-pressure/swap/allocation accounting while own process
  runs. Stop own PID on warning/critical pressure, any new swap growth >256 MiB,
  sustained <32 GiB verified headroom, unexpected resident-service regression,
  allocator error, missing server generation counters or workload truncation.
- These conservative proposed limits need fleet review against real telemetry;
  do not infer a numerical memory guarantee from them. Never intentionally OOM.
- Stop only own process, restore any expressly authorized test-window change and
  verify live resident endpoints/relay state afterward. If residents cannot be
  protected or the observer is incomplete, report no calibration result.

## Observer

`scripts/calibration/observe_llama.py` observes an already-started approved server.
It cannot launch/stop/kill, SSH, select models, change supply or fetch off-host.
Only literal HTTP loopback origins with an explicit port are accepted; proxies
and redirects disabled. Identity model/binary hashes must match local files.
Concurrency 1/2, at most 90s, max128 output tokens. Output uses exclusive create
and 0600; never overwrites evidence. Full responses are retained (synthetic
prompts only, no owner/private data). Unknown/missing server counters stay null.

```sh
python3 scripts/calibration/observe_llama.py \
  --origin http://127.0.0.1:11991 --identity /local/campaign/identity.json \
  --model-file /exact/existing/model.gguf --binary-file /exact/existing/llama-server \
  --prompt-file /local/campaign/synthetic-prompt.txt \
  --out /local/campaign/observation-01.json --concurrency 1
```

Identity uses the same seven fields as `validate-evidence`, but this observation
is deliberately not a RawRun. Launch flags/build/served target need independent
verification. No peak/capacity/eval is invented. Wall time is named including
prefill; decode comes only from server `timings.predicted_n / predicted_ms`.
No counting SSE chunks or dividing tokens by full request time. Per-response
TPS at concurrency2 is not aggregated simultaneous wall throughput.

## Proof remains separate

One-device observations cannot clear the two-device held-out gate. First training
samples must fit predictor costs, then freeze the model and pre-register held-out
predictions before collection. Need >=20 predicted-fit successful held-out
loads/decode cases across >=2 devices, contexts and concurrency settings, valid
all-domain peak/capacity, tool/cancellation evaluation and <=20% median absolute
relative decode error. No false fits. Actual peak modeling and trusted source
freshness still require a producer. No observer output authorizes selection.

Pinned timing-source semantics reviewed in llama.cpp c96ffc869:
https://github.com/ggml-org/llama.cpp/blob/c96ffc869/tools/server/server-context.cpp
https://github.com/ggml-org/llama.cpp/blob/c96ffc869/tools/server/server-task.cpp
Other builds must be independently inspected before accepting counter semantics.

## Grounded 512g1 target and build (Oct 2 inventory)

Model: `/Users/tailor512g1/Library/Application Support/Teale/gguf/Hermes-3-Llama-3.1-8B-Q5_K_M.gguf`, 5,732,987,808 bytes. Full model hash must still be collected before launch.
Binary: `/Users/tailor512g1/.local/bin/llama-server`, build b8855/81df3f7cf,
SHA256 `07cc25e06d71512b462057e25142cf41b43746882b4ef30297cf274f44161d26`.
Source 81df3f7cf has the same generation-only `predicted_n`/`predicted_ms`
semantics and 256-cell context rounding. Keep the 8805-only `models inspect`
formula restriction intact: this observer does not expand that producer contract.

Fleet-reported live startup components at ctx32768/one slot: MTL0 model 5115.49
MiB, CPU model 344.44 MiB, q4_0 K+V KV 1152 MiB, MTL0 compute 517 MiB and CPU
compute 160.11 MiB. Those are allocation-log components, not a measured complete
runtime peak. Fleet inventory showed zero swap and 114.7GB free at the read time;
re-check at actual launch. GLM stays live, never restarted by this campaign.

Reviewed build sources:
https://github.com/ggml-org/llama.cpp/blob/81df3f7cf/tools/server/server-context.cpp
https://github.com/ggml-org/llama.cpp/blob/81df3f7cf/tools/server/server-task.cpp
https://github.com/ggml-org/llama.cpp/blob/81df3f7cf/src/llama-context.cpp
