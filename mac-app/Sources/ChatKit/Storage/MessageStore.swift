import Foundation

// MARK: - Message Store

/// Append-only local message log per conversation.
/// Messages are stored as encrypted payloads in JSONL format (one JSON object per line).
/// No data ever leaves the device except via P2P encrypted transport.
public actor MessageStore {
    private let baseDir: URL

    private static let appDir: URL = {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("Teale/groups", isDirectory: true)
    }()

    public init() {
        self.baseDir = Self.appDir
    }

    // MARK: - Read

    /// Load all stored messages for a conversation.
    public func loadMessages(groupID: UUID) -> [StoredMessage] {
        let file = messagesFile(for: groupID)
        guard let data = try? Data(contentsOf: file),
              let text = String(data: data, encoding: .utf8) else {
            return []
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return text.split(separator: "\n").compactMap { line in
            guard let lineData = String(line).data(using: .utf8) else { return nil }
            return try? decoder.decode(StoredMessage.self, from: lineData)
        }
    }

    // MARK: - Write

    /// Append an encrypted message to the local log.
    public func append(_ message: StoredMessage, groupID: UUID) {
        let dir = groupDir(for: groupID)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard var data = try? encoder.encode(message) else { return }
        data.append(Data("\n".utf8))

        let file = messagesFile(for: groupID)
        if FileManager.default.fileExists(atPath: file.path) {
            if let handle = try? FileHandle(forWritingTo: file) {
                handle.seekToEndOfFile()
                handle.write(data)
                handle.closeFile()
            }
        } else {
            try? data.write(to: file, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        }
    }

    /// Check if a message ID already exists (dedup).
    public func hasMessage(id: UUID, groupID: UUID) -> Bool {
        loadMessages(groupID: groupID).contains { $0.id == id }
    }

    /// Delete the entire persisted message log for a conversation. Used for
    /// the demo conversation, which is ephemeral by design.
    public func clearMessages(groupID: UUID) {
        let file = messagesFile(for: groupID)
        try? FileManager.default.removeItem(at: file)
    }

    // MARK: - Sync Support

    /// Get messages newer than a given timestamp (for catch-up sync).
    public func messagesSince(_ date: Date, groupID: UUID) -> [StoredMessage] {
        loadMessages(groupID: groupID).filter { $0.timestamp > date }
    }

    // MARK: - Paths

    private func groupDir(for groupID: UUID) -> URL {
        baseDir.appendingPathComponent(groupID.uuidString, isDirectory: true)
    }

    private func messagesFile(for groupID: UUID) -> URL {
        groupDir(for: groupID).appendingPathComponent("messages.jsonl")
    }
}

// MARK: - Stored Message

/// An encrypted message as stored on disk. Contains only ciphertext — no plaintext ever hits disk.
public struct StoredMessage: Codable, Sendable, Identifiable {
    public let id: UUID
    public let conversationID: UUID
    public let senderNodeID: String
    public let senderID: UUID?
    public let payload: EncryptedPayload
    public let messageType: MessageType
    public let metadata: MessageMetadata?
    public let timestamp: Date

    public init(
        id: UUID = UUID(),
        conversationID: UUID,
        senderNodeID: String,
        senderID: UUID?,
        payload: EncryptedPayload,
        messageType: MessageType,
        metadata: MessageMetadata? = nil,
        timestamp: Date = Date()
    ) {
        self.id = id
        self.conversationID = conversationID
        self.senderNodeID = senderNodeID
        self.senderID = senderID
        self.payload = payload
        self.messageType = messageType
        self.metadata = metadata
        self.timestamp = timestamp
    }
}
