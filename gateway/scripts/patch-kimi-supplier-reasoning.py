#!/usr/bin/env python3
"""Patch mlx-openai-proxy.py on the local host so SSE deltas with
`reasoning` get folded into `content`. Kimi K2.6 always emits
chain-of-thought tokens in `delta.reasoning` regardless of
`enable_thinking`; without this fold, OpenAI clients see zero content
and small max_tokens requests `finish_reason: length` empty.

After patching, the upstream chunk pipe in do_POST is wrapped to:
  - parse each `data: {...}` SSE line
  - if `choices[*].delta.reasoning` is set and `delta.content` is empty,
    move the reasoning text to content
  - serialize and forward
"""
import os, pathlib, subprocess, sys

candidates = [
    pathlib.Path("/Users/tailor512/teale-kimi-q8/mlx-openai-proxy.py"),
    pathlib.Path("/Users/tailor512g1/teale-kimi-q8/mlx-openai-proxy.py"),
]
target = next((p for p in candidates if p.exists()), None)
if target is None:
    sys.exit("could not find mlx-openai-proxy.py")

s = target.read_text()

# Idempotent: already patched.
if "_fold_reasoning_into_content" in s:
    print(f"[{target}] already patched")
else:
    helper = '''
def _fold_reasoning_into_content(line: bytes) -> bytes:
    """Rewrite an SSE `data: {json}` line so `delta.reasoning` text moves
    into `delta.content`. Lines that aren't SSE data, aren't JSON, or have
    no reasoning are returned unchanged."""
    if not line.startswith(b"data: "):
        return line
    payload = line[len(b"data: "):].strip()
    if not payload or payload == b"[DONE]":
        return line
    try:
        obj = json.loads(payload)
    except Exception:
        return line
    choices = obj.get("choices") if isinstance(obj, dict) else None
    if not isinstance(choices, list):
        return line
    changed = False
    for choice in choices:
        if not isinstance(choice, dict):
            continue
        delta = choice.get("delta")
        if not isinstance(delta, dict):
            continue
        reasoning = delta.get("reasoning")
        if not isinstance(reasoning, str) or reasoning == "":
            continue
        existing = delta.get("content") or ""
        delta["content"] = existing + reasoning
        delta.pop("reasoning", None)
        changed = True
    if not changed:
        return line
    return b"data: " + json.dumps(obj).encode("utf-8") + b"\\n"


def _stream_fold_reasoning(upstream):
    """Yield upstream SSE chunks with `delta.reasoning` folded into
    `delta.content`. Splits on \\n boundaries so we never split a JSON
    payload across chunks."""
    buf = b""
    for chunk in upstream.iter_content(chunk_size=8192):
        if not chunk:
            continue
        buf += chunk
        while b"\\n" in buf:
            line, buf = buf.split(b"\\n", 1)
            yield _fold_reasoning_into_content(line) + b"\\n"
    if buf:
        yield _fold_reasoning_into_content(buf)
'''
    # Insert helpers right before `class ProxyHandler`.
    marker = "class ProxyHandler(BaseHTTPRequestHandler):"
    if marker not in s:
        sys.exit("failed to locate ProxyHandler class")
    s = s.replace(marker, helper + "\n" + marker)

    # Swap the streaming pass-through to use the folder.
    old_stream = """        if "text/event-stream" in content_type:
            for chunk in upstream.iter_content(chunk_size=8192):
                if not chunk:
                    continue
                self.wfile.write(chunk)
                self.wfile.flush()
            return"""
    new_stream = """        if "text/event-stream" in content_type:
            for chunk in _stream_fold_reasoning(upstream):
                if not chunk:
                    continue
                self.wfile.write(chunk)
                self.wfile.flush()
            return"""
    if old_stream not in s:
        sys.exit("failed to locate streaming pass-through block to patch")
    s = s.replace(old_stream, new_stream)

    # Also fold in the non-streaming JSON return (full body).
    old_buffered = """        for chunk in upstream.iter_content(chunk_size=8192):
            if not chunk:
                continue
            self.wfile.write(chunk)
        self.wfile.flush()"""
    new_buffered = """        full = b"".join(c for c in upstream.iter_content(chunk_size=8192) if c)
        try:
            obj = json.loads(full.decode("utf-8"))
            for choice in obj.get("choices", []) if isinstance(obj, dict) else []:
                msg = choice.get("message") if isinstance(choice, dict) else None
                if not isinstance(msg, dict):
                    continue
                reasoning = msg.get("reasoning")
                if isinstance(reasoning, str) and reasoning:
                    msg["content"] = (msg.get("content") or "") + reasoning
                    msg.pop("reasoning", None)
            full = json.dumps(obj).encode("utf-8")
        except Exception:
            pass
        self.wfile.write(full)
        self.wfile.flush()"""
    if old_buffered not in s:
        sys.exit("failed to locate buffered pass-through block to patch")
    s = s.replace(old_buffered, new_buffered)

    target.write_text(s)
    print(f"[{target}] patched")

# Restart the proxy LaunchAgent (the proxy is the second leg of the
# kimi-k26-mlx-server agent — kickstarting that re-execs run-mlx-server.sh
# which re-execs the proxy).
uid = os.getuid()
r = subprocess.run(
    ["launchctl", "kickstart", "-k", f"gui/{uid}/com.teale.kimi-k26-mlx-server"],
    capture_output=True, text=True,
)
print(f"kickstart rc={r.returncode}", r.stderr.strip() or "OK")
