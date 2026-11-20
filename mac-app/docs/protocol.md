# TealeNet Relay Protocol

The relay protocol spec lives in one place: [`docs/protocol.md`](../../docs/protocol.md)
at the repository root. It is written from `relay/server.ts` and covers the
HTTP endpoints, every relay message, discover filtering, error codes and the
register signature rule.

This file used to hold a second, diverging copy (it described a `/metrics`
endpoint, a discover rate limit and deprecated `peerJoined`/`peerLeft`, none
of which the relay implements). Edit the root spec instead.
