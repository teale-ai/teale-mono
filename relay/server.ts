import type { ServerWebSocket } from "bun";
import { loadHistory, logEvent, queryEvents, eventLogStatus } from "./eventlog.ts";
import {
  isObject,
  parseDiscover,
  parseRegister,
  parseTargeted,
  peerMatchesFilter,
  samplePeers,
  verifyRegisterSignature,
  type JSONObject,
  type JSONValue,
  type RegisterPayload,
} from "./validate.ts";

type WS = ServerWebSocket<unknown>;

type RelayPeer = {
  ws: WS;
  nodeID: string;
  publicKey: string;
  wgPublicKey?: string;
  displayName: string;
  capabilities: JSONObject;
  lastSeenReferenceSeconds: number;
  // Signature that proved this registration, and whether it verified.
  // A heartbeat re-register on the same socket with the same verified
  // signature skips re-verification.
  signature: string;
  verified: boolean;
};

type RelayMessage = Record<string, JSONValue>;

/** Messages the relay forwards verbatim to `toNodeID` (after stamping `fromNodeID`). */
const TARGETED_KINDS = new Set([
  "offer",
  "answer",
  "iceCandidate",
  "relayOpen",
  "relayReady",
  "relayData",
  "relayClose",
]);

export type RelayOptions = {
  /** TCP port; 0 picks a free port. Default: $PORT or 8080. */
  port?: number;
  /**
   * Reject `register` messages whose Ed25519 signature does not verify
   * (default true). With false, failures are logged but the registration
   * is accepted (env RELAY_ENFORCE_SIGNATURES=false).
   */
  enforceSignatures?: boolean;
  /** Bearer token required for GET /events and /peers when set (env RELAY_ADMIN_TOKEN). */
  adminToken?: string;
  /** Replay the on-disk event log into memory at start (default true). */
  replayHistory?: boolean;
};

export type RelayHandle = {
  port: number;
  stop: () => void;
};

const referenceDateSeconds = Date.parse("2001-01-01T00:00:00Z") / 1000;

function nowReferenceSeconds(): number {
  return Date.now() / 1000 - referenceDateSeconds;
}

