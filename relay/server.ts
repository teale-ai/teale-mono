import { loadHistory, logEvent, queryEvents, eventLogStatus } from "./eventlog.ts";

type JSONValue =
  | string
  | number
  | boolean
  | null
  | JSONValue[]
  | { [key: string]: JSONValue };

type RegisterPayload = {
  nodeID: string;
  publicKey: string;
  wgPublicKey?: string;
  displayName: string;
  capabilities: JSONValue;
  signature: string;
};

type DiscoverPayload = {
  requestingNodeID: string;
};

type TargetedPayload = {
  fromNodeID: string;
  toNodeID: string;
  sessionID: string;
};

type RelayPeer = {
  ws: ServerWebSocket<unknown>;
  nodeID: string;
  publicKey: string;
  wgPublicKey?: string;
  displayName: string;
  capabilities: JSONValue;
  lastSeenReferenceSeconds: number;
};

type RelayMessage = Record<string, JSONValue>;

const port = Number(Bun.env.PORT ?? "8080");
const referenceDateSeconds = Date.parse("2001-01-01T00:00:00Z") / 1000;
const peers = new Map<string, RelayPeer>();
const sockets = new WeakMap<ServerWebSocket<unknown>, string>();

// Delivery telemetry. Bun's ServerWebSocket.send() returns 0 when the message
// was DROPPED (connection issue) and -1 when enqueued under backpressure.
// Silent drops here corrupt relayed byte streams (socks tunnels) invisibly.
const stats = {
  sent: 0,
  dropped: 0,
  backpressured: 0,
  lastDropAt: "",
  lastDropTo: "",
};

function nowReferenceSeconds(): number {
  return Date.now() / 1000 - referenceDateSeconds;
}

function send(ws: ServerWebSocket<unknown>, message: RelayMessage) {
  const result = ws.send(JSON.stringify(message));
  stats.sent++;
  if (result === 0) {
    stats.dropped++;
    stats.lastDropAt = new Date().toISOString();
    stats.lastDropTo = sockets.get(ws)?.substring(0, 16) ?? "unknown";
    console.log(`[send] DROPPED message to ${stats.lastDropTo}... kind=${Object.keys(message)[0]} buffered=${ws.getBufferedAmount()}`);
    logEvent("drop", { to: sockets.get(ws) ?? "unknown", msg_kind: Object.keys(message)[0], buffered: ws.getBufferedAmount() });
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
    endpoints: []
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

function sendError(ws: ServerWebSocket<unknown>, code: string, errorMessage: string) {
  send(ws, {
    error: {
      code,
      message: errorMessage
    }
  });
}

function forwardToTarget(kind: string, payload: TargetedPayload & Record<string, JSONValue>, sender: ServerWebSocket<unknown>) {
  const target = peers.get(payload.toNodeID);
  if (!target) {
    sendError(sender, "peer_not_found", `Peer ${payload.toNodeID} is not connected`);
    logEvent("peer_not_found", { from: sockets.get(sender) ?? "unknown", to: payload.toNodeID, msg_kind: kind });
    return;
  }

  send(target.ws, {
    [kind]: payload
  });
}

function handleRegister(ws: ServerWebSocket<unknown>, payload: RegisterPayload) {
  if (!payload?.nodeID) {
    sendError(ws, "invalid_register", "Missing nodeID in register payload");
    return;
  }
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
    lastSeenReferenceSeconds: nowReferenceSeconds()
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
      ttlSeconds: 300
    }
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
  });
  if (!isSessionRefresh) {
    broadcast(
      {
        peerJoined: {
          nodeID: payload.nodeID,
          displayName: payload.displayName
        }
      },
      payload.nodeID
    );
  }
}

function handleDiscover(ws: ServerWebSocket<unknown>, payload: DiscoverPayload) {
  const responsePeers = Array.from(peers.values())
    .filter((peer) => peer.nodeID !== payload.requestingNodeID)
    .map(peerInfo);

  send(ws, {
    discoverResponse: {
      peers: responsePeers
    }
  });
}

