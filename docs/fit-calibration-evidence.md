# Offline supplied calibration dataset checks

```sh
teale models validate-evidence --manifest /local/campaign/manifest.json \
  --max-age-seconds 86400
```

No benchmark is started. This command reads bounded local JSON evidence and
reports dataset consistency and finite held-out gates. It does not verify
measurement authorship, execute backends, load/download models, access the
network, change selection or spend anything. Missing raw evidence cannot be
replaced by synthetic test outputs.

## Manifest

All fields are required except prediction decode rate, which can be null.
Raw runs are single relative filenames alongside the manifest, never absolute,
nested, symlinked or traversal paths. SHA-256 uses 64 lowercase hex characters.
Each file and manifest is limited to 8 MiB, campaign to 10,000 held-out cases.

```json
{
  "version": 1,
  "predictorSha256": "<digest of immutable predictor/cost configuration>",
  "trainingRunIds": ["train-1"],
  "heldOut": [{
    "file": "held-1.json",
    "sha256": "<digest of raw file bytes>",
    "prediction": {
      "runId": "held-1",
      "identity": {
        "deviceId": "lab-a",
        "backendBinarySha256": "<digest>",
        "artifactSha256": "<digest>",
        "backendRevision": "pinned revision",
        "configurationSha256": "<digest of all runtime settings, OS, codec, method, batch and placement>",
        "contextTokens": 4096,
        "concurrency": 1
      },
      "predictedAtUnix": 1000,
      "predictorSha256": "<same predictor digest>",
      "modeledFit": true,
      "predictedDecodeTps": 50.0
    }
  }]
}
```

Raw run:

```json
{
  "version": 1,
  "runId": "held-1",
  "identity": "<same full identity object as prediction, not a string>",
  "collectedAtUnix": 1100,
  "fitOutcome": "loaded",
  "observedPeakBytes": 8000,
  "capacityBytes": 10000,
  "decodeTokens": 100,
  "decodeSeconds": 2.0,
  "cancelled": false,
  "toolEvalPassed": true
}
```

`fitOutcome` is `loaded`, `oom`, or `allocation_failed`. A successful load needs
observed peak bytes no higher than capacity in the same limiting physical domain.
Failures can have null peak and decode fields. Do not deliberately cause an OOM
on a daily-use or production device to populate evidence; this reader does not
authorize any campaign. Every physical domain still needs separate collector
verification. `decodeTokens` and `decodeSeconds` exclude prefill; counters cover
exactly the workload identified by the prediction. Positive finite prediction,
nonzero tokens and positive finite seconds must be present together, or all
three decode fields must be null. Failed/cancelled/tool-failed runs cannot be
used as successful decode evidence.

## Validation and gates

- Reject raw-file digest mismatch, malformed/missing identity, unknown schema
  fields, duplicate held-out IDs, training/held-out overlap, predictor mismatch,
  posthoc/equal prediction timestamps, future timestamps and stale evidence.
- Both prediction and collection must be within explicitly supplied maximum age.
- Predictions must precede collection. Timestamp and training-ID assertions are
  not authenticated. Use trusted immutable collection and pre-registration.
- Relative error is `abs(predicted - observed) / observed`, where observed TPS
  is raw tokens / seconds. Report median absolute relative error, not signed bias.
- Any predicted fit followed by OOM/allocation failure is a false fit and fails.
- Initial finite proof rubric requires >=20 predicted-fit successful held-out
  loads, >=20 successful held-out decode cases, >=2 device identities, >=2
  contexts and >=2 concurrency settings. Missing coverage fails as incomplete.
- No cancelled or tool/eval-failed cases; median relative decode error <=20%.

The coverage floor is a proposed initial proof rubric, not a universal
statistical guarantee or a substitute for agreed hardware/model coverage.
A pass is named `supplied_dataset_pass`. It establishes only that the supplied
finite records clear these checks. It does **not** establish truthful measurements,
causal independence, source authenticity, universal zero-false-fit, a safe new
workload, or permission to select/route. Existing routing remains unchanged.
A digest binds bytes, not who wrote them. Raw peak and settings are collector
claims. No fleet calibration has been performed by this implementation.

This checks raw benchmark freshness, not all reported/published/model-cost
source freshness in `models assess`. That broader evidence producer and full
peak-memory extraction remain outstanding. Do not label stage 2 complete from
these mechanics alone.
