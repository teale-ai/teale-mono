#!/usr/bin/env python3
"""Observe an already started, approved local llama-server. Never starts/stops it.
Preserves server generation counters; missing data remains missing. No fit claim.
"""
import argparse
import concurrent.futures
import hashlib
import ipaddress
import json
import math
import os
from pathlib import Path
import time
import urllib.parse
import urllib.request

MAX_REPLY = 4 * 1024 * 1024


def local_url(value):
    parsed = urllib.parse.urlsplit(value)
    if parsed.scheme != "http" or parsed.username or parsed.password or parsed.query or parsed.fragment:
        raise ValueError("only unauthenticated HTTP loopback endpoints are allowed")
    if parsed.path not in ("", "/") or not parsed.port:
        raise ValueError("supply a loopback origin with explicit port, no path")
    try:
        address = ipaddress.ip_address(parsed.hostname)
    except ValueError as exc:
        raise ValueError("use literal 127.0.0.1 or ::1; no DNS") from exc
    if not address.is_loopback:
        raise ValueError("non-loopback endpoint refused")
    return value.rstrip("/")


def digest(path):
    path = Path(path)
    if path.is_symlink() or not path.is_file():
        raise ValueError("identity files must be regular nonsymlink files")
    before = path.stat()
    h = hashlib.sha256()
    with path.open("rb") as f:
        while chunk := f.read(1024 * 1024):
            h.update(chunk)
    after = path.stat()
    if (before.st_size, before.st_mtime_ns, before.st_ino) != (after.st_size, after.st_mtime_ns, after.st_ino):
        raise ValueError("identity file changed during hashing")
    return h.hexdigest()


def extract_timings(response):
    t = response.get("timings", {})
    tokens, milliseconds = t.get("predicted_n"), t.get("predicted_ms")
    if isinstance(tokens, bool) or not isinstance(tokens, int) or tokens <= 0:
        return None
    if isinstance(milliseconds, bool) or not isinstance(milliseconds, (float, int)):
        return None
    if not math.isfinite(milliseconds) or milliseconds <= 0:
        return None
    return {"decodeTokens": tokens, "decodeSeconds": milliseconds / 1000,
            "serverReportedDecodeTps": tokens * 1000 / milliseconds}


def request(origin, prompt, timeout, slot):
    payload = {"prompt": prompt, "n_predict": 128, "temperature": 0,
               "seed": 42, "cache_prompt": False, "stream": False}
    body = json.dumps(payload).encode()
    req = urllib.request.Request(origin + "/completion", data=body,
                                 headers={"Content-Type": "application/json"})
    # No proxy can redirect a loopback observation through a third party.
    class NoRedirect(urllib.request.HTTPRedirectHandler):
        def redirect_request(self, *args, **kwargs):
            return None
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect())
    started = time.monotonic()
    with opener.open(req, timeout=timeout) as reply:
        data = reply.read(MAX_REPLY + 1)
        if len(data) > MAX_REPLY:
            raise ValueError("response exceeds 4 MiB")
    response = json.loads(data)
    if not isinstance(response, dict):
        raise ValueError("unexpected response object")
    content = response.get("content")
    if not isinstance(content, str) or not content.strip():
        raise ValueError("empty/missing generated content")
    if response.get("truncated"):
        raise ValueError("context truncation invalidates workload")
    timing = extract_timings(response)
    return {"slot": slot, "elapsedSecondsIncludingPrefill": time.monotonic() - started,
            "generationCounters": timing, "response": response,
            "missingCounters": timing is None}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--origin", required=True, type=local_url)
    parser.add_argument("--identity", required=True, type=Path)
    parser.add_argument("--model-file", required=True, type=Path)
    parser.add_argument("--binary-file", required=True, type=Path)
    parser.add_argument("--prompt-file", required=True, type=Path)
    parser.add_argument("--out", required=True, type=Path)
    parser.add_argument("--concurrency", required=True, type=int, choices=(1, 2))
    parser.add_argument("--timeout", type=int, default=90, choices=range(1, 91))
    args = parser.parse_args()
    if args.identity.stat().st_size > 65536 or args.prompt_file.stat().st_size > 65536:
        parser.error("identity/prompt exceeds 64 KiB")
    identity = json.loads(args.identity.read_text())
    required = {"deviceId", "backendBinarySha256", "artifactSha256", "backendRevision",
                "configurationSha256", "contextTokens", "concurrency"}
    if set(identity) != required or identity["concurrency"] != args.concurrency:
        parser.error("exact identity fields and matching concurrency required")
    if digest(args.model_file) != identity["artifactSha256"] or digest(args.binary_file) != identity["backendBinarySha256"]:
        parser.error("model/binary bytes differ from identity")
    if args.out.exists():
        parser.error("output exists; never overwrite prior evidence")
    prompt = args.prompt_file.read_text()
    started = int(time.time())
    with concurrent.futures.ThreadPoolExecutor(max_workers=args.concurrency) as pool:
        futures = [pool.submit(request, args.origin, prompt, args.timeout, n)
                   for n in range(args.concurrency)]
        observations = [f.result() for f in futures]
    # This is intentionally NOT RawRun: no authenticated peak, capacity, or eval.
    result = {"version": 1, "kind": "decode_observation_not_fit_evidence",
              "identity": identity, "startedAtUnix": started, "collectedAtUnix": int(time.time()),
              "promptSha256": hashlib.sha256(prompt.encode()).hexdigest(),
              "observations": observations, "verdict": "not_calibrated",
              "caveats": ["Backend identity/flags require independent fleet verification.",
                          "No Metal-inclusive peak or usable-capacity measurement; no fit claim.",
                          "No tool/cancellation evaluation; not a validate-evidence RawRun.",
                          "Per-response server generation counters are not concurrent wall-throughput."]}
    fd = os.open(args.out, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
    with os.fdopen(fd, "w") as f:
        json.dump(result, f, indent=2)
        f.write("\n")


if __name__ == "__main__":
    main()
