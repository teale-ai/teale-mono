# Perf gate bench

Same-machine before/after bench for the canary release gate.

## Protocol (per release with perf-affecting changes)

1. Pick the machine that exercises the change (MLX changes -> an MLX-backed
   machine; llama changes -> any llama supplier).
2. If no pinned baseline of the same engine exists, use same-machine
   before/after: run `bench.py` on the CURRENT build, update, run again.
   (Absolute-behavior validation - weaker than A/B, so say which you ran.)
3. Compare:
   - multiturn follow-up TTFT flat as context grows (prefix retention)
   - tool_boundary.next_tool_call_ttfb in the same range as multiturn
     follow-ups (#196 - pre-fix it re-prefills and is visibly larger)
   - decode chunks/total sane (no throughput collapse)
4. Promote fleet-wide only if no regression; keep the JSONs.

Loopback only: default base is the node's local API, no gateway in the path.
