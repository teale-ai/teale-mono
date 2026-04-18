#!/usr/bin/env python3
"""
Post-processing for teale-stress runs.
Reads runs/<run_id>/records.jsonl and produces per-model tables + histograms.

Usage:
    python3 stress/analyze.py runs/steady_state_abc123
"""

import json
import sys
from collections import defaultdict
from pathlib import Path
from statistics import mean, median


def percentile(values, p):
    if not values:
        return 0
    ordered = sorted(values)
    k = (len(ordered) - 1) * p
    f = int(k)
    c = min(f + 1, len(ordered) - 1)
    if f == c:
        return ordered[f]
    return ordered[f] + (ordered[c] - ordered[f]) * (k - f)


def main(run_dir: str):
    run = Path(run_dir)
    records_path = run / "records.jsonl"
    if not records_path.exists():
        print(f"no records at {records_path}")
        sys.exit(1)

    by_model_status = defaultdict(lambda: {"count": 0, "ttft": [], "latency": [], "errors": defaultdict(int)})
    total = 0
    ok = 0
    errors = 0

    with records_path.open() as f:
        for line in f:
            rec = json.loads(line)
            total += 1
            if rec["status"] == "ok":
                ok += 1
            else:
                errors += 1
            key = (rec["model"], rec["status"])
            slot = by_model_status[key]
            slot["count"] += 1
            if rec.get("ttft_ms") is not None:
                slot["ttft"].append(rec["ttft_ms"])
            slot["latency"].append(rec["total_ms"])
            if rec.get("error"):
                slot["errors"][rec["error"][:80]] += 1

    print(f"\n=== {run.name} ===")
    print(f"total={total} ok={ok} errors={errors} success_rate={ok/total:.4f}" if total else "no requests recorded")
    print()
    print(f"{'model':<48} {'status':<15} {'count':>6} {'p50':>7} {'p95':>7} {'p99':>7}")
    print("-" * 100)
    for (model, status), slot in sorted(by_model_status.items()):
        p50 = percentile(slot["latency"], 0.50)
        p95 = percentile(slot["latency"], 0.95)
        p99 = percentile(slot["latency"], 0.99)
        print(f"{model:<48} {status:<15} {slot['count']:>6} {p50:>7.0f} {p95:>7.0f} {p99:>7.0f}")

    print()
    print("=== TTFT (streaming only) ===")
    print(f"{'model':<48} {'count':>6} {'p50':>7} {'p95':>7} {'p99':>7}")
    print("-" * 80)
    ttft_by_model = defaultdict(list)
    for (model, status), slot in by_model_status.items():
        if status == "ok":
            ttft_by_model[model].extend(slot["ttft"])
    for model, samples in sorted(ttft_by_model.items()):
        if samples:
            print(f"{model:<48} {len(samples):>6} "
                  f"{percentile(samples, 0.5):>7.0f} "
                  f"{percentile(samples, 0.95):>7.0f} "
                  f"{percentile(samples, 0.99):>7.0f}")

    # Error breakdown
    err_counts = defaultdict(int)
    for (_, status), slot in by_model_status.items():
        if status != "ok":
            for msg, n in slot["errors"].items():
                err_counts[msg] += n
    if err_counts:
        print("\n=== Top error messages ===")
        for msg, n in sorted(err_counts.items(), key=lambda x: -x[1])[:10]:
            print(f"{n:>6}  {msg}")


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("usage: analyze.py <run_dir>")
        sys.exit(1)
    main(sys.argv[1])
