import Foundation

// MARK: - Group Memory Store

/// Device-local persistence for each group's accumulated memory.
/// File layout: `~/Library/Application Support/Teale/memory/{conversationID}.json`.
/// Not synced to peers yet — memories accumulate per-device as each participant's
/// AI learns from the conversations it sees.
@MainActor
@Observable
public final class GroupMemoryStore {
    private var memoriesByConversation: [UUID: GroupMemory] = [:]

    public init() {}

    // MARK: - Read

    public func memory(for conversationID: UUID) -> GroupMemory {
        if let cached = memoriesByConversation[conversationID] {
            return cached
        }
        let loaded = load(conversationID: conversationID) ?? GroupMemory(conversationID: conversationID)
        memoriesByConversation[conversationID] = loaded
        return loaded
    }

    public func entries(for conversationID: UUID) -> [MemoryEntry] {
        memory(for: conversationID).entries
    }

    // MARK: - Write

    @discardableResult
    public func add(
        _ text: String,
        category: String? = nil,
        sourceMessageID: UUID? = nil,
        to conversationID: UUID
    ) -> MemoryEntry {
        var mem = memory(for: conversationID)
        let entry = MemoryEntry(
            text: text,
            category: category,
            sourceMessageID: sourceMessageID
        )
        mem.entries.append(entry)
        memoriesByConversation[conversationID] = mem
        save(mem)
        return entry
    }

    public func remove(id: UUID, from conversationID: UUID) {
        var mem = memory(for: conversationID)
        mem.entries.removeAll { $0.id == id }
        memoriesByConversation[conversationID] = mem
        save(mem)
    }

    public func clear(conversationID: UUID) {
        var mem = memory(for: conversationID)
        mem.entries.removeAll()
        memoriesByConversation[conversationID] = mem
        save(mem)
    }

    // MARK: - Search

    /// Case-insensitive substring match over entry text.
    public func search(_ query: String, in conversationID: UUID, limit: Int = 20) -> [MemoryEntry] {
        let q = query.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return Array(memory(for: conversationID).entries.suffix(limit)) }
        return memory(for: conversationID).entries
            .filter { $0.text.lowercased().contains(q) }
            .suffix(limit)
            .map { $0 }
    }

    // MARK: - Persistence

    private static let directory: URL = {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return support.appendingPathComponent("Teale/memory", isDirectory: true)
    }()

    private func fileURL(for conversationID: UUID) -> URL {
        Self.directory.appendingPathComponent("\(conversationID.uuidString).json")
    }

    private func load(conversationID: UUID) -> GroupMemory? {
        let url = fileURL(for: conversationID)
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(GroupMemory.self, from: data)
    }

    private func save(_ memory: GroupMemory) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        guard let data = try? encoder.encode(memory) else { return }
        try? data.write(to: fileURL(for: memory.conversationID), options: .atomic)
    }
}
