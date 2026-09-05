#!/usr/bin/env python3
"""Teale x goose pilot: 5-turn streaming tool-calling probe against the gateway.

Validates what goose needs from Teale's OpenAI-compatible endpoint:
  - streamed tool-call deltas: OK (incremental deltas) vs BLOCK (one burst)
  - TTFT / chunk inter-arrival shape per turn
  - silent tool loss (tools requested, none returned, no error)

Usage: TEALE_API_KEY=... python3 pilot.py [--base-url https://teale-gateway.fly.dev/v1]
                                          [--model qwen/qwen3.6-35b-a3b]
Stdlib only. Exit 0 = all turns passed (warnings allowed), 1 = failure.
"""
import json, os, sys, time, urllib.request, urllib.error

BASE = "https://teale-gateway.fly.dev/v1"
MODEL = "qwen/qwen3.6-35b-a3b"
KEY = os.environ.get("TEALE_API_KEY", "")
if not KEY:
    sys.exit("TEALE_API_KEY not set")

TOOLS = [{
    "type": "function",
    "function": {
        "name": "get_weather",
        "description": "Get current weather for a city",
        "parameters": {"type": "object",
                       "properties": {"city": {"type": "string"}},
                       "required": ["city"]},
    },
}, {
    "type": "function",
    "function": {
        "name": "add_numbers",
        "description": "Add two numbers",
        "parameters": {"type": "object",
                       "properties": {"a": {"type": "number"}, "b": {"type": "number"}},
                       "required": ["a", "b"]},
    },
}]

def run_tool(name, args):
    if name == "get_weather":
        return {"city": args.get("city"), "temp_c": 22, "condition": "clear"}
    if name == "add_numbers":
        return {"sum": args.get("a", 0) + args.get("b", 0)}
    return {"error": "unknown tool"}

class TurnResult:
    def __init__(self, name):
        self.name = name
        self.ttfb = None
        self.total = None
        self.chunks = 0
        self.max_gap = 0.0
        self.tool_delta_chunks = 0   # streamed tool-call delta chunks seen
        self.tool_calls = []         # assembled calls
        self.text = ""
        self.finish = None
        self.tool_loss = False
        self.lane_header = None
        self.error = None

def sse_turn(name, messages, stream=True, tools=None):
    r = TurnResult(name)
    body = {"model": MODEL, "messages": messages, "stream": stream}
    if tools:
        body["tools"] = tools
        body["tool_choice"] = "auto"
    req = urllib.request.Request(BASE + "/chat/completions",
        data=json.dumps(body).encode(),
        headers={"Authorization": "Bearer " + KEY, "Content-Type": "application/json"})
    t0 = time.time()
    try:
        resp = urllib.request.urlopen(req, timeout=180)
    except urllib.error.HTTPError as e:
        r.error = "HTTP %s: %s" % (e.code, e.read()[:300])
        return r
    r.lane_header = resp.headers.get("tools-lane-exhausted")

    if not stream:
        data = json.loads(resp.read())
        r.total = time.time() - t0
        r.ttfb = r.total
        msg = data.get("choices", [{}])[0].get("message", {})
        r.text = msg.get("content") or ""
        r.tool_calls = msg.get("tool_calls") or []
        r.finish = data.get("choices", [{}])[0].get("finish_reason")
        return r

    # streaming: accumulate tool-call deltas; detect BLOCK vs incremental
    assembled = {}
    last = t0
    for raw in resp:
        now = time.time()
        if r.ttfb is None:
            r.ttfb = now - t0
        gap = now - last
        r.max_gap = max(r.max_gap, gap)
        last = now
        line = raw.decode("utf-8", "replace").strip()
        if not line.startswith("data: "):
            continue
        payload = line[6:]
        if payload == "[DONE]":
            break
        r.chunks += 1
        try:
            chunk = json.loads(payload)
        except json.JSONDecodeError:
            continue
        choice = (chunk.get("choices") or [{}])[0]
        delta = choice.get("delta") or {}
        if delta.get("content"):
            r.text += delta["content"]
        for tc in delta.get("tool_calls") or []:
            r.tool_delta_chunks += 1
            i = tc.get("index", 0)
            slot = assembled.setdefault(i, {"id": "", "type": "function",
                "function": {"name": "", "arguments": ""}})
            if tc.get("id"):
                slot["id"] = tc["id"]
            fn = tc.get("function") or {}
            if fn.get("name"):
                slot["function"]["name"] += fn["name"]
            if fn.get("arguments"):
                slot["function"]["arguments"] += fn["arguments"]
        if choice.get("finish_reason"):
            r.finish = choice["finish_reason"]
    r.total = time.time() - t0
    r.tool_calls = list(assembled.values())
    return r