function handleMessage(ws: ServerWebSocket<unknown>, rawMessage: string | Buffer) {
  let message: RelayMessage;
  try {
    message = JSON.parse(rawMessage.toString());
  } catch {
    sendError(ws, "invalid_json", "Could not decode relay message");
    return;
  }

  const entry = Object.entries(message)[0];
  if (!entry) {
    sendError(ws, "invalid_message", "Empty relay message");
    return;
  }

  const [kind, rawPayload] = entry as [string, any];

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
  const payload = rawPayload?._0 ?? rawPayload;

  console.log(`[msg] kind=${kind} from=${sockets.get(ws)?.substring(0, 16) ?? "unknown"}...`);

  switch (kind) {
    case "register":
      handleRegister(ws, payload as RegisterPayload);
      break;

    case "discover":
      handleDiscover(ws, payload as DiscoverPayload);
      break;

    case "offer":
    case "answer":
    case "iceCandidate":
    case "relayOpen":
    case "relayReady":
    case "relayData":
    case "relayClose":
      forwardToTarget(kind, payload as TargetedPayload & Record<string, JSONValue>, ws);
      break;

    default:
      sendError(ws, "unsupported_message", `Unsupported relay message: ${kind}`);
      break;
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

function handleClose(ws: ServerWebSocket<unknown>, code: number, reason: string) {
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
  while (recentCloses.length && now - recentCloses[0].ts > MASS_CLOSE_WINDOW_MS) recentCloses.shift();
  if (recentCloses.length >= MASS_CLOSE_MIN) {
    const codes: Record<string, number> = {};
    for (const c of recentCloses) codes[String(c.code)] = (codes[String(c.code)] ?? 0) + 1;
    console.log(`[mass_close] ${recentCloses.length} sockets closed within ${MASS_CLOSE_WINDOW_MS}ms; codes=${JSON.stringify(codes)} peers_after=${peers.size} - platform/edge event signature, not per-socket churn`);
    logEvent("mass_close", {
      closed: recentCloses.map(c => ({ node: c.nodeID, code: c.code, reason: c.reason })),
      window_ms: MASS_CLOSE_WINDOW_MS,
      codes,
      peers_after: peers.size
    });
    recentCloses.length = 0; // one roll-up per burst, not per close
  }
  console.log(`[close] removed ${nodeID.substring(0, 16)}... peers_after=${peers.size}`);
  logEvent("close", { node: nodeID, outcome: "removed", peers_after: peers.size, code, reason });
  broadcast({
    peerLeft: {
      nodeID,
      displayName: peer.displayName
    }
  });
}

const server = Bun.serve({
  port,
  fetch(req, server) {
    const url = new URL(req.url);
    if (url.pathname === "/health") {
      return Response.json({
        ok: true,
        peers: peers.size,
        stats,
        eventlog: eventLogStatus()
      });
    }

    // Post-hoc forensics (#221): recent control-plane events, newest last.
    // Node IDs are truncated here; full IDs stay in the on-disk JSONL,
    // readable via flyctl ssh console -a teale-relay.
    if (url.pathname === "/events") {
      return Response.json({ events: queryEvents(url.searchParams) });
    }

    if (url.pathname === "/peers") {
      const peerList = Array.from(peers.values()).map(p => ({
        nodeID: p.nodeID.substring(0, 16) + "...",
        displayName: p.displayName,
        wgPublicKey: p.wgPublicKey ? p.wgPublicKey.substring(0, 16) + "..." : null,
        lastSeen: p.lastSeenReferenceSeconds,
      }));
      return Response.json({ peers: peerList });
    }

    if (url.pathname === "/ws" && server.upgrade(req)) {
      return;
    }

    return new Response("Not found", { status: 404 });
  },
  websocket: {
    message(ws, message) {
      handleMessage(ws, message);
    },
    close(ws, code, reason) {
      handleClose(ws, code, reason);
    }
  }
});

const replayed = loadHistory();
logEvent("start", { port: server.port, events_replayed: replayed });
console.log(`relay listening on :${server.port} (replayed ${replayed} events from disk)`);

// Periodic stats snapshot so post-hoc forensics get a counter timeline
// (registrations/closes are event-driven; delivery counters are not).
setInterval(() => {
  logEvent("stats", {
    sent: stats.sent,
    dropped: stats.dropped,
    backpressured: stats.backpressured,
    peers: peers.size,
  });
}, 60_000);
