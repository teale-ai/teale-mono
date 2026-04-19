# Error Codes

Reference for all error codes returned by the relay server and local API.

## Relay Errors

Errors returned by the relay server in `error` messages over WebSocket.

| Code | Description | When It Occurs |
|------|-------------|----------------|
| `peer_not_found` | Target peer is not connected to the relay | Sending `relayOpen`, `relayData`, `offer`, or `answer` to a peer that has disconnected |
| `invalid_json` | Message could not be parsed as JSON | Sending malformed JSON over the WebSocket |
| `invalid_message` | Empty or malformed message (no recognized message type key) | Sending an empty object `{}` or a message with an unrecognized structure |
| `invalid_register` | Missing required fields in register message | Omitting `nodeID`, `publicKey`, `capabilities`, or `signature` from registration |
| `rate_limited` | Too many requests; includes `retryAfterSeconds` field | Exceeding the discover rate limit (1 per 10 seconds) |
| `unsupported_message` | Unknown message type | Sending a message with an unrecognized type key |

### Relay Error Format

```json
{
  "error": {
    "code": "peer_not_found",
    "message": "Peer abc... is not connected"
  }
}
```

### Rate-Limited Error Format

Rate-limited errors include a `retryAfterSeconds` field indicating when the request can be retried.

```json
{
  "error": {
    "code": "rate_limited",
    "message": "Discover rate limited, retry after 8s",
    "retryAfterSeconds": 8
  }
}
```

## API Errors

Errors returned by the local HTTP API (`localhost:11435`).

| Code | Description | HTTP Status | When It Occurs |
|------|-------------|-------------|----------------|
| `model_not_loaded` | Requested model is not currently loaded | 503 | Sending a chat completion request for a model that is not loaded |
| `invalid_request` | Request body is malformed or missing required fields | 400 | Missing `messages` array, invalid JSON, or unsupported parameters |
| `internal_error` | An internal error occurred during processing | 500 | Inference engine crash, memory allocation failure, or unexpected exception |
| `unauthorized` | Invalid or missing API key | 401 | Request does not include a valid `Authorization: Bearer` header when API keys are configured |

### API Error Format

API errors follow the OpenAI error response format:

```json
{
  "error": {
    "message": "Model mlx-community/Qwen3-8B-4bit is not loaded",
    "type": "model_not_loaded",
    "code": "model_not_loaded"
  }
}
```

## PTN Errors

Errors that occur during Private TealeNet operations.

| Error | Description |
|-------|-------------|
| `invalidInviteCode` | The invite code could not be decoded (malformed base64url or JSON) |
| `inviteExpired` | The invite token's `expiresAt` has passed |
| `notPTNAdmin` | Operation requires admin role but the current node is not an admin |
| `caKeyNotFound` | CA private key not found on this device (only the PTN creator or key recipient has it) |
| `ptnNotFound` | The specified PTN is not in the node's membership list |
| `certificateVerificationFailed` | The certificate's signature does not verify against the PTN's CA public key |
| `joinRequestTimeout` | The inviter did not respond to the join request (likely offline) |
| `joinRejected` | The inviter explicitly rejected the join request |

## Noise Protocol Errors

Errors during encrypted session establishment or communication.

| Error | Description |
|-------|-------------|
| `handshakeFailed` | Noise handshake could not be completed (invalid keys, corrupted message, etc.) |
| `decryptionFailed` | ChaCha20-Poly1305 authentication tag verification failed |
| `invalidMessage` | Encrypted message is too short or structurally invalid |
| `invalidPublicKey` | Public key could not be parsed (not 32 bytes or invalid point) |
| `replayDetected` | Message nonce was already received (replay attack or duplicate) |
| `sessionExpired` | Noise session has exceeded its maximum lifetime (default 24 hours) |
