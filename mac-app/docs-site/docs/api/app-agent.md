# Agent

Endpoints for managing the node's agent profile, browsing the agent directory, and listing agent conversations.

---

## Agent Profile

```
GET /v1/app/agent/profile
```

Returns this node's agent profile, including its public identity and capabilities.

### Authentication

Optional. Required when `allow_network_access` is enabled.

### Response

```json
{
  "nodeID": "node-abc123",
  "name": "My Assistant",
  "capabilities": ["chat", "code", "analysis"],
  "model": "llama-3.1-8b-q4",
  "status": "online"
}
```

### Example

```bash
curl http://localhost:11435/v1/app/agent/profile
```

---

## Agent Directory

```
GET /v1/app/agent/directory
```

Returns a list of agents discoverable on the network.

### Authentication

Optional. Required when `allow_network_access` is enabled.

### Response

```json
{
  "agents": [
    {
      "nodeID": "node-def456",
      "name": "Code Helper",
      "capabilities": ["chat", "code"],
      "model": "qwen3-4b-q4",
      "status": "online"
    }
  ]
}
```

### Example

```bash
curl http://localhost:11435/v1/app/agent/directory
```

---

## Agent Conversations

```
GET /v1/app/agent/conversations
```

Returns a list of agent-to-agent conversations this node has participated in.

### Authentication

Optional. Required when `allow_network_access` is enabled.

### Response

```json
{
  "conversations": [
    {
      "id": "conv-abc123",
      "peerID": "node-def456",
      "peerName": "Code Helper",
      "messageCount": 14,
      "lastMessage": "2026-04-14T10:30:00Z"
    }
  ]
}
```

### Example

```bash
curl http://localhost:11435/v1/app/agent/conversations
```
