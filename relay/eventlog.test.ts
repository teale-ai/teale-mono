import { beforeEach, describe, expect, test } from "bun:test";
import { mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

// RELAY_LOG_DIR is read at module load, so each test group gets a fresh
// temp dir + a fresh dynamic import of the module.
let dir: string;
let ev: typeof import("./eventlog.ts");

beforeEach(async () => {
  dir = mkdtempSync(join(tmpdir(), "relay-eventlog-"));
  process.env.RELAY_LOG_DIR = dir;
  ev = await import(`./eventlog.ts?${Date.now()}-${Math.random()}`);
});

describe("eventlog", () => {
  test("persists events to JSONL and serves them via queryEvents", () => {
    ev.logEvent("register", { node: "a".repeat(64), displayName: "n", replaced: false, refresh: false });
    ev.logEvent("close", { node: "a".repeat(64), outcome: "removed" });

    const file = readFileSync(join(dir, "events.jsonl"), "utf8").trim().split("\n");
    expect(file.length).toBe(2);
    expect(JSON.parse(file[0]).kind).toBe("register");
    expect(JSON.parse(file[0]).node).toBe("a".repeat(64)); // full ID on disk

    const out = ev.queryEvents(new URLSearchParams());
    expect(out.length).toBe(2);
    expect(out[0].node).toBe("a".repeat(16) + "..."); // truncated via endpoint
  });

  test("fields can never clobber the event kind", () => {
    ev.logEvent("peer_not_found", { from: "x", to: "y", msg_kind: "relayOpen" });
    const out = ev.queryEvents(new URLSearchParams());
    expect(out[0].kind).toBe("peer_not_found");
    expect(out[0].msg_kind).toBe("relayOpen");
  });

  test("filters by kind, node prefix, and since", () => {
    ev.logEvent("register", { node: "a".repeat(64) });
    ev.logEvent("close", { node: "b".repeat(64) });
    expect(ev.queryEvents(new URLSearchParams("kind=close")).length).toBe(1);
    expect(ev.queryEvents(new URLSearchParams(`node=${"a".repeat(16)}`)).length).toBe(1);
    expect(ev.queryEvents(new URLSearchParams("since=2999-01-01T00:00:00Z")).length).toBe(0);
  });

  test("loadHistory replays prior file contents across restarts", () => {
    ev.logEvent("register", { node: "a".repeat(64) });
    // simulate a process restart: fresh module instance, same dir
    return (async () => {
      const ev2: typeof import("./eventlog.ts") = await import(`./eventlog.ts?restart-${Date.now()}`);
      const replayed = ev2.loadHistory();
      expect(replayed).toBe(1);
      const out = ev2.queryEvents(new URLSearchParams());
      expect(out.some((e) => e.kind === "register")).toBe(true);
    })();
  });
});
