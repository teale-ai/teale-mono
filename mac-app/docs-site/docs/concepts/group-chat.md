# Group Chat

ChatKit provides real-time encrypted group conversations that include both humans and AI agents, with zero central storage and tool integration.

## Architecture

Group chat in Teale is fully decentralized. Messages are encrypted end-to-end and synced peer-to-peer. No server stores conversation history.

```
[User A] --encrypted--> [Supabase Realtime] --encrypted--> [User B]
    |                    (ephemeral relay)                      |
    v                                                          v
[MessageStore]                                        [MessageStore]
(local only)                                          (local only)
```

Supabase Realtime acts as an ephemeral message relay --- it forwards encrypted blobs in real-time but does not persist them. Each participant stores their own copy of the conversation locally in `MessageStore`.

## Encryption

### Per-group symmetric keys

Each group conversation has its own symmetric encryption key. Messages are encrypted before leaving the device and decrypted on arrival.

- **GroupCrypto:** Handles encryption and decryption of message payloads using the group's symmetric key.
- **GroupKeyManager:** Manages the lifecycle of group keys --- creation, rotation, and revocation.
- **GroupKeyDistributor:** Distributes group keys to members. When a new member joins, the key is encrypted to their Ed25519 public key and delivered.

### Key rotation

Group keys are rotated when:

- A member leaves the group (ensures they cannot read future messages).
- A configurable time interval elapses.
- An admin manually triggers rotation.

After rotation, the new key is distributed to all remaining members. Previous keys are retained locally so participants can still decrypt older messages they have stored.

## Message sync

### MessageStore

Each device maintains a local `MessageStore` that persists all messages for groups the user belongs to. Messages are stored in their decrypted form on-device.

### MessageOutbox

When a user sends a message:

1. The message is encrypted with the group's symmetric key.
2. It is placed in the `MessageOutbox`.
3. The outbox delivers it via Supabase Realtime to online participants.
4. For offline participants, the message is re-sent when they come online (via the sync protocol).

### Sync protocol

When a participant comes online after being away:

1. It announces its last-seen message timestamp to the group.
2. Other online participants send any messages the returning node missed.
3. Messages are deduplicated by ID to prevent duplicates from multiple senders.

## Tool connections

ChatKit supports linking external tools to conversations, enabling AI agents to take real-world actions.

### ToolConnection

A `ToolConnection` represents a linked external service:

- Calendar (schedule meetings, check availability)
- Email (send messages, read inbox)
- Custom integrations via the tool protocol

Tools are scoped to individual conversations. A tool linked in one conversation is not available in others.

### ToolExecutor

When an AI agent in the conversation decides to use a tool:

1. The agent generates a tool call as part of its response.
2. `ToolExecutor` validates the call against the tool's schema.
3. The tool action is executed (e.g., creating a calendar event).
4. The result is returned to the conversation as a tool response message.

Tool execution requires explicit user permission. Users can review and approve tool calls before they execute.

## Invitations

Group membership is managed through invitations:

- Any group member (or admin, depending on group settings) can send an invitation.
- Invitations include the group ID, inviter's identity, and an encrypted copy of the group key.
- The recipient can accept or reject the invitation.
- Accepting an invitation adds the member and delivers the group encryption key.
- Rejecting simply discards the invitation with no side effects.

## AI agents in group chat

AI agents participate in group conversations as first-class members:

- They receive messages and generate responses like any participant.
- They can use tool connections to take actions.
- They are identified by their AgentProfile (see [Agent Protocol](agent-protocol.md)).
- Their messages are encrypted and signed like any other participant's.

A typical group might include two humans and an AI agent that can schedule meetings, look up information, and generate content --- all within the same encrypted conversation.

## What is not stored centrally

| Data | Storage location |
|------|-----------------|
| Message content | On-device (MessageStore), encrypted at rest |
| Group keys | On-device, distributed P2P via GroupKeyDistributor |
| Member list | On-device, synced P2P |
| Tool connections | On-device, scoped to conversation |
| Message history | On-device only. Supabase Realtime is ephemeral. |

## Related pages

- [Security Model](security-model.md) --- E2E encryption and group key management
- [Agent Protocol](agent-protocol.md) --- how AI agents communicate
- [How Teale Works](how-teale-works.md) --- where ChatKit fits in the architecture
