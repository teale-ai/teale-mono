import Foundation
import SharedTypes

// MARK: - Chat Service (P2P, zero central storage)

/// Orchestrates E2E encrypted group conversations over P2P transport.
/// All messages are stored locally and synced device-to-device.
/// No data ever touches a central server.
@MainActor
@Observable
public final class ChatService {
    // MARK: - State

    public private(set) var conversations: [Conversation] = []
    public private(set) var activeConversation: Conversation?
    public private(set) var activeMessages: [DecryptedMessage] = []
    public private(set) var activeParticipants: [ParticipantInfo] = []
    public private(set) var isLoadingMessages: Bool = false
    public private(set) var isSending: Bool = false

    // MARK: - Dependencies

    private let currentUserID: UUID
    private let localNodeID: String
    public let keyManager: GroupKeyManager
    public let messageStore: MessageStore
    public let outbox: MessageOutbox
    public let syncService: MessageSyncService
    public let configStore: GroupConfigStore
    public let aiParticipant: AIParticipant

    /// Callback to broadcast a message to connected group peers.
    /// Set by the app layer (wired to ClusterKit/WANKit transport).
    public var onBroadcast: ((_ data: Data, _ groupID: UUID) async -> Void)?

    // MARK: - Init

    public init(currentUserID: UUID, localNodeID: String) {
        self.currentUserID = currentUserID
        self.localNodeID = localNodeID
        self.keyManager = GroupKeyManager(memberID: currentUserID)
        self.messageStore = MessageStore()
        self.outbox = MessageOutbox()
        self.syncService = MessageSyncService(messageStore: messageStore, outbox: outbox)
        self.configStore = GroupConfigStore()
        self.aiParticipant = AIParticipant()
    }

    // MARK: - Conversation List

    /// Load conversations from local storage.
    public func loadConversations() async {
        // Conversations are stored as a simple JSON list locally
        let file = Self.conversationsFile
        guard let data = try? Data(contentsOf: file) else {
            conversations = []
            return
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        conversations = (try? decoder.decode([Conversation].self, from: data)) ?? []
    }

    /// Save conversations list to local storage.
    private func saveConversations() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(conversations) else { return }
        let dir = Self.conversationsFile.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? data.write(to: Self.conversationsFile, options: .atomic)
    }

    // MARK: - Open Conversation

    /// Open a conversation and load messages from local store.
    public func openConversation(_ conversation: Conversation) async {
        activeConversation = conversation
        isLoadingMessages = true

        // Load encrypted messages from local store
        let stored = await messageStore.loadMessages(groupID: conversation.id)
        activeMessages = await decryptMessages(stored, groupID: conversation.id)
        isLoadingMessages = false
    }

    /// Close the current conversation.
    public func closeConversation() {
        activeConversation = nil
        activeMessages = []
        activeParticipants = []
    }

    // MARK: - Send Message

    /// Encrypt, store locally, and broadcast a message to group peers.
    public func sendMessage(_ content: String) async {
        guard let conversation = activeConversation else { return }
        guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        isSending = true
        defer { isSending = false }

        do {
            var senderKey = await keyManager.mySenderKey(for: conversation.id)
            let payload = try GroupCrypto.encrypt(content, using: &senderKey)
            // Persist ratcheted key state
            await keyManager.storeSenderKey(senderKey, for: conversation.id)

            let stored = StoredMessage(
                conversationID: conversation.id,
                senderNodeID: localNodeID,
                senderID: currentUserID,
                payload: payload,
                messageType: .text
            )

            // Store locally
            await messageStore.append(stored, groupID: conversation.id)
            await syncService.recordMessage(
                groupID: conversation.id,
                senderNodeID: localNodeID,
                timestamp: stored.timestamp
            )

            // Broadcast to peers
            let data = try JSONEncoder().encode(GroupMessagePayload(message: stored))
            await onBroadcast?(data, conversation.id)

            // Add to active view
            let decrypted = DecryptedMessage(message: stored.toMessage(), content: content)
            if !activeMessages.contains(where: { $0.id == stored.id }) {
                activeMessages.append(decrypted)
            }

            // Update conversation preview
            if let idx = conversations.firstIndex(where: { $0.id == conversation.id }) {
                conversations[idx].lastMessageAt = stored.timestamp
                conversations[idx].lastMessagePreview = String(content.prefix(100))
                saveConversations()
            }
        } catch {
            // Encryption or broadcast failed
        }
    }

