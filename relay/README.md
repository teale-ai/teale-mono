# Teale Relay

This is the WAN relay service for Teale.

It handles:

- peer registration
- peer discovery
- offer/answer forwarding
- relayed `ClusterMessage` transport for inference when direct WAN transport fails

## Local Run

```bash
cd relay
bun run start
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
