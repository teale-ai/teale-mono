// Durable structured event log for post-hoc forensics.
//
// Fly's log retention for this app is effectively a ~1 minute ring buffer, so
// console.log alone cannot answer "what happened to node X at 09:04" after the
// fact (#221). This module appends low-volume control-plane events (registers,
// closes, errors, drops, periodic stats) to a JSONL file on the machine rootfs.
// The rootfs survives process restarts - the exact failure mode that motivated
// this - and is only reset on machine replacement or a new image deploy.
//
// Query paths:
//   live process:  GET /events?since=&kind=&node=&limit=   (node IDs truncated)
//   post-restart:  flyctl ssh console -a teale-relay -C 'cat /app/logs/events.jsonl'
// On boot the tail of the file is replayed into memory so /events serves
// seamless history across restarts.

import { appendFileSync, existsSync, mkdirSync, readFileSync, renameSync, statSync } from "node:fs";
import { join } from "node:path";

type JSONValue =
  | string
  | number
  | boolean
  | null
  | JSONValue[]
  | { [key: string]: JSONValue };

export type RelayEvent = { ts: string; kind: string } & Record<string, JSONValue>;

const LOG_DIR = Bun.env.RELAY_LOG_DIR ?? "/app/logs";
const LOG_FILE = join(LOG_DIR, "events.jsonl");
const ROTATED_FILE = LOG_FILE + ".1";
const MAX_FILE_BYTES = 4 * 1024 * 1024; // rotate at 4MB, keep one generation
const RING_CAPACITY = 5000;
const REPLAY_LINES = 5000;

const ring: RelayEvent[] = [];
let writesFailed = 0;

function rotateIfNeeded() {
  try {
    if (statSync(LOG_FILE).size >= MAX_FILE_BYTES) {
      renameSync(LOG_FILE, ROTATED_FILE);
    }
  } catch {
    // missing file is the common case - nothing to rotate
  }
}

export function logEvent(kind: string, fields: Record<string, JSONValue> = {}) {
  // kind last so a fields key can never clobber the event kind
  const event: RelayEvent = { ts: new Date().toISOString(), ...fields, kind };
  ring.push(event);
  if (ring.length > RING_CAPACITY) {
    ring.splice(0, ring.length - RING_CAPACITY);
  }
  try {
    mkdirSync(LOG_DIR, { recursive: true });
    rotateIfNeeded();
    appendFileSync(LOG_FILE, JSON.stringify(event) + "\n");
  } catch (e) {
    // Never let logging take the relay down.
    if (writesFailed++ % 100 === 0) {
      console.log(`[eventlog] write failed: ${e}`);
    }
  }
}

// Replay the tail of the on-disk log (previous generation + current) so the
// /events endpoint has history from before a process restart.
export function loadHistory(): number {
  let loaded = 0;
  for (const file of [ROTATED_FILE, LOG_FILE]) {
    try {
      if (!existsSync(file)) continue;
      const lines = readFileSync(file, "utf8").split("\n");
      for (const line of lines) {
        if (!line) continue;
        try {
          ring.push(JSON.parse(line) as RelayEvent);
          loaded++;
        } catch {
          // skip corrupt lines
        }
      }
    } catch (e) {
      console.log(`[eventlog] replay of ${file} failed: ${e}`);
    }
  }
  if (ring.length > RING_CAPACITY) {
    ring.splice(0, ring.length - RING_CAPACITY);
  }
  ring.sort((a, b) => (a.ts < b.ts ? -1 : a.ts > b.ts ? 1 : 0));
  return loaded;
}

const NODE_ID_KEYS = new Set(["node", "from", "to"]);

function truncateNodeIDs(event: RelayEvent): RelayEvent {
  const out: RelayEvent = { ...event };
  for (const key of Object.keys(out)) {
    const value = out[key];
    if (NODE_ID_KEYS.has(key) && typeof value === "string" && value.length > 16) {
      out[key] = value.substring(0, 16) + "...";
    }
  }
  return out;
}

export function queryEvents(params: URLSearchParams): RelayEvent[] {
  const sinceParam = params.get("since");
  let sinceMs = 0;
  if (sinceParam) {
    const asNumber = Number(sinceParam);
    // epoch seconds or ISO-8601
    sinceMs = Number.isFinite(asNumber) && asNumber > 1_000_000_000
      ? asNumber * 1000
      : Date.parse(sinceParam) || 0;
  }
  const kind = params.get("kind");
  const node = params.get("node");
  const limit = Math.min(Math.max(Number(params.get("limit")) || 200, 1), 2000);

  const matches: RelayEvent[] = [];
  // Walk newest-first and collect, then re-sort ascending for the response.
  for (let i = ring.length - 1; i >= 0 && matches.length < limit; i--) {
    const event = ring[i];
    if (sinceMs && Date.parse(event.ts) < sinceMs) break;
    if (kind && event.kind !== kind) continue;
    if (node) {
      const eventNode = event.node ?? event.from ?? event.to;
      if (typeof eventNode !== "string" || !eventNode.startsWith(node.replace(/\.\.\.$/, ""))) continue;
    }
    matches.push(event);
  }
  matches.reverse();
  return matches.map(truncateNodeIDs);
}

export function eventLogStatus() {
  return {
    ring_size: ring.length,
    oldest: ring.length ? ring[0].ts : null,
    newest: ring.length ? ring[ring.length - 1].ts : null,
    writes_failed: writesFailed,
    file: LOG_FILE,
  };
}
