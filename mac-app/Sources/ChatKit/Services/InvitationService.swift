import Foundation

// MARK: - Invitation Service (P2P)

/// Manages group invitations via P2P key exchange.
/// Invitations are shared as encoded tokens containing group info + sender key.
public final class InvitationService: Sendable {
    private let currentUserID: UUID

    public init(currentUserID: UUID) {
        self.currentUserID = currentUserID
    }

    /// Create an invitation token for a group.
    public func createInvitation(groupID: UUID, groupTitle: String) -> GroupInvitation {
        GroupInvitation(
            id: UUID(),
            groupID: groupID,
            groupTitle: groupTitle,
            inviterID: currentUserID,
            createdAt: Date()
        )
    }

    /// Encode an invitation to a shareable string.
    public func encode(_ invitation: GroupInvitation) -> String? {
        guard let data = try? JSONEncoder().encode(invitation) else { return nil }
        return data.base64EncodedString()
    }

    /// Decode an invitation from a shared string.
    public func decode(_ token: String) -> GroupInvitation? {
        guard let data = Data(base64Encoded: token) else { return nil }
        return try? JSONDecoder().decode(GroupInvitation.self, from: data)
    }
}

/// A group invitation token shared between peers.
public struct GroupInvitation: Codable, Sendable {
    public let id: UUID
    public let groupID: UUID
    public let groupTitle: String
    public let inviterID: UUID
    public let createdAt: Date
}
