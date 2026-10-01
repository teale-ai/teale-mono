# Evidence-tagged model-fit assessment: read-only foundation

```sh
teale models assess --plan cli/tests/fixtures/fit-plan.json
```

The Rust CLI reads an explicit JSON load plan, adds physical-memory-domain
charges and reports `modeled_fit` or `modeled_does_not_fit`, limiting domain,
required bytes, signed remaining bytes and provenance of every term. It never
connects to the daemon, loads/downloads a model, changes profiles or routes,
runs a benchmark or spends credits. Output is JSON even without --json.
The included fixture is synthetic, not measured hardware/model evidence.

This is the stage-2 schema/arithmetic foundation, not automatic header extraction
or a validated recommendation engine. The person preparing the plan must obtain
exact artifact and backend facts. No fit/speed claim is promoted to production
routing by this command. Existing profile precedence and admission remain intact.

## Input contract

Required identifiers: version=1, deviceId, backend, backendRevision, modelId,
artifactId, contextTokens, concurrency and nonempty domains. All terms are bytes,
not GB/GiB. Every numeric byte input has:

```json
{"value": 1024, "evidence": {"basis": "modeled", "source": "retrievable source or formula version", "asOf": "2026-10-01"}}
```

Basis is `reported`, `published`, `assumed`, `modeled` or `measured`.
`measured` additionally requires benchmarkId identifying raw evidence. These
labels describe supplied evidence, not authentication or validation of the source.
The CLI preserves them but does not dereference sources, check dates/freshness,
verify a benchmark, read GGUF headers or measure current RAM. Never call it a
live measured hardware assessment.

Each physical domain has unique id, capacity, reserve, occupied, weights,
kvPerRequest, scratchPeak, draftPeak and overhead. All are required including
explicit zeros with source evidence:

`required = reserve + occupied + weights + kvPerRequest × concurrency + scratchPeak + draftPeak + overhead`

- Capacity must be the usable capacity for that domain, accounting for process
  limits when lower than physical total. Not an aggregate sum hiding a VRAM deficit.
- Reserve is OS/process headroom; occupied is allocations outside this load plan.
- Weights include all target shards in the domain. Charge aliases once against
  the same physical pool; unified CPU/GPU memory is not two independent capacities.
- kvPerRequest covers the complete configured context under the backend's exact
  attention/state codec. Context in the plan is per request, not a combined slot
  budget. MLA, recurrent/hybrid state and quantized block overhead must come from
  backend-specific evidence; do not apply a dense-attention formula universally.
- scratchPeak is the shared maximum at the declared batch/concurrency.
- draftPeak includes draft weights, state and scratch at the selected method.
  Never omit draft memory when reporting a speculative configuration's fit.
- overhead includes other execution resources absent from these charges.

Every domain must independently fit. Exactly zero remaining bytes is a modeled
fit but offers no spare margin beyond its supplied reserve. Integer overflow,
missing evidence, duplicate domains and absent identity fail closed.
Missing/zero terms supplied falsely cannot be detected: verified peak-memory
runs remain the zero-false-fit/OOM gate before use for automatic selection.

## Optional plain-decode estimate

A decode object can supply bandwidthBytesPerSecond, weightEfficiency,
historyEfficiency, streamedWeightBytes, historyBytes, launchCount, launchSeconds
and stepSeconds. Numeric costs/efficiencies use value+evidence, byte counts use
the same byte contract. No defaults from Magnitude's M4 Max are inserted.

`seconds/token = stepSeconds + launchCount × launchSeconds + streamedWeightBytes/(bandwidth × weightEfficiency) + historyBytes/(bandwidth × historyEfficiency)`

The output is always `analytical_plain_decode`, even if an input was measured.
It is a single-request prediction at the declared context, not speculative
acceptance-adjusted speed, concurrency throughput, TTFT, task success or earnings.
A producer must calibrate cost terms against the pinned backend/device/workload.
Missing decode means no speed prediction, not a guessed speed. Efficiencies must
be in (0,1], bandwidth positive, costs nonnegative and final result finite/positive.

