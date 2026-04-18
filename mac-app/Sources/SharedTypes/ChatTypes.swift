import Foundation

// MARK: - Chat Role

public enum ChatRole: String, Codable, Sendable {
    case system
    case user
    case assistant
}

// MARK: - Chat Message

public struct ChatMessage: Codable, Sendable, Identifiable {
    public var id: UUID
    public var role: ChatRole
    public var content: String
    public var timestamp: Date

    public init(id: UUID = UUID(), role: ChatRole, content: String, timestamp: Date = Date()) {
        self.id = id
        self.role = role
        self.content = content
        self.timestamp = timestamp
    }
}

// MARK: - Conversation

public struct ConversationInfo: Codable, Sendable, Identifiable {
    public var id: UUID
    public var title: String
    public var createdAt: Date
    public var updatedAt: Date
    public var messageCount: Int

    public init(id: UUID = UUID(), title: String, createdAt: Date = Date(), updatedAt: Date = Date(), messageCount: Int = 0) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.messageCount = messageCount
    }
}