def report(r, expect_tool):
    status = "OK"
    if r.error:
        status = "FAIL"
    elif expect_tool and not r.tool_calls:
        r.tool_loss = True
        status = "FAIL(tool-loss)"
    shape = ""
    if r.tool_calls:
        args_len = sum(len(t["function"]["arguments"]) for t in r.tool_calls)
        if r.tool_delta_chunks > len(r.tool_calls):
            shape = "deltas=%d (incremental)" % r.tool_delta_chunks
        else:
            shape = "deltas=%d (block-style)" % r.tool_delta_chunks
        shape += " args_bytes=%d" % args_len
    print("[%s] %-22s ttfb=%.2fs total=%.2fs chunks=%d max_gap=%.2fs finish=%s %s %s" % (
        status, r.name, r.ttfb or -1, r.total or -1, r.chunks, r.max_gap,
        r.finish, shape, ("lane_exhausted=" + r.lane_header) if r.lane_header else ""))
    if r.text:
        snippet = r.text.replace("\n", " ")[:220]
        print("    text: %s%s" % (snippet, "..." if len(r.text) > 220 else ""))
    if r.error:
        print("    error:", r.error)
    return status == "OK"

def main():
    for arg in sys.argv[1:]:
        global BASE, MODEL
        if arg == "--base-url":
            BASE = sys.argv[sys.argv.index(arg) + 1]
        if arg == "--model":
            MODEL = sys.argv[sys.argv.index(arg) + 1]
    ok = True
    msgs = [{"role": "system", "content": "You are a concise assistant. Use tools when asked."}]

    # Turn 1: expect a get_weather tool call (streaming)
    msgs.append({"role": "user", "content": "What's the weather in Tokyo right now?"})
    t1 = sse_turn("t1-tool-call", msgs, stream=True, tools=TOOLS)
    ok &= report(t1, expect_tool=True)

    # Turn 2: tool result -> streamed text answer
    if t1.tool_calls:
        call = t1.tool_calls[0]
        msgs.append({"role": "assistant", "content": None, "tool_calls": t1.tool_calls})
        try:
            args = json.loads(call["function"]["arguments"] or "{}")
        except json.JSONDecodeError:
            args = {}
        msgs.append({"role": "tool", "tool_call_id": call["id"],
                     "content": json.dumps(run_tool(call["function"]["name"], args))})
        t2 = sse_turn("t2-tool-answer", msgs, stream=True, tools=TOOLS)
        ok &= report(t2, expect_tool=False)
        msgs.append({"role": "assistant", "content": t2.text or ""})
    else:
        print("[SKIP] t2-tool-answer (no t1 call)")

    # Turn 3: second tool call type (streamed). Retry on tool loss to gauge
    # determinism, then a non-streaming control of the same messages: if the
    # control also loses the call, the loss is upstream of SSE (template /
    # model / parser); if the control works, suspect the streaming path.
    msgs.append({"role": "user", "content": "Add 37 and 5."})
    t3 = sse_turn("t3-tool-call-2", msgs, stream=True, tools=TOOLS)
    ok &= report(t3, expect_tool=True)
    if t3.tool_loss:
        for attempt in (2, 3):
            t3r = sse_turn("t3-retry-%d" % attempt, msgs, stream=True, tools=TOOLS)
            report(t3r, expect_tool=True)
        t3c = sse_turn("t3-nonstream-ctl", msgs, stream=False, tools=TOOLS)
        report(t3c, expect_tool=True)

    # Turn 4: result -> final streamed text
    if t3.tool_calls:
        call = t3.tool_calls[0]
        msgs.append({"role": "assistant", "content": None, "tool_calls": t3.tool_calls})
        try:
            args = json.loads(call["function"]["arguments"] or "{}")
        except json.JSONDecodeError:
            args = {}
        msgs.append({"role": "tool", "tool_call_id": call["id"],
                     "content": json.dumps(run_tool(call["function"]["name"], args))})
        t4 = sse_turn("t4-final-answer", msgs, stream=True, tools=TOOLS)
        ok &= report(t4, expect_tool=False)
    else:
        print("[SKIP] t4-final-answer (no t3 call)")

    # Turn 5: non-streaming control with tools
    t5 = sse_turn("t5-nonstream-tool", [{"role": "user", "content": "What's the weather in Houston?"}],
                  stream=False, tools=TOOLS)
    ok &= report(t5, expect_tool=True)

    print("\n=== VERDICTS ===")
    print("streamed tool deltas:", "incremental" if t1.tool_delta_chunks > 1 else "block-style", "(t1 chunks=%d)" % t1.tool_delta_chunks)
    print("silent tool loss:", "YES" if (t1.tool_loss or t3.tool_loss or t5.tool_loss) else "no")
    print("non-streaming tool calls:", "OK" if t5.tool_calls else "BROKEN")
    sys.exit(0 if ok else 1)

if __name__ == "__main__":
    main()
