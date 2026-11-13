import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

// eventlog.ts reads RELAY_LOG_DIR at module load: point it at a temp dir
// before importing the relay.
process.env.RELAY_LOG_DIR = mkdtempSync(join(tmpdir(), "relay-server-"));
const { startRelay } = await import("./server.ts");
const { verifyRegisterSignature, parseDiscover, peerMatchesFilter } = await import("./validate.ts");

type Relay = ReturnType<typeof startRelay>;
type Message = Record<string, any>;

function toHex(bytes: Uint8Array): string {
  return Array.from(bytes, (b) => b.toString(16).padStart(2, "0")).join("");
}

type Identity = { nodeID: string; sign: (text: string) => Promise<string> };

async function makeIdentity(): Promise<Identity> {
  const pair = (await crypto.subtle.generateKey({ name: "Ed25519" }, true, ["sign", "verify"])) as CryptoKeyPair;
  const raw = new Uint8Array(await crypto.subtle.exportKey("raw", pair.publicKey));
  return {
    nodeID: toHex(raw),
    sign: async (text: string) =>
      toHex(new Uint8Array(await crypto.subtle.sign({ name: "Ed25519" }, pair.privateKey, new TextEncoder().encode(text)))),
  };
}

function capabilities(models: string[], ramGB: number, tier: number) {
  return {
    hardware: { chipFamily: "m3Ultra", chipName: "test", totalRAMGB: ramGB, gpuCoreCount: 1, memoryBandwidthGBs: 1, tier },
    loadedModels: models,
    maxModelSizeGB: 1,
    isAvailable: true,
  };
}

class Client {
  private queue: Message[] = [];
  private waiters: (() => void)[] = [];
  closed = false;

  private constructor(private ws: WebSocket) {
    ws.onmessage = (event) => {
      this.queue.push(JSON.parse(String(event.data)));
      for (const w of this.waiters.splice(0)) w();
    };
    ws.onclose = () => {
      this.closed = true;
      for (const w of this.waiters.splice(0)) w();
    };
  }

  static connect(port: number): Promise<Client> {
    return new Promise((resolve, reject) => {
      const ws = new WebSocket(`ws://127.0.0.1:${port}/ws`);
      const client = new Client(ws);
      ws.onopen = () => resolve(client);
      ws.onerror = (e) => reject(e);
    });
  }

  send(message: unknown) {
    this.ws.send(typeof message === "string" ? message : JSON.stringify(message));
  }

  /** Resolve with the payload of the next message of `kind` (other kinds stay queued). */
  async next(kind: string, timeoutMs = 2000): Promise<any> {
    const deadline = Date.now() + timeoutMs;
    for (;;) {
      const index = this.queue.findIndex((m) => kind in m);
      if (index >= 0) return this.queue.splice(index, 1)[0]![kind];
      const remaining = deadline - Date.now();
      if (remaining <= 0) throw new Error(`timed out waiting for ${kind}`);
      await new Promise<void>((resolve) => {
        const timer = setTimeout(resolve, remaining);
        this.waiters.push(() => {
          clearTimeout(timer);
          resolve();
        });
      });
    }
  }

  /** True if no message of `kind` arrives within `ms`. */
  async none(kind: string, ms = 200): Promise<boolean> {
    try {
      await this.next(kind, ms);
      return false;
    } catch {
      return true;
    }
  }

  async register(identity: Identity, caps: object = capabilities([], 16, 2), displayName = "test") {
    this.send({
      register: {
        nodeID: identity.nodeID,
        publicKey: identity.nodeID,
        displayName,
        capabilities: caps,
        signature: await identity.sign(identity.nodeID),
      },
    });
    return this.next("registerAck");
  }

  close() {
    this.ws.close();
  }
}

