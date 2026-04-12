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

function nowReferenceSeconds(): number {
  return Date.now() / 1000 - referenceDateSeconds;
}

function send(ws: ServerWebSocket<unknown>, message: RelayMessage) {
  ws.send(JSON.stringify(message));
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

  // Swift's auto-synthesized Codable wraps enum associated values in {"_0": {...}}.
  // Unwrap transparently so the relay handles both formats.
  const payload = rawPayload?._0 ?? rawPayload;

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

function handleClose(ws: ServerWebSocket<unknown>) {
  const nodeID = sockets.get(ws);
  if (!nodeID) {
    console.log(`[close] unknown websocket closed`);
    return;
  }

  console.log(`[close] nodeID=${nodeID.substring(0, 16)}... peers_before=${peers.size}`);
  sockets.delete(ws);
  const peer = peers.get(nodeID);
  if (!peer || peer.ws !== ws) {
    console.log(`[close] stale ws for ${nodeID.substring(0, 16)}... (already replaced)`);
    return;
  }

  peers.delete(nodeID);
  console.log(`[close] removed ${nodeID.substring(0, 16)}... peers_after=${peers.size}`);
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
        peers: peers.size
      });
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
    close(ws) {
      handleClose(ws);
    }
  }
});

console.log(`relay listening on :${server.port}`);