## Next proof gate

Before automatic recommendation/routing, produce header/backend-derived plans
and compare predictions to held-out runs across hardware/context/concurrency:
zero false-fit/OOM cases and <=20% median decode prediction error. Otherwise
rework the producer/cost model and retain existing profiles. A capacity threshold
can be nonlinear; report the exact domain deficit, don't smooth it into a score.
No benchmark or fleet calibration is claimed by this patch.

Architecture informed by Magnitude's evidence-separated assessment, reviewed at
9187740037f41fb208849ac66afb41b41a00c304:
https://github.com/magnitudedev/magnitude/blob/9187740037f41fb208849ac66afb41b41a00c304/inference/engine/executor/src/assessment/assess.rs
https://github.com/magnitudedev/magnitude/blob/9187740037f41fb208849ac66afb41b41a00c304/inference/engine/executor/src/assessment/estimate.rs
https://github.com/magnitudedev/magnitude/blob/9187740037f41fb208849ac66afb41b41a00c304/inference/engine/executor/src/assessment/costs.rs

This Rust code is independently written and no upstream implementation is copied.

## Local artifact / KV payload inspection

```sh
teale models inspect --model /absolute/path/model.gguf \
  --backend-binary /absolute/path/llama-server --backend-revision c96ffc869 \
  --context-tokens 32768 --concurrency 2 --kv-codec q4_0
```

This independent read-only producer inspects little-endian GGUF v3 headers and
validates tensor shapes, byte ranges, alignment and supported storage encodings.
It hashes the full model and binary without executing the binary. It reports
stored tensor payload, metadata key names and modeled total KV payload. No
`assess` plan is synthesized: scratch, buffer overhead, memory placement, mmap
resident copies, draft and live capacity remain unknown. Verdict is always
`not_assessed`. Stored payload is not device-resident peak memory.

The KV formula is narrowly reviewed for llama.cpp source revision `c96ffc869`
(build 8805), plain dense Llama GQA and identical K/V codec (`f16`, `q4_0`,
`q8_0`). Revision and runtime configuration are supplied assertions, not
proved by the binary digest. It cannot certify that a particular binary was
built from that source or actually launched with those flags. Missing head-width
keys default to embedding/head count in this reviewed llama.cpp version, with
every Q/K/V weight shape checked. This is **not** Seismic eligibility: Seismic's
current loader requires explicit width keys. Unknown architectures/features,
shards, arrays in required scalar geometry and unknown encodings fail closed.
A header has a 128 MiB read limit; retained strings and directory counts are
bounded. Tensor contents are not decoded. Q8_1 is excluded due to conflicting
Python-vs-C layout descriptions in this revision, rather than guessing its size.

Context means per request, rounded up to 256 cells, then multiplied by concurrency.
Do not copy llama-server's combined `--ctx-size` into a per-request input without
checking slot/unified-cache semantics. No TTFT, decode speed, fit or safe-load
claim is made. Full-file hashing can take time on large local artifacts.
Length/mtime changes during inspection are rejected; use immutable regular
files for a consistent snapshot. These checks are not an adversarial snapshot
or source-authentication guarantee.

Reviewed sources:
https://github.com/ggml-org/llama.cpp/blob/c96ffc869/src/llama-model.cpp
https://github.com/ggml-org/llama.cpp/blob/c96ffc869/src/llama-context.cpp
https://github.com/ggml-org/llama.cpp/blob/c96ffc869/src/llama-kv-cache.cpp
https://github.com/ggml-org/llama.cpp/blob/c96ffc869/ggml/src/ggml-common.h

Source freshness checks, benchmark evidence validation and held-out calibration
are still separate work. Synthetic parser tests do not prove zero false-fit/OOM
or <=20% decode error on hardware. Automatic selection remains disabled.