    /// Encrypt and broadcast an AI response.
    public func insertAIMessage(_ content: String, conversationID: UUID) async {
        do {
            var senderKey = await keyManager.mySenderKey(for: conversationID)
            let payload = try GroupCrypto.encrypt(content, using: &senderKey)
            await keyManager.storeSenderKey(senderKey, for: conversationID)

            let stored = StoredMessage(
                conversationID: conversationID,
                senderNodeID: localNodeID,
                senderID: nil,
                payload: payload,
                messageType: .aiResponse
            )

            await messageStore.append(stored, groupID: conversationID)
            let data = try JSONEncoder().encode(GroupMessagePayload(message: stored))
            await onBroadcast?(data, conversationID)

            if activeConversation?.id == conversationID {
                let decrypted = DecryptedMessage(message: stored.toMessage(), content: content)
                if !activeMessages.contains(where: { $0.id == stored.id }) {
                    activeMessages.append(decrypted)
                }
            }
        } catch {
            // AI message encryption failed
        }
    }

    // MARK: - Receive Message (from P2P transport)

    /// Handle an incoming encrypted message from a peer.
    public func receiveMessage(_ data: Data) async {
        guard let payload = try? JSONDecoder().decode(GroupMessagePayload.self, from: data) else { return }
        let message = payload.message

        // Dedup
        guard await !messageStore.hasMessage(id: message.id, groupID: message.conversationID) else { return }

        // Store locally
        await messageStore.append(message, groupID: message.conversationID)
        await syncService.recordMessage(
            groupID: message.conversationID,
            senderNodeID: message.senderNodeID,
            timestamp: message.timestamp
        )

        // Decrypt and display if this conversation is open
        if activeConversation?.id == message.conversationID {
            if let decrypted = await decryptMessage(message, groupID: message.conversationID) {
                activeMessages.append(decrypted)
            }
        }
    }

    // MARK: - Create Conversation

    /// Create a new group conversation (stored locally).
    public func createGroup(title: String, memberIDs: [UUID]) async -> Conversation? {
        let conversation = Conversation(
            type: .group,
            title: title,
            createdBy: currentUserID
        )
        conversations.insert(conversation, at: 0)
        saveConversations()
        return conversation
    }

    /// Create a DM conversation (stored locally).
    public func createDM(with otherUserID: UUID) async -> Conversation? {
        let conversation = Conversation(
            type: .dm,
            createdBy: currentUserID
        )
        conversations.insert(conversation, at: 0)
        saveConversations()
        return conversation
    }

    // MARK: - Leave

    public func leaveConversation(_ conversationID: UUID) async {
        await keyManager.removeKeys(for: conversationID)
        conversations.removeAll { $0.id == conversationID }
        saveConversations()
        if activeConversation?.id == conversationID {
            closeConversation()
        }
    }

    // MARK: - Decryption

    private func decryptMessages(_ messages: [StoredMessage], groupID: UUID) async -> [DecryptedMessage] {
        var result: [DecryptedMessage] = []
        for stored in messages {
            if let decrypted = await decryptMessage(stored, groupID: groupID) {
                result.append(decrypted)
            }
        }
        return result
    }

    private func decryptMessage(_ stored: StoredMessage, groupID: UUID) async -> DecryptedMessage? {
        guard var key = await keyManager.senderKey(for: groupID, keyID: stored.payload.keyID) else {
            let msg = stored.toMessage()
            return DecryptedMessage(message: msg, content: "[unable to decrypt — missing key]")
        }

        do {
            let content = try GroupCrypto.decrypt(stored.payload, using: &key)
            // Persist advanced ratchet state
            await keyManager.storeSenderKey(key, for: groupID)
            return DecryptedMessage(message: stored.toMessage(), content: content)
        } catch {
            let msg = stored.toMessage()
            return DecryptedMessage(message: msg, content: "[decryption failed]")
        }
    }

    // MARK: - Cleanup

    public func cleanup() {
        closeConversation()
    }

    // MARK: - Paths

    private static var conversationsFile: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("Teale/groups/conversations.json")
    }
}

// MARK: - StoredMessage → Message conversion

extension StoredMessage {
    /// Convert to a Message for display layer compatibility.
    public func toMessage() -> Message {
        Message(
            id: id,
            conversationID: conversationID,
            senderID: senderID,
            encryptedContent: "", // Not needed for display — DecryptedMessage has content
            encryptionKeyID: payload.keyID,
            messageType: messageType,
            createdAt: timestamp
        )
    }
}
