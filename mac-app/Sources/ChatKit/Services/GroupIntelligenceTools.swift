import Foundation

// MARK: - Context Provider

/// The orchestrator's view onto the currently-active conversation — lets tool
/// handlers resolve which group memory / messages to operate on without the
/// orchestrator having to thread conversation IDs through every call.
@MainActor
public protocol GroupIntelligenceContext: AnyObject {
    var activeConversationID: UUID? { get }
    /// Plain-text contents of the active conversation's text and AI messages
    /// in order. Used by the history-search tool.
    var activeMessageContents: [(id: UUID, content: String, senderName: String?, isFromAgent: Bool, createdAt: Date)] { get }
}

// MARK: - Group Memory Tools

public final class RememberTool: ToolHandler {
    public let schema = ToolSchema(
        name: "remember",
        description: "Write a durable fact about this group (preferences, dates, plans, running context) into group memory so you can recall it later.",
        parametersJSON: #"{"text":"string (the fact to remember)","category":"string (optional: preferences|dates|people|plans|facts)"}"#
    )

    private let memoryStore: GroupMemoryStore
    private weak var context: (any GroupIntelligenceContext)?

    public init(memoryStore: GroupMemoryStore, context: any GroupIntelligenceContext) {
        self.memoryStore = memoryStore
        self.context = context
    }

    public func run(params: [String: String]) async throws -> String {
        guard let text = params["text"]?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            throw NSError(domain: "ChatKit.Tools", code: 1, userInfo: [NSLocalizedDescriptionKey: "`text` is required"])
        }
        let memoryStore = self.memoryStore
        let context = self.context
        let category = params["category"]
        return await MainActor.run {
            guard let conversationID = context?.activeConversationID else {
                return "No active conversation."
            }
            let entry = memoryStore.add(text, category: category, to: conversationID)
            return "Remembered: \"\(entry.text)\""
        }
    }
}

public final class RecallTool: ToolHandler {
    public let schema = ToolSchema(
        name: "recall",
        description: "Search the group's accumulated memory for relevant context. Pass a query to filter, or omit it to get the most recent entries.",
        parametersJSON: #"{"query":"string (optional)","limit":"integer (optional, default 10)"}"#
    )

    private let memoryStore: GroupMemoryStore
    private weak var context: (any GroupIntelligenceContext)?

    public init(memoryStore: GroupMemoryStore, context: any GroupIntelligenceContext) {
        self.memoryStore = memoryStore
        self.context = context
    }

    public func run(params: [String: String]) async throws -> String {
        let memoryStore = self.memoryStore
        let context = self.context
        let limit = Int(params["limit"] ?? "10") ?? 10
        let query = params["query"] ?? ""
        return await MainActor.run {
            guard let conversationID = context?.activeConversationID else {
                return "No active conversation."
            }
            let hits = memoryStore.search(query, in: conversationID, limit: max(1, min(50, limit)))
            if hits.isEmpty { return "No matching memory entries." }
            return hits.map { "• \($0.text)" + ($0.category.map { " [\($0)]" } ?? "") }.joined(separator: "\n")
        }
    }
}

// MARK: - Message History Search

public final class SearchHistoryTool: ToolHandler {
    public let schema = ToolSchema(
        name: "search_history",
        description: "Search the current group's past messages by substring. Useful for 'what did we decide about X' / 'when did we talk about Y'.",
        parametersJSON: #"{"query":"string (required)","limit":"integer (optional, default 10)"}"#
    )

    private weak var context: (any GroupIntelligenceContext)?

    public init(context: any GroupIntelligenceContext) {
        self.context = context
    }

    public func run(params: [String: String]) async throws -> String {
        guard let query = params["query"]?.lowercased().trimmingCharacters(in: .whitespacesAndNewlines), !query.isEmpty else {
            throw NSError(domain: "ChatKit.Tools", code: 1, userInfo: [NSLocalizedDescriptionKey: "`query` is required"])
        }
        let context = self.context
        let limit = max(1, min(30, Int(params["limit"] ?? "10") ?? 10))
        return await MainActor.run {
            guard let context else { return "No active conversation." }
            let hits = context.activeMessageContents
                .filter { $0.content.lowercased().contains(query) }
                .suffix(limit)
            if hits.isEmpty { return "No messages matching \"\(query)\"." }

            let formatter = DateFormatter()
            formatter.dateStyle = .short
            formatter.timeStyle = .short
            return hits.map { entry in
                let sender = entry.isFromAgent ? "Teale" : (entry.senderName ?? "User")
                return "[\(formatter.string(from: entry.createdAt))] \(sender): \(entry.content)"
            }.joined(separator: "\n")
        }
    }
}

// MARK: - Per-Device User Preferences

public final class SetPreferenceTool: ToolHandler {
    public let schema = ToolSchema(
        name: "set_my_preference",
        description: "Record a personal preference for the local user (dietary, scheduling, communication style, etc.). Stored only on this device.",
        parametersJSON: #"{"key":"string (e.g. diet, timezone, pronouns)","value":"string"}"#
    )

    private let preferenceStore: UserPreferenceStore

    public init(preferenceStore: UserPreferenceStore) {
        self.preferenceStore = preferenceStore
    }

    public func run(params: [String: String]) async throws -> String {
        guard let key = params["key"]?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty,
              let value = params["value"]?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            throw NSError(domain: "ChatKit.Tools", code: 1, userInfo: [NSLocalizedDescriptionKey: "Both `key` and `value` are required"])
        }
        let preferenceStore = self.preferenceStore
        return await MainActor.run {
            let entry = preferenceStore.setPreference(key: key, value: value)
            return "Saved preference: \(entry.key) = \(entry.value)"
        }
    }
}

public final class GetPreferencesTool: ToolHandler {
    public let schema = ToolSchema(
        name: "get_my_preferences",
        description: "Read the local user's recorded preferences. Pass an optional topic to filter, or omit to list everything.",
        parametersJSON: #"{"topic":"string (optional)"}"#
    )

    private let preferenceStore: UserPreferenceStore

    public init(preferenceStore: UserPreferenceStore) {
        self.preferenceStore = preferenceStore
    }

    public func run(params: [String: String]) async throws -> String {
        let preferenceStore = self.preferenceStore
        let topic = params["topic"]
        return await MainActor.run {
            let hits = preferenceStore.lookup(topic)
            if hits.isEmpty { return "No preferences recorded on this device." }
            return hits.map { "• \($0.key): \($0.value)" }.joined(separator: "\n")
        }
    }
}