describe("relay register signatures (enforced)", () => {
  let relay: Relay;
  const clients: Client[] = [];
  const connect = async () => {
    const c = await Client.connect(relay.port);
    clients.push(c);
    return c;
  };

  beforeAll(() => {
    relay = startRelay({ port: 0, enforceSignatures: true, replayHistory: false });
  });
  afterAll(() => {
    for (const c of clients) c.close();
    relay.stop();
  });

  test("valid signature is accepted", async () => {
    const id = await makeIdentity();
    const c = await connect();
    const ack = await c.register(id);
    expect(ack.nodeID).toBe(id.nodeID);
    expect(ack.ttlSeconds).toBe(300);
  });

  test("Rust/ed25519-dalek fixture verifies (deterministic RFC 8032 signature)", async () => {
    // Seed 0x01..0x20; nodeID and signature computed with RFC 8032 Ed25519,
    // identical to ed25519-dalek SigningKey::from_bytes + sign(nodeID).
    const nodeID = "79b5562e8fe654f94078b112e8a98ba7901f853ae695bed7e0e3910bad049664";
    const signature =
      "57123333064270891cbade3483bb71ff4a76a65d7dd7854834003351ab60fad0b1eab8d3c2e9a6ee762412f7a77850cef09cdfeb2444ea63c3a3ca552cce6a00";
    expect(await verifyRegisterSignature(nodeID, nodeID, signature)).toEqual({ ok: true });
    // Upper-case hex encodes the same key; but the signed message is the nodeID
    // string as sent, so the lower-case signature does not cover it.
    expect((await verifyRegisterSignature(nodeID.toUpperCase(), nodeID, signature)).ok).toBe(false);

    const c = await connect();
    c.send({ register: { nodeID, publicKey: nodeID, displayName: "fixture", capabilities: capabilities([], 8, 4), signature } });
    expect((await c.next("registerAck")).nodeID).toBe(nodeID);
  });

  test("signature from the wrong key is rejected", async () => {
    const victim = await makeIdentity();
    const attacker = await makeIdentity();
    const c = await connect();
    c.send({
      register: {
        nodeID: victim.nodeID,
        publicKey: victim.nodeID,
        displayName: "attacker",
        capabilities: capabilities([], 16, 2),
        signature: await attacker.sign(victim.nodeID),
      },
    });
    const err = await c.next("error");
    expect(err.code).toBe("invalid_signature");
    expect(await c.none("registerAck")).toBe(true);
  });

  test("nodeID different from publicKey is rejected", async () => {
    const victim = await makeIdentity();
    const attacker = await makeIdentity();
    const c = await connect();
    c.send({
      register: {
        nodeID: victim.nodeID,
        publicKey: attacker.nodeID,
        displayName: "attacker",
        capabilities: capabilities([], 16, 2),
        signature: await attacker.sign(victim.nodeID),
      },
    });
    const err = await c.next("error");
    expect(err.code).toBe("invalid_signature");
    expect(err.message).toContain("nodeID must equal publicKey");
  });

  test("a bad register does not evict the existing session", async () => {
    const victim = await makeIdentity();
    const attacker = await makeIdentity();
    const sender = await makeIdentity();

    const victimClient = await connect();
    await victimClient.register(victim);

    const attackerClient = await connect();
    attackerClient.send({
      register: {
        nodeID: victim.nodeID,
        publicKey: victim.nodeID,
        displayName: "attacker",
        capabilities: capabilities([], 16, 2),
        signature: "00".repeat(64),
      },
    });
    expect((await attackerClient.next("error")).code).toBe("invalid_signature");

    // The victim is still connected and still receives traffic addressed to it.
    const senderClient = await connect();
    await senderClient.register(sender);
    senderClient.send({ relayOpen: { fromNodeID: sender.nodeID, toNodeID: victim.nodeID, sessionID: "s-1" } });
    const open = await victimClient.next("relayOpen");
    expect(open.sessionID).toBe("s-1");
    expect(victimClient.closed).toBe(false);
    expect(await attackerClient.none("relayOpen")).toBe(true);
  });

  test("spoofed fromNodeID is overwritten with the registered nodeID", async () => {
    const target = await makeIdentity();
    const sender = await makeIdentity();
    const targetClient = await connect();
    await targetClient.register(target);
    const senderClient = await connect();
    await senderClient.register(sender);

    senderClient.send({
      relayData: { fromNodeID: "f".repeat(64), toNodeID: target.nodeID, sessionID: "s-2", data: "aGVsbG8=" },
    });
    const data = await targetClient.next("relayData");
    expect(data.fromNodeID).toBe(sender.nodeID);
    expect(data.data).toBe("aGVsbG8=");

    // Swift's {"_0": {...}} wrapper and a missing fromNodeID are handled too.
    senderClient.send({ offer: { _0: { toNodeID: target.nodeID, sessionID: "s-3", connectionInfo: {}, signature: "" } } });
    const offer = await targetClient.next("offer");
    expect(offer.fromNodeID).toBe(sender.nodeID);
    expect(offer.sessionID).toBe("s-3");
  });

  test("targeted messages from an unregistered socket are rejected", async () => {
    const target = await makeIdentity();
    const targetClient = await connect();
    await targetClient.register(target);
    const anon = await connect();
    anon.send({ relayOpen: { fromNodeID: "a".repeat(64), toNodeID: target.nodeID, sessionID: "s-4" } });
    expect((await anon.next("error")).code).toBe("not_registered");
    expect(await targetClient.none("relayOpen")).toBe(true);
  });

  test("messages right after register wait for verification (ordering)", async () => {
    const target = await makeIdentity();
    const sender = await makeIdentity();
    const targetClient = await connect();
    await targetClient.register(target);
    const senderClient = await connect();
    // Send register and relayOpen back to back without awaiting the ack.
    senderClient.send({
      register: {
        nodeID: sender.nodeID,
        publicKey: sender.nodeID,
        displayName: "fast",
        capabilities: capabilities([], 16, 2),
        signature: await sender.sign(sender.nodeID),
      },
    });
    senderClient.send({ relayOpen: { fromNodeID: sender.nodeID, toNodeID: target.nodeID, sessionID: "s-5" } });
    expect((await senderClient.next("registerAck")).nodeID).toBe(sender.nodeID);
    expect((await targetClient.next("relayOpen")).fromNodeID).toBe(sender.nodeID);
  });

  test("malformed payloads return errors instead of crashing the relay", async () => {
    const c = await connect();
    c.send("[1,2,3]");
    expect((await c.next("error")).code).toBe("invalid_message");
    c.send("null");
    expect((await c.next("error")).code).toBe("invalid_message");
    c.send("{not json");
    expect((await c.next("error")).code).toBe("invalid_json");
    c.send({ register: null });
    expect((await c.next("error")).code).toBe("invalid_register");
    c.send({ register: { nodeID: 5 } });
    expect((await c.next("error")).code).toBe("invalid_register");
    c.send({ discover: "x" });
    expect((await c.next("error")).code).toBe("invalid_message");
    c.send({ discover: { requestingNodeID: "x", filter: { minTier: "two" } } });
    expect((await c.next("error")).code).toBe("invalid_message");
    c.send({ nope: {} });
    expect((await c.next("error")).code).toBe("unsupported_message");

    const id = await makeIdentity();
    await c.register(id);
    c.send({ relayOpen: "x" });
    expect((await c.next("error")).code).toBe("invalid_message");
    c.send({ relayOpen: { toNodeID: 7, sessionID: "s" } });
    expect((await c.next("error")).code).toBe("invalid_message");
    // Still alive.
    c.send({ discover: null });
    expect(Array.isArray((await c.next("discoverResponse")).peers)).toBe(true);
  });
});

