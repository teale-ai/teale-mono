import Foundation

// MARK: - Conversation Store (JSON file-backed)

@MainActor
@Observable
public final class ConversationStore {
    public private(set) var conversations: [Conversation] = []

    private var storageDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("InferencePool/conversations", isDirectory: true)
    }

    public init() {
        ensureDirectory()
        loadAll()
    }

    public func createConversation(title: String = "New Chat") -> Conversation {
        let conversation = Conversation(title: title)
        conversations.insert(conversation, at: 0)
        save(conversation)
        return conversation
    }

    public func deleteConversation(_ conversation: Conversation) {
        conversations.removeAll { $0.id == conversation.id }
        deleteFromDisk(conversation)
    }

    public func addMessage(to conversation: Conversation, role: String, content: String) -> Message {
        let message = Message(role: role, content: content)
        conversation.messages.append(message)
        conversation.updatedAt = Date()
        // Move to top
        if let index = conversations.firstIndex(where: { $0.id == conversation.id }) {
            let conv = conversations.remove(at: index)
            conversations.insert(conv, at: 0)
        }
        save(conversation)
        return message
    }

    // MARK: - File Persistence

    private func ensureDirectory() {
        try? FileManager.default.createDirectory(at: storageDirectory, withIntermediateDirectories: true)
    }

    private func loadAll() {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: storageDirectory,
            includingPropertiesForKeys: nil,
            options: .skipsHiddenFiles
        ) else { return }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        var loaded: [Conversation] = []
        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                  let codable = try? decoder.decode(CodableConversation.self, from: data) else {
                continue
            }
            loaded.append(Conversation(from: codable))
        }

        conversations = loaded.sorted { $0.updatedAt > $1.updatedAt }
    }

    private func save(_ conversation: Conversation) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        guard let data = try? encoder.encode(conversation.toCodable()) else { return }
        let filePath = storageDirectory.appendingPathComponent("conversation_\(conversation.id.uuidString).json")
        try? data.write(to: filePath, options: .atomic)
    }

    private func deleteFromDisk(_ conversation: Conversation) {
        let filePath = storageDirectory.appendingPathComponent("conversation_\(conversation.id.uuidString).json")
        try? FileManager.default.removeItem(at: filePath)
    }
}
