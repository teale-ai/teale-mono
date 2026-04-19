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
    /// When true, the heartbeat scheduler is allowed to post proactive nudges
    /// (upcoming dates, stale plans, unanswered questions) to this conversation.
    public var heartbeatsEnabled: Bool

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
        groupKeyVersion: Int = 1,
        heartbeatsEnabled: Bool = false
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
        self.heartbeatsEnabled = heartbeatsEnabled
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
        case heartbeatsEnabled = "heartbeats_enabled"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(UUID.self, forKey: .id)
        self.type = try container.decode(ConversationType.self, forKey: .type)
        self.title = try container.decodeIfPresent(String.self, forKey: .title)
        self.createdBy = try container.decode(UUID.self, forKey: .createdBy)
        self.agentConfig = try container.decodeIfPresent(AgentConfig.self, forKey: .agentConfig) ?? .default
        self.createdAt = try container.decode(Date.self, forKey: .createdAt)
        self.updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        self.lastMessageAt = try container.decodeIfPresent(Date.self, forKey: .lastMessageAt)
        self.lastMessagePreview = try container.decodeIfPresent(String.self, forKey: .lastMessagePreview)
        self.isArchived = try container.decodeIfPresent(Bool.self, forKey: .isArchived) ?? false
        self.groupKeyVersion = try container.decodeIfPresent(Int.self, forKey: .groupKeyVersion) ?? 1
        // Older persisted conversations won't have this key — default to false.
        self.heartbeatsEnabled = try container.decodeIfPresent(Bool.self, forKey: .heartbeatsEnabled) ?? false
    }
}
