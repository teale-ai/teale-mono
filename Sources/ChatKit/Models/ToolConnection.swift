import Foundation

// MARK: - Tool Type

public enum ToolType: String, Codable, Sendable {
    case calendar
    case email
    case contacts
    case reminders
    case notes
    case custom
}

// MARK: - Tool Provider

public enum ToolProvider: String, Codable, Sendable {
    case appleCalendar = "apple_calendar"
    case googleCalendar = "google_calendar"
    case outlook
    case appleMail = "apple_mail"
    case gmail
    case appleContacts = "apple_contacts"
    case appleReminders = "apple_reminders"
    case appleNotes = "apple_notes"
    case custom
}

// MARK: - Tool Scope

public enum ToolScope: String, Codable, Sendable {
    case read
    case create
    case update
    case delete
}

// MARK: - Tool Connection

public struct ToolConnection: Codable, Sendable, Identifiable, Equatable {
    public var id: UUID
    public var userID: UUID
    /// nil = available to all user's chats
    public var conversationID: UUID?
    public var toolType: ToolType
    public var provider: ToolProvider
    public var scopes: [ToolScope]
    public var isActive: Bool
    public var connectedAt: Date
    public var lastUsedAt: Date?

    public init(
        id: UUID = UUID(),
        userID: UUID,
        conversationID: UUID? = nil,
        toolType: ToolType,
        provider: ToolProvider,
        scopes: [ToolScope] = [.read],
        isActive: Bool = true,
        connectedAt: Date = Date(),
        lastUsedAt: Date? = nil
    ) {
        self.id = id
        self.userID = userID
        self.conversationID = conversationID
        self.toolType = toolType
        self.provider = provider
        self.scopes = scopes
        self.isActive = isActive
        self.connectedAt = connectedAt
        self.lastUsedAt = lastUsedAt
    }

    enum CodingKeys: String, CodingKey {
        case id
        case userID = "user_id"
        case conversationID = "conversation_id"
        case toolType = "tool_type"
        case provider
        case scopes
        case isActive = "is_active"
        case connectedAt = "connected_at"
        case lastUsedAt = "last_used_at"
    }
}

// MARK: - Conversation Tool Summary (for AI context building)

/// Aggregated view of tools available in a conversation (no credentials exposed)
public struct ConversationToolSummary: Sendable, Equatable {
    public var toolType: ToolType
    public var provider: ToolProvider
    public var scopes: [ToolScope]
    public var ownerDisplayName: String

    public init(toolType: ToolType, provider: ToolProvider, scopes: [ToolScope], ownerDisplayName: String) {
        self.toolType = toolType
        self.provider = provider
        self.scopes = scopes
        self.ownerDisplayName = ownerDisplayName
    }

    /// Human-readable description for the AI system prompt
    public var promptDescription: String {
        let scopeList = scopes.map(\.rawValue).joined(separator: ", ")
        return "\(toolType.rawValue) (\(provider.rawValue)) — \(scopeList) — owned by \(ownerDisplayName)"
    }
}
