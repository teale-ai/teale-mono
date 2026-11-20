# Teale Relay

This is the WAN relay service for Teale.

It handles:

- peer registration
- peer discovery
- offer/answer forwarding
- relayed `ClusterMessage` transport for inference when direct WAN transport fails

The wire protocol (messages, discover filters, error codes, the register
signature rule) is specified in [`docs/protocol.md`](../docs/protocol.md).

## Local Run

```bash
cd relay
bun run start
```

Environment:

- `PORT` (default `8080`)
- `RELAY_ENFORCE_SIGNATURES` (default `true`): every `register` must carry
  `signature = hex(Ed25519.sign(utf8(nodeID)))` with `nodeID == publicKey`.
  Set to `false` only as an emergency escape hatch; failures are then logged
  (`register_rejected` events) but accepted.
- `RELAY_ADMIN_TOKEN` (unset by default): when set, `/events` and `/peers`
  require `Authorization: Bearer <token>`.
- `RELAY_LOG_DIR` (default `/app/logs`)

## Checks

```bash
cd relay
bun install
bun run typecheck   # tsc --noEmit, strict
bun test            # eventlog.test.ts, server.test.ts
```

Health check:

```bash
curl http://127.0.0.1:8080/health
```

WebSocket endpoint:

```text
ws://127.0.0.1:8080/ws
```

## Fly Deploy

1. Install `flyctl`
2. Pick an app name and update `app` in `fly.toml`
3. From `relay/`, launch or deploy:

```bash
fly launch --no-deploy
fly deploy
```

4. Confirm health:

```bash
curl https://relay.teale.com/health
```

The production relay is deployed at `wss://relay.teale.com/ws` and is the default in both apps.

## Platform Note

Use Fly, not Vercel, for this relay. Teale needs a long-lived WebSocket server, and Vercel Functions do not support acting as a WebSocket server.

## Forensics: durable event log (#221)

Fly's log retention for this app is effectively a ~1 minute ring buffer, so
`flyctl logs` cannot answer "what happened to node X at 09:04" after the fact.
The relay appends low-volume control-plane events (process start, register /
replace / refresh, close, peer_not_found, drops, backpressure samples, and a
60s stats snapshot) to `/app/logs/events.jsonl` on the machine rootfs, rotating
at 4MB with one generation kept. The rootfs survives process restarts (the
common failure mode) and is only reset on machine replacement or a new image
deploy.

Query paths:

- Live process: `GET /events?since=<iso|epoch_s>&kind=<kind>&node=<id-prefix>&limit=<n>`
  (node IDs truncated to 16 chars at any nesting level, matching `/peers`;
  bearer token required when `RELAY_ADMIN_TOKEN` is set). `/health` includes an
  `eventlog` status block (ring size, oldest/newest timestamps, write failures).
- Post-restart: on boot the tail of the file is replayed into memory, so
  `/events` serves seamless history across restarts. Full (untruncated) history
  stays on disk: `flyctl ssh console -a teale-relay -C 'cat /app/logs/events.jsonl'`.
