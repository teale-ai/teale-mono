import Foundation

// MARK: - Message Outbox

/// Per-peer queue of undelivered encrypted messages.
/// When a peer is offline, messages accumulate here and are flushed when they reconnect.
public actor MessageOutbox {
    private let baseDir: URL

    private static let appDir: URL = {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("Teale/groups", isDirectory: true)
    }()

    public init() {
        self.baseDir = Self.appDir
    }

    /// Queue a message for delivery to a specific peer.
    public func enqueue(_ message: StoredMessage, groupID: UUID, peerNodeID: String) {
        let dir = outboxDir(for: groupID)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard var data = try? encoder.encode(message) else { return }
        data.append(Data("\n".utf8))

        let file = peerFile(groupID: groupID, peerNodeID: peerNodeID)
        if FileManager.default.fileExists(atPath: file.path) {
            if let handle = try? FileHandle(forWritingTo: file) {
                handle.seekToEndOfFile()
                handle.write(data)
                handle.closeFile()
            }
        } else {
            try? data.write(to: file, options: .atomic)
        }
    }

    /// Get all queued messages for a peer (for flushing on reconnect).
    public func pending(groupID: UUID, peerNodeID: String) -> [StoredMessage] {
        let file = peerFile(groupID: groupID, peerNodeID: peerNodeID)
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

    /// Clear the outbox for a peer (after successful delivery).
    public func clear(groupID: UUID, peerNodeID: String) {
        let file = peerFile(groupID: groupID, peerNodeID: peerNodeID)
        try? FileManager.default.removeItem(at: file)
    }

    // MARK: - Paths

    private func outboxDir(for groupID: UUID) -> URL {
        baseDir
            .appendingPathComponent(groupID.uuidString, isDirectory: true)
            .appendingPathComponent("outbox", isDirectory: true)
    }

    private func peerFile(groupID: UUID, peerNodeID: String) -> URL {
        outboxDir(for: groupID).appendingPathComponent("\(peerNodeID).jsonl")
    }
}
