#!/usr/bin/env python3
"""Teale perf-gate bench: same-machine before/after for release gating.

Run against a node's LOCAL API (default http://127.0.0.1:11435/v1) on the
canary machine before and after the candidate build installs. Exercises the
mechanisms in the pending perf batch and prints a JSON summary to compare:

  - multi-turn prefix retention (#154/#178): follow-up TTFT must stay flat
    as conversation context grows
  - tool-call boundary retention (#196): TTFT of the turn AFTER a tool call
    must match ordinary follow-up TTFT (pre-#196 it re-prefills: large)
  - decode throughput sanity

Usage: python3 bench.py [--base-url http://127.0.0.1:11435/v1]
                        [--model qwen/qwen3.6-35b-a3b] [--turns 12]
                        [--api-key sk-...]  # only if the node requires auth
Stdlib only. Exit 0 always - this is a measurement tool, not a gate itself.
"""
import json, sys, time, urllib.request, urllib.error

BASE = "http://127.0.0.1:11435/v1"
MODEL = "qwen/qwen3.6-35b-a3b"
TURNS = 12
KEY = ""

def sse_chat(messages, tools=None, max_tokens=48):
    body = {"model": MODEL, "messages": messages, "stream": True,
            "max_tokens": max_tokens}
    if tools:
        body["tools"] = tools
        body["tool_choice"] = "auto"
    req = urllib.request.Request(BASE + "/chat/completions",
        data=json.dumps(body).encode(),
        headers={"Content-Type": "application/json"} |
                ({"Authorization": "Bearer " + KEY} if KEY else {}))
    t0 = time.time()
    try:
        resp = urllib.request.urlopen(req, timeout=300)
    except urllib.error.HTTPError as e:
        return {"error": "HTTP %s: %s" % (e.code, e.read()[:200])}
    ttfb = None; chunks = 0; text = ""; tool_calls = []; finish = None
    for raw in resp:
        now = time.time()
        line = raw.decode("utf-8", "replace").strip()
        if not line.startswith("data: "):
            continue
        payload = line[6:]
        if payload == "[DONE]":
            break
        chunks += 1
        try:
            chunk = json.loads(payload)
        except json.JSONDecodeError:
            continue
        choice = (chunk.get("choices") or [{}])[0]
        delta = choice.get("delta") or {}
        if delta.get("content") or delta.get("tool_calls"):
            if ttfb is None:
                ttfb = now - t0
        if delta.get("content"):
            text += delta["content"]
        for tc in delta.get("tool_calls") or []:
            fn = tc.get("function") or {}
            if fn.get("name"):
                tool_calls.append({"id": tc.get("id") or ("call_%d" % len(tool_calls)),
                                   "type": "function",
                                   "function": {"name": fn["name"],
                                                "arguments": fn.get("arguments") or ""}})
            elif tool_calls:
                tool_calls[-1]["function"]["arguments"] += fn.get("arguments") or ""
        if choice.get("finish_reason"):
            finish = choice["finish_reason"]
    total = time.time() - t0
    return {"ttfb": ttfb, "total": total, "chunks": chunks, "text": text,
            "tool_calls": tool_calls, "finish": finish}

TOOLS = [{"type": "function", "function": {
    "name": "get_weather",
    "description": "Get current weather for a city",
    "parameters": {"type": "object",
                   "properties": {"city": {"type": "string"}},
                   "required": ["city"]}}}]

def main():
    global BASE, MODEL, TURNS, KEY
    args = sys.argv[1:]
    for i, a in enumerate(args):
        if a == "--base-url": BASE = args[i + 1]
        if a == "--model": MODEL = args[i + 1]
        if a == "--turns": TURNS = int(args[i + 1])
        if a == "--api-key": KEY = args[i + 1]

    # Phase 1: warm the process (first-touch costs are not the gate signal)
    print("warmup...", file=sys.stderr)
    sse_chat([{"role": "user", "content": "Say hi."}], max_tokens=8)

    # Phase 2: multi-turn prefix retention - growing context, flat TTFT expected
    msgs = [{"role": "system", "content": "You are a concise assistant."}]
    multiturn = []
    for t in range(TURNS):
        msgs.append({"role": "user", "content": "Tell me one fact about the number %d." % (t + 1)})
        r = sse_chat(msgs)
        multiturn.append({"turn": t + 1, "ttfb": r.get("ttfb"),
                          "total": r.get("total"), "chunks": r.get("chunks"),
                          "error": r.get("error")})
        msgs.append({"role": "assistant", "content": r.get("text") or ""})
        print("multiturn t%d ttfb=%.3f" % (t + 1, r.get("ttfb") or -1), file=sys.stderr)

    # Phase 3: tool-call boundary - TTFT of the turn right after a tool call
    tmsgs = [{"role": "system", "content": "Use tools when asked."},
             {"role": "user", "content": "Use the get_weather tool for Tokyo."}]
    t1 = sse_chat(tmsgs, tools=TOOLS)
    post_tool = None
    if t1.get("tool_calls"):
        call = t1["tool_calls"][0]
        tmsgs.append({"role": "assistant", "content": None, "tool_calls": t1["tool_calls"]})
        tmsgs.append({"role": "tool", "tool_call_id": call["id"],
                      "content": json.dumps({"city": "Tokyo", "temp_c": 22})})
        t2 = sse_chat(tmsgs, tools=TOOLS)
        tmsgs.append({"role": "assistant", "content": t2.get("text") or ""})
        tmsgs.append({"role": "user", "content": "And what about Osaka? Use the tool."})
        t3 = sse_chat(tmsgs, tools=TOOLS)
        post_tool = {"after_tool_answer_ttfb": t2.get("ttfb"),
                     "next_tool_call_ttfb": t3.get("ttfb"),
                     "next_tool_call_got_call": bool(t3.get("tool_calls"))}
        print("post-tool ttfb=%.3f / next-call ttfb=%.3f" %
              (t2.get("ttfb") or -1, t3.get("ttfb") or -1), file=sys.stderr)

    summary = {"base": BASE, "model": MODEL,
               "multiturn": multiturn, "tool_boundary": post_tool}
    print(json.dumps(summary, indent=2))

if __name__ == "__main__":
    main()
