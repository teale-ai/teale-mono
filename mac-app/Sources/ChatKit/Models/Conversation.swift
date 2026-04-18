import Foundation

// MARK: - Conversation Type

public enum ConversationType: String, Codable, Sendable {
    case dm
    case group
}

// MARK: - Agent Config

/// Per-conversation AI agent configuration
public struct AgentConfig: Codable, Sendable, Equatable {
    /// Preferred model ID for inference in this conversation
    public var model: String?
    /// Custom system prompt for the agent
    public var systemPrompt: String?
    /// Respond to every message (vs only when @mentioned)
    public var autoRespond: Bool
    /// Only respond when explicitly @mentioned
    public var mentionOnly: Bool
    /// Agent persona label (e.g. "assistant", "trip-planner")
    public var persona: String?

    public init(
        model: String? = nil,
        systemPrompt: String? = nil,
        autoRespond: Bool = false,
        mentionOnly: Bool = true,
        persona: String? = nil
    ) {
        self.model = model
        self.systemPrompt = systemPrompt
        self.autoRespond = autoRespond
        self.mentionOnly = mentionOnly
        self.persona = persona
    }

    public static let `default` = AgentConfig()
}

// MARK: - Conversation

public struct Conversation: Codable, Sendable, Identifiable, Equatable {
    public var id: UUID
    public var type: ConversationType
    public var title: String?
    public var createdBy: UUID
    public var agentConfig: AgentConfig
    public var createdAt: Date
    public var updatedAt: Date
    public var lastMessageAt: Date?
    public var lastMessagePreview: String?
    public var isArchived: Bool
    /// Key rotation epoch — incremented when a member leaves and keys rotate.
    public var groupKeyVersion: Int

    public init(
        id: UUID = UUID(),
        type: ConversationType,
        title: String? = nil,
        createdBy: UUID,
        agentConfig: AgentConfig = .default,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        lastMessageAt: Date? = nil,
        lastMessagePreview: String? = nil,
        isArchived: Bool = false,
        groupKeyVersion: Int = 1
    ) {
        self.id = id
        self.type = type
        self.title = title
        self.createdBy = createdBy
        self.agentConfig = agentConfig
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.lastMessageAt = lastMessageAt
        self.lastMessagePreview = lastMessagePreview
        self.isArchived = isArchived
        self.groupKeyVersion = groupKeyVersion
    }

    /// Display title — for DMs, derive from the other participant's name
    public func displayTitle(otherParticipantName: String? = nil) -> String {
        if let title, !title.isEmpty { return title }
        if type == .dm, let name = otherParticipantName { return name }
        return "New Conversation"
    }

    // MARK: - Supabase Column Mapping

    enum CodingKeys: String, CodingKey {
        case id
        case type
        case title
        case createdBy = "created_by"
        case agentConfig = "agent_config"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case lastMessageAt = "last_message_at"
        case lastMessagePreview = "last_message_preview"
        case isArchived = "is_archived"
        case groupKeyVersion = "group_key_version"
    }
}
