import Foundation

// MARK: - Memory Entry

/// A single piece of remembered context about a group conversation.
/// Examples: "Mom is allergic to shellfish", "Taylor's birthday is Aug 14",
/// "Trip to Tokyo in June 2026, budget $2000", "We meet every Sunday at 5pm".
public struct MemoryEntry: Codable, Sendable, Identifiable, Equatable {
    public let id: UUID
    public var text: String
    /// Optional semantic bucket so recall can filter: "preferences", "dates",
    /// "people", "plans", "facts". Free-form — the AI picks whatever seems useful.
    public var category: String?
    /// Optional pointer back to the message that prompted this memory.
    public var sourceMessageID: UUID?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        text: String,
        category: String? = nil,
        sourceMessageID: UUID? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.text = text
        self.category = category
        self.sourceMessageID = sourceMessageID
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

// MARK: - Group Memory

/// All persistent context accumulated for a single group conversation.
/// Stored per-device in Application Support, keyed by conversation ID.
public struct GroupMemory: Codable, Sendable, Equatable {
    public var conversationID: UUID
    public var entries: [MemoryEntry]

    public init(conversationID: UUID, entries: [MemoryEntry] = []) {
        self.conversationID = conversationID
        self.entries = entries
    }
}