export function startRelay(options: RelayOptions = {}): RelayHandle {
  const enforceSignatures = options.enforceSignatures ?? true;
  const adminToken = options.adminToken && options.adminToken.length > 0 ? options.adminToken : undefined;
  const peers = new Map<string, RelayPeer>();
  // Socket -> nodeID it has successfully registered. Only set after a
  // register is accepted, so it is the authority for `fromNodeID`.
  const sockets = new WeakMap<WS, string>();
  const closedSockets = new WeakSet<WS>();
  // Per-socket processing queue: register verification is async (WebCrypto),
  // so later messages on the same socket wait for it to keep strict ordering.
  const pending = new WeakMap<WS, Promise<void>>();

  // Delivery telemetry. Bun's ServerWebSocket.send() returns 0 when the message
  // was DROPPED (connection issue) and -1 when enqueued under backpressure.
  // Silent drops here corrupt relayed byte streams (socks tunnels) invisibly.
  const stats = {
    sent: 0,
    dropped: 0,
    backpressured: 0,
    lastDropAt: "",
    lastDropTo: "",
    registerRejected: 0,
    fromNodeIDOverwritten: 0,
  };

  function send(ws: WS, message: RelayMessage) {
    const result = ws.send(JSON.stringify(message));
    stats.sent++;
    if (result === 0) {
      stats.dropped++;
      stats.lastDropAt = new Date().toISOString();
      stats.lastDropTo = sockets.get(ws)?.substring(0, 16) ?? "unknown";
      console.log(`[send] DROPPED message to ${stats.lastDropTo}... kind=${Object.keys(message)[0]} buffered=${ws.getBufferedAmount()}`);
      logEvent("drop", { to: sockets.get(ws) ?? "unknown", msg_kind: Object.keys(message)[0] ?? "", buffered: ws.getBufferedAmount() });
    } else if (result === -1) {
      stats.backpressured++;
      if (stats.backpressured % 100 === 1) {
        console.log(`[send] backpressure enqueuing to ${sockets.get(ws)?.substring(0, 16) ?? "unknown"}... buffered=${ws.getBufferedAmount()} count=${stats.backpressured}`);
        logEvent("backpressure", { to: sockets.get(ws) ?? "unknown", buffered: ws.getBufferedAmount(), count: stats.backpressured });
      }
    }
  }

  function peerInfo(peer: RelayPeer) {
    return {
      nodeID: peer.nodeID,
      publicKey: peer.publicKey,
      wgPublicKey: peer.wgPublicKey ?? null,
      displayName: peer.displayName,
      capabilities: peer.capabilities,
      lastSeen: peer.lastSeenReferenceSeconds,
      natType: "unknown",
      endpoints: [],
    };
  }

  function broadcast(message: RelayMessage, excludeNodeID?: string) {
    for (const peer of peers.values()) {
      if (peer.nodeID === excludeNodeID) {
        continue;
      }
      send(peer.ws, message);
    }
  }

  function sendError(ws: WS, code: string, errorMessage: string) {
    send(ws, {
      error: {
        code,
        message: errorMessage,
      },
    });
  }

  function forwardToTarget(kind: string, rawPayload: unknown, sender: WS) {
    const payload = parseTargeted(kind, rawPayload);
    if (typeof payload === "string") {
      sendError(sender, "invalid_message", payload);
      return;
    }

    // The sender's identity is the nodeID it registered (and proved) on this
    // socket - never what it claims in the payload.
    const claimedFrom = typeof payload.fromNodeID === "string" ? payload.fromNodeID : undefined;
    let fromNodeID = sockets.get(sender);
    if (fromNodeID === undefined) {
      if (enforceSignatures || claimedFrom === undefined) {
        sendError(sender, "not_registered", `Register before sending ${kind}`);
        return;
      }
      fromNodeID = claimedFrom; // legacy, signatures not enforced
    }
    if (claimedFrom !== fromNodeID) {
      stats.fromNodeIDOverwritten++;
      if (stats.fromNodeIDOverwritten % 100 === 1) {
        logEvent("from_overwritten", { from: fromNodeID, claimed: claimedFrom ?? null, msg_kind: kind, count: stats.fromNodeIDOverwritten });
      }
    }

    const target = peers.get(payload.toNodeID);
    if (!target) {
      sendError(sender, "peer_not_found", `Peer ${payload.toNodeID} is not connected`);
      logEvent("peer_not_found", { from: fromNodeID, to: payload.toNodeID, msg_kind: kind });
      return;
    }

    send(target.ws, {
      [kind]: claimedFrom === fromNodeID ? payload : { ...payload, fromNodeID },
    });
  }

  function handleRegister(ws: WS, rawPayload: unknown): void | Promise<void> {
    const payload = parseRegister(rawPayload);
    if (typeof payload === "string") {
      sendError(ws, "invalid_register", payload);
      return;
    }

    const existing = peers.get(payload.nodeID);
    // Heartbeat fast path: the same socket re-registering with the signature
    // that already verified (Rust clients sign deterministically).
    if (
      existing &&
      existing.ws === ws &&
      existing.verified &&
      existing.signature === payload.signature &&
      existing.publicKey === payload.publicKey
    ) {
      completeRegister(ws, payload, true);
      return;
    }

    return verifyRegisterSignature(payload.nodeID, payload.publicKey, payload.signature).then((check) => {
      if (closedSockets.has(ws)) {
        return;
      }
      if (!check.ok) {
        stats.registerRejected++;
        console.log(`[register] signature check failed for ${payload.nodeID.substring(0, 16)}... (${check.reason}) enforced=${enforceSignatures}`);
        logEvent("register_rejected", { node: payload.nodeID, reason: check.reason, enforced: enforceSignatures });
        if (enforceSignatures) {
          // Reject without touching any existing session for this nodeID.
          sendError(ws, "invalid_signature", `Register rejected: ${check.reason}`);
          return;
        }
      }
      completeRegister(ws, payload, check.ok);
    });
  }

  function completeRegister(ws: WS, payload: RegisterPayload, verified: boolean) {
    console.log(`[register] nodeID=${payload.nodeID.substring(0, 16)}... displayName=${payload.displayName} peers_before=${peers.size}`);
    const existing = peers.get(payload.nodeID);
    // Store the new peer BEFORE closing the old connection to prevent race conditions.
    // If we close first, the close handler could fire synchronously and remove the peer
    // before the new registration is stored.
    const peer: RelayPeer = {
      ws,
      nodeID: payload.nodeID,
      publicKey: payload.publicKey,
      wgPublicKey: payload.wgPublicKey,
      displayName: payload.displayName,
      capabilities: payload.capabilities,
      lastSeenReferenceSeconds: nowReferenceSeconds(),
      signature: payload.signature,
      verified,
    };

    peers.set(payload.nodeID, peer);
    sockets.set(ws, payload.nodeID);

    // Close old connection AFTER the new peer is stored, so the close handler
    // sees peer.ws !== old_ws and skips removal.
    if (existing && existing.ws !== ws) {
      console.log(`[register] replacing existing session for ${payload.nodeID.substring(0, 16)}...`);
      existing.ws.close(1012, "Replaced by newer session");
    }

    send(ws, {
      registerAck: {
        nodeID: payload.nodeID,
        registeredAt: peer.lastSeenReferenceSeconds,
        ttlSeconds: 300,
      },
    });

    // A re-register on the SAME live socket is a heartbeat, not a join: the
    // node's periodic heartbeat re-registers on its existing session to keep
    // the capability cache fresh. Broadcasting peerJoined for those ticks
    // makes every consumer tear down and rebuild peer state on the node's
    // heartbeat cadence (40s in the fleet), which reads as catalog churn.
    // Broadcast only for a genuinely new nodeID or a session replacement.
    const isSessionRefresh = existing !== undefined && existing.ws === ws;
    logEvent("register", {
      node: payload.nodeID,
      displayName: payload.displayName,
      peers_before: peers.size - 1,
      replaced: existing !== undefined && existing.ws !== ws,
      refresh: isSessionRefresh,
      verified,
    });
    if (!isSessionRefresh) {
      broadcast(
        {
          peerJoined: {
            nodeID: payload.nodeID,
            displayName: payload.displayName,
          },
        },
        payload.nodeID,
      );
    }
  }

  function handleDiscover(ws: WS, rawPayload: unknown) {
    const request = parseDiscover(rawPayload);
    if (typeof request === "string") {
      sendError(ws, "invalid_message", request);
      return;
    }
    const requestingNodeID = request.requestingNodeID ?? sockets.get(ws);
    const matching = Array.from(peers.values()).filter(
      (peer) => peer.nodeID !== requestingNodeID && peerMatchesFilter(peer.capabilities, request.filter),
    );

    send(ws, {
      discoverResponse: {
        peers: samplePeers(matching, request.filter.maxPeers).map(peerInfo),
      },
    });
  }

  function handleMessage(ws: WS, rawMessage: string | Buffer): void | Promise<void> {
    let message: unknown;
    try {
      message = JSON.parse(rawMessage.toString());
    } catch {
      sendError(ws, "invalid_json", "Could not decode relay message");
      return;
    }

    if (!isObject(message)) {
      sendError(ws, "invalid_message", "Relay message must be a JSON object with one key");
      return;
    }
    const entry = Object.entries(message)[0];
    if (!entry) {
      sendError(ws, "invalid_message", "Empty relay message");
      return;
    }

    const [kind, rawPayload] = entry;

    // Any message from a registered socket proves liveness - refresh lastSeen.
    // Clients that register once per connection (the Rust gateway) otherwise
    // look stale forever while their socket is healthy, and Swift clients
    // prune peers older than 600s.
    const senderNodeID = sockets.get(ws);
    if (senderNodeID) {
      const senderPeer = peers.get(senderNodeID);
      if (senderPeer && senderPeer.ws === ws) {
        senderPeer.lastSeenReferenceSeconds = nowReferenceSeconds();
      }
    }

    // Support both flat JSON and Swift's auto-synthesized {"_0": {...}} wrapper format.
    const payload: unknown = isObject(rawPayload) && rawPayload._0 !== undefined ? rawPayload._0 : rawPayload;

    console.log(`[msg] kind=${kind} from=${senderNodeID?.substring(0, 16) ?? "unknown"}...`);

    if (kind === "register") {
      return handleRegister(ws, payload);
    }
    if (kind === "discover") {
      handleDiscover(ws, payload);
      return;
    }
    if (TARGETED_KINDS.has(kind)) {
      forwardToTarget(kind, payload, ws);
      return;
    }
    sendError(ws, "unsupported_message", `Unsupported relay message: ${kind}`);
  }

  function track(ws: WS, work: Promise<void>) {
    const tracked = work.catch((e) => {
      console.log(`[msg] handler error: ${e}`);
    });
    pending.set(ws, tracked);
    tracked.then(() => {
      if (pending.get(ws) === tracked) {
        pending.delete(ws);
      }
    });
  }

  function runHandler(ws: WS, rawMessage: string | Buffer): void | Promise<void> {
    try {
      return handleMessage(ws, rawMessage);
    } catch (e) {
      console.log(`[msg] handler error: ${e}`);
      sendError(ws, "internal_error", "Relay failed to process message");
    }
  }

  function onMessage(ws: WS, rawMessage: string | Buffer) {
    const prior = pending.get(ws);
    if (prior) {
      track(ws, prior.then(() => runHandler(ws, rawMessage)));
      return;
    }
    const result = runHandler(ws, rawMessage);
    if (result) {
      track(ws, result);
    }
  }

  // Mass-close detector (#284): a platform/proxy-edge event kills every socket
  // in the same instant with no deploy and no process start (observed
  // 2026-09-07 14:13Z: 7 peers in 1s). Per-close logs alone can't distinguish
  // that from ordinary churn, so closes within a tight window roll up into one
  // mass_close event carrying codes/reasons - the signature that separates an
  // edge event (abnormal/no code) from relay-initiated replaces (1012) and
  // clean client closes (1000).
  const recentCloses: { ts: number; nodeID: string; code: number; reason: string }[] = [];
  const MASS_CLOSE_WINDOW_MS = 2000;
  const MASS_CLOSE_MIN = 3;

  function handleClose(ws: WS, code: number, reason: string) {
    closedSockets.add(ws);
    const nodeID = sockets.get(ws);
    if (!nodeID) {
      console.log(`[close] unknown websocket closed code=${code} reason=${JSON.stringify(reason)}`);
      logEvent("close", { outcome: "unknown_socket", code, reason });
      return;
    }

    console.log(`[close] nodeID=${nodeID.substring(0, 16)}... peers_before=${peers.size} code=${code} reason=${JSON.stringify(reason)}`);
    sockets.delete(ws);
    const peer = peers.get(nodeID);
    if (!peer || peer.ws !== ws) {
      console.log(`[close] stale ws for ${nodeID.substring(0, 16)}... (already replaced)`);
      logEvent("close", { node: nodeID, outcome: "stale_replaced", code, reason });
      return;
    }

    peers.delete(nodeID);
    const now = Date.now();
    recentCloses.push({ ts: now, nodeID, code, reason });
    while (recentCloses.length && now - (recentCloses[0]?.ts ?? now) > MASS_CLOSE_WINDOW_MS) recentCloses.shift();
    if (recentCloses.length >= MASS_CLOSE_MIN) {
      const codes: Record<string, number> = {};
      for (const c of recentCloses) codes[String(c.code)] = (codes[String(c.code)] ?? 0) + 1;
      console.log(`[mass_close] ${recentCloses.length} sockets closed within ${MASS_CLOSE_WINDOW_MS}ms; codes=${JSON.stringify(codes)} peers_after=${peers.size} - platform/edge event signature, not per-socket churn`);
      logEvent("mass_close", {
        closed: recentCloses.map((c) => ({ node: c.nodeID, code: c.code, reason: c.reason })),
        window_ms: MASS_CLOSE_WINDOW_MS,
        codes,
        peers_after: peers.size,
      });
      recentCloses.length = 0; // one roll-up per burst, not per close
    }
    console.log(`[close] removed ${nodeID.substring(0, 16)}... peers_after=${peers.size}`);
    logEvent("close", { node: nodeID, outcome: "removed", peers_after: peers.size, code, reason });
    broadcast({
      peerLeft: {
        nodeID,
        displayName: peer.displayName,
      },
    });
  }

  function authorized(req: Request): boolean {
    if (!adminToken) return true;
    return req.headers.get("authorization") === `Bearer ${adminToken}`;
  }

  const server = Bun.serve({
    port: options.port ?? Number(Bun.env.PORT ?? "8080"),
    fetch(req, server) {
      const url = new URL(req.url);
      if (url.pathname === "/health") {
        return Response.json({
          ok: true,
          peers: peers.size,
          enforceSignatures,
          stats,
          eventlog: eventLogStatus(),
        });
      }

      // Post-hoc forensics (#221): recent control-plane events, newest last.
      // Node IDs are truncated here; full IDs stay in the on-disk JSONL,
      // readable via flyctl ssh console -a teale-relay.
      if (url.pathname === "/events") {
        if (!authorized(req)) return new Response("Unauthorized", { status: 401 });
        return Response.json({ events: queryEvents(url.searchParams) });
      }

      if (url.pathname === "/peers") {
        if (!authorized(req)) return new Response("Unauthorized", { status: 401 });
        const peerList = Array.from(peers.values()).map((p) => ({
          nodeID: p.nodeID.substring(0, 16) + "...",
          displayName: p.displayName,
          wgPublicKey: p.wgPublicKey ? p.wgPublicKey.substring(0, 16) + "..." : null,
          lastSeen: p.lastSeenReferenceSeconds,
        }));
        return Response.json({ peers: peerList });
      }

      if (url.pathname === "/ws" && server.upgrade(req)) {
        return undefined;
      }

      return new Response("Not found", { status: 404 });
    },
    websocket: {
      message(ws, message) {
        onMessage(ws, message);
      },
      close(ws, code, reason) {
        handleClose(ws, code, reason);
      },
    },
  });

  const replayed = options.replayHistory === false ? 0 : loadHistory();
  logEvent("start", { port: server.port ?? 0, events_replayed: replayed, enforce_signatures: enforceSignatures });
  console.log(`relay listening on :${server.port} (replayed ${replayed} events from disk, enforceSignatures=${enforceSignatures})`);

  // Periodic stats snapshot so post-hoc forensics get a counter timeline
  // (registrations/closes are event-driven; delivery counters are not).
  const statsTimer = setInterval(() => {
    logEvent("stats", {
      sent: stats.sent,
      dropped: stats.dropped,
      backpressured: stats.backpressured,
      register_rejected: stats.registerRejected,
      peers: peers.size,
    });
  }, 60_000);

  return {
    port: server.port ?? 0,
    stop() {
      clearInterval(statsTimer);
      server.stop(true);
    },
  };
}

if (import.meta.main) {
  startRelay({
    enforceSignatures: (Bun.env.RELAY_ENFORCE_SIGNATURES ?? "true").trim().toLowerCase() !== "false",
    adminToken: Bun.env.RELAY_ADMIN_TOKEN,
  });
}
