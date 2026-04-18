import Foundation

// MARK: - Group Key Distribution

/// Distributes sender keys to group members over P2P channels.
/// Keys are sent via the existing ClusterMessage/AgentMessage transport,
/// which is already encrypted via Noise on WAN connections.
public actor GroupKeyDistributor {
    private let keyManager: GroupKeyManager
    private var transport: GroupKeyTransport?

    public init(keyManager: GroupKeyManager) {
        self.keyManager = keyManager
    }

    /// Set the transport layer for sending key exchange messages.
    public func setTransport(_ transport: GroupKeyTransport) {
        self.transport = transport
    }

    // MARK: - Key Distribution

    /// Distribute our sender key to all group members.
    /// Call on group creation, when joining a group, or after key rotation.
    public func distributeMyKey(groupID: UUID, memberNodeIDs: [String]) async throws {
        let myKey = await keyManager.mySenderKey(for: groupID)
        let payload = GroupKeyExchangePayload(
            groupID: groupID,
            senderKey: myKey,
            action: .distribute
        )
        let data = try JSONEncoder().encode(payload)

        for nodeID in memberNodeIDs {
            try? await transport?.send(data: data, to: nodeID)
        }
    }

    /// Handle receiving a key exchange message from another member.
    public func handleKeyExchange(_ data: Data) async throws {
        let payload = try JSONDecoder().decode(GroupKeyExchangePayload.self, from: data)

        switch payload.action {
        case .distribute:
            await keyManager.storeSenderKey(payload.senderKey, for: payload.groupID)

        case .rotate:
            await keyManager.storeSenderKey(payload.senderKey, for: payload.groupID)

        case .revoke:
            // Member left — we should rotate our own key
            let newKey = await keyManager.rotateSenderKey(for: payload.groupID)
            // Re-distribute our new key to remaining members
            // (The caller should provide updated member list)
            _ = newKey
        }
    }

    /// Rotate our key and redistribute (call when a member leaves).
    public func rotateAndRedistribute(groupID: UUID, remainingNodeIDs: [String]) async throws {
        let _ = await keyManager.rotateSenderKey(for: groupID)
        try await distributeMyKey(groupID: groupID, memberNodeIDs: remainingNodeIDs)
    }

    /// Send all our known keys to a new member joining the group.
    public func sendKeysToNewMember(groupID: UUID, newMemberNodeID: String) async throws {
        let keys = await keyManager.activeSenderKeys(for: groupID)
        for key in keys {
            let payload = GroupKeyExchangePayload(
                groupID: groupID,
                senderKey: key,
                action: .distribute
            )
            let data = try JSONEncoder().encode(payload)
            try? await transport?.send(data: data, to: newMemberNodeID)
        }
    }
}

// MARK: - Transport Protocol

/// Abstract transport for sending key exchange messages.
/// Implemented by ClusterKit/WANKit bridges.
public protocol GroupKeyTransport: Sendable {
    func send(data: Data, to nodeID: String) async throws
}

// MARK: - Key Exchange Payload

public struct GroupKeyExchangePayload: Codable, Sendable {
    public let groupID: UUID
    public let senderKey: SenderKey
    public let action: KeyExchangeAction

    public init(groupID: UUID, senderKey: SenderKey, action: KeyExchangeAction) {
        self.groupID = groupID
        self.senderKey = senderKey
        self.action = action
    }
}

public enum KeyExchangeAction: String, Codable, Sendable {
    case distribute  // New key or initial distribution
    case rotate      // Key rotation (old key expired)
    case revoke      // Member removed, all should rotate
}
