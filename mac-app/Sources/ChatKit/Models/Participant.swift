import Foundation

// MARK: - Participant Role

public enum ParticipantRole: String, Codable, Sendable {
    case owner
    case admin
    case member
}

// MARK: - Conversation Participant

public struct Participant: Codable, Sendable, Identifiable, Equatable {
    public var id: UUID
    public var conversationID: UUID
    public var userID: UUID
    public var role: ParticipantRole
    public var joinedAt: Date
    public var lastReadAt: Date?
    public var notificationsMuted: Bool
    public var isActive: Bool

    public init(
        id: UUID = UUID(),
        conversationID: UUID,
        userID: UUID,
        role: ParticipantRole = .member,
        joinedAt: Date = Date(),
        lastReadAt: Date? = nil,
        notificationsMuted: Bool = false,
        isActive: Bool = true
    ) {
        self.id = id
        self.conversationID = conversationID
        self.userID = userID
        self.role = role
        self.joinedAt = joinedAt
        self.lastReadAt = lastReadAt
        self.notificationsMuted = notificationsMuted
        self.isActive = isActive
    }

    /// Number of unread messages (compared against lastReadAt)
    public func unreadCount(lastMessageAt: Date?) -> Bool {
        guard let lastMessage = lastMessageAt else { return false }
        guard let lastRead = lastReadAt else { return true }
        return lastMessage > lastRead
    }

    enum CodingKeys: String, CodingKey {
        case id
        case conversationID = "conversation_id"
        case userID = "user_id"
        case role
        case joinedAt = "joined_at"
        case lastReadAt = "last_read_at"
        case notificationsMuted = "notifications_muted"
        case isActive = "is_active"
    }
}

// MARK: - Participant with Profile (joined view)

/// A participant enriched with display info from the profiles table
public struct ParticipantInfo: Sendable, Identifiable, Equatable {
    public var id: UUID { participant.id }
    public var participant: Participant
    public var displayName: String
    public var avatarURL: URL?

    public init(participant: Participant, displayName: String, avatarURL: URL? = nil) {
        self.participant = participant
        self.displayName = displayName
        self.avatarURL = avatarURL
    }
}
