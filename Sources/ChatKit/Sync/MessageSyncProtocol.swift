import Foundation

// MARK: - Message Sync Protocol

/// Vector clock-based catch-up sync for P2P group messaging.
///
/// Each device tracks `{nodeID: lastSeenTimestamp}` per group.
/// On peer connect, devices exchange clocks and the peer with newer
/// messages sends what the other is missing.
public actor MessageSyncService {
    private let messageStore: MessageStore
    private let outbox: MessageOutbox

    /// Vector clock per group: nodeID -> last seen message timestamp
    private var vectorClocks: [UUID: [String: Date]] = [:]

    private static let clockFile: URL = {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("Teale/groups/vector_clocks.json", isDirectory: true)
    }()

    public init(messageStore: MessageStore, outbox: MessageOutbox) {
        self.messageStore = messageStore
        self.outbox = outbox
        loadClocks()
    }

    // MARK: - Sync

    /// Get our vector clock for a group (to send to a peer).
    public func vectorClock(for groupID: UUID) -> [String: Date] {
        vectorClocks[groupID] ?? [:]
    }

    /// Process a peer's vector clock and return messages they're missing.
    public func messagesForPeer(
        groupID: UUID,
        peerClock: [String: Date]
    ) async -> [StoredMessage] {
        let allMessages = await messageStore.loadMessages(groupID: groupID)
        var missing: [StoredMessage] = []

        for message in allMessages {
            let peerLastSeen = peerClock[message.senderNodeID] ?? .distantPast
            if message.timestamp > peerLastSeen {
                missing.append(message)
            }
        }

        return missing.sorted { $0.timestamp < $1.timestamp }
    }

    /// Update our vector clock after receiving a message.
    public func recordMessage(groupID: UUID, senderNodeID: String, timestamp: Date) {
        var clock = vectorClocks[groupID] ?? [:]
        let existing = clock[senderNodeID] ?? .distantPast
        if timestamp > existing {
            clock[senderNodeID] = timestamp
            vectorClocks[groupID] = clock
            saveClocks()
        }
    }

    /// Flush outbox: get queued messages for a peer that just came online.
    public func pendingMessages(groupID: UUID, peerNodeID: String) async -> [StoredMessage] {
        await outbox.pending(groupID: groupID, peerNodeID: peerNodeID)
    }

    /// Clear outbox after successful delivery.
    public func confirmDelivery(groupID: UUID, peerNodeID: String) async {
        await outbox.clear(groupID: groupID, peerNodeID: peerNodeID)
    }

    // MARK: - Persistence

    private func saveClocks() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(vectorClocks) else { return }
        let dir = Self.clockFile.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? data.write(to: Self.clockFile, options: .atomic)
    }

    private func loadClocks() {
        guard let data = try? Data(contentsOf: Self.clockFile) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        vectorClocks = (try? decoder.decode([UUID: [String: Date]].self, from: data)) ?? [:]
    }
}

// MARK: - Sync Payloads (for ClusterMessage transport)

public struct GroupSyncRequestPayload: Codable, Sendable {
    public let groupID: UUID
    public let vectorClock: [String: Date]
    public let requestingNodeID: String

    public init(groupID: UUID, vectorClock: [String: Date], requestingNodeID: String) {
        self.groupID = groupID
        self.vectorClock = vectorClock
        self.requestingNodeID = requestingNodeID
    }
}

public struct GroupSyncResponsePayload: Codable, Sendable {
    public let groupID: UUID
    public let messages: [StoredMessage]

    public init(groupID: UUID, messages: [StoredMessage]) {
        self.groupID = groupID
        self.messages = messages
    }
}

public struct GroupMessagePayload: Codable, Sendable {
    public let message: StoredMessage

    public init(message: StoredMessage) {
        self.message = message
    }
}