describe("relay discover filter", () => {
  let relay: Relay;
  const clients: Client[] = [];

  beforeAll(() => {
    relay = startRelay({ port: 0, enforceSignatures: true, replayHistory: false });
  });
  afterAll(() => {
    for (const c of clients) c.close();
    relay.stop();
  });

  test("filters by modelID, minRAMGB, minTier and caps with maxPeers", async () => {
    const big = await makeIdentity();
    const small = await makeIdentity();
    const asker = await makeIdentity();
    for (const [id, caps] of [
      [big, capabilities(["model-a"], 512, 1)],
      [small, capabilities(["model-b"], 16, 3)],
      [asker, capabilities([], 8, 4)],
    ] as const) {
      const c = await Client.connect(relay.port);
      clients.push(c);
      await c.register(id, caps);
    }
    const askerClient = clients[2]!;
    const ids = async (filter: unknown) => {
      askerClient.send({ discover: { requestingNodeID: asker.nodeID, filter } });
      const resp = await askerClient.next("discoverResponse");
      return (resp.peers as { nodeID: string }[]).map((p) => p.nodeID).sort();
    };

    expect(await ids(undefined)).toEqual([big.nodeID, small.nodeID].sort());
    expect(await ids({ modelID: "model-a" })).toEqual([big.nodeID]);
    expect(await ids({ minRAMGB: 32 })).toEqual([big.nodeID]);
    expect(await ids({ minTier: 2 })).toEqual([big.nodeID]);
    expect(await ids({ minTier: 3 })).toEqual([big.nodeID, small.nodeID].sort());
    expect(await ids({ modelID: "missing" })).toEqual([]);
    expect((await ids({ maxPeers: 1 })).length).toBe(1);
  });

  test("filter helpers", () => {
    expect(parseDiscover({ requestingNodeID: "x", filter: null })).toEqual({ requestingNodeID: "x", filter: {} });
    expect(typeof parseDiscover({ filter: { maxPeers: 0 } })).toBe("string");
    expect(peerMatchesFilter({ hardware: { tier: 0 } }, { minTier: 4 })).toBe(false);
    expect(peerMatchesFilter({}, {})).toBe(true);
  });
});

describe("relay with RELAY_ENFORCE_SIGNATURES=false", () => {
  let relay: Relay;
  const clients: Client[] = [];

  beforeAll(() => {
    relay = startRelay({ port: 0, enforceSignatures: false, replayHistory: false });
  });
  afterAll(() => {
    for (const c of clients) c.close();
    relay.stop();
  });

  test("bad signatures are logged but accepted", async () => {
    const id = await makeIdentity();
    const c = await Client.connect(relay.port);
    clients.push(c);
    c.send({
      register: { nodeID: id.nodeID, publicKey: id.nodeID, displayName: "legacy", capabilities: {}, signature: "bad" },
    });
    expect((await c.next("registerAck")).nodeID).toBe(id.nodeID);
  });
});

describe("relay admin endpoints", () => {
  test("/events and /peers require the admin token when configured", async () => {
    const relay = startRelay({ port: 0, adminToken: "secret", replayHistory: false });
    try {
      const base = `http://127.0.0.1:${relay.port}`;
      expect((await fetch(`${base}/health`)).status).toBe(200);
      expect((await fetch(`${base}/events`)).status).toBe(401);
      expect((await fetch(`${base}/peers`)).status).toBe(401);
      const ok = await fetch(`${base}/peers`, { headers: { authorization: "Bearer secret" } });
      expect(ok.status).toBe(200);
    } finally {
      relay.stop();
    }
  });
});
