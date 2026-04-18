import Foundation

// MARK: - Conversation

public final class Conversation: Identifiable, ObservableObject, Hashable {
    public let id: UUID
    @Published public var title: String
    @Published public var createdAt: Date
    @Published public var updatedAt: Date
    @Published public var messages: [Message]

    public init(title: String = "New Chat") {
        self.id = UUID()
        self.title = title
        self.createdAt = Date()
        self.updatedAt = Date()
        self.messages = []
    }

    public init(from codable: CodableConversation) {
        self.id = codable.id
        self.title = codable.title
        self.createdAt = codable.createdAt
        self.updatedAt = codable.updatedAt
        self.messages = codable.messages.map { Message(from: $0) }
    }

    public func toCodable() -> CodableConversation {
        CodableConversation(
            id: id,
            title: title,
            createdAt: createdAt,
            updatedAt: updatedAt,
            messages: messages.map { $0.toCodable() }
        )
    }

    public static func == (lhs: Conversation, rhs: Conversation) -> Bool {
        lhs.id == rhs.id
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

// MARK: - Message

public final class Message: Identifiable, ObservableObject {
    public let id: UUID
    public var role: String
    public var content: String
    public var timestamp: Date

    public init(role: String, content: String) {
        self.id = UUID()
        self.role = role
        self.content = content
        self.timestamp = Date()
    }

    public init(from codable: CodableMessage) {
        self.id = codable.id
        self.role = codable.role
        self.content = codable.content
        self.timestamp = codable.timestamp
    }

    public func toCodable() -> CodableMessage {
        CodableMessage(id: id, role: role, content: content, timestamp: timestamp)
    }
}

// MARK: - Codable Bridge Types

public struct CodableConversation: Codable {
    public let id: UUID
    public var title: String
    public var createdAt: Date
    public var updatedAt: Date
    public var messages: [CodableMessage]
}

public struct CodableMessage: Codable {
    public let id: UUID
    public var role: String
    public var content: String
    public var timestamp: Date
}
