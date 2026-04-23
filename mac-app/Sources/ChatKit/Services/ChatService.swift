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

    public let currentUserID: UUID
    private let localNodeID: String
    public let keyManager: GroupKeyManager
    public let messageStore: MessageStore
    public let outbox: MessageOutbox
    public let syncService: MessageSyncService
    public let configStore: GroupConfigStore
    public let aiParticipant: AIParticipant
    public let memoryStore: GroupMemoryStore
    public let preferenceStore: UserPreferenceStore
    public let walletStore: GroupWalletStore

    /// Callback fired when a personal-wallet debit is needed to fund a group
    /// wallet contribution. Wired by the app layer to the USDC wallet.
    /// Return `true` iff the debit succeeded.
    public var onPersonalWalletDebit: ((_ amount: Double, _ conversationID: UUID, _ memo: String) async -> Bool)?

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
        self.memoryStore = GroupMemoryStore()
        self.preferenceStore = UserPreferenceStore()
        self.walletStore = GroupWalletStore()
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

        // Replay any `.walletEntry` messages into the wallet store — dedups by
        // entry.id, so this is safe to run on every open.
        for msg in activeMessages where msg.messageType == .walletEntry {
            if let data = msg.content.data(using: .utf8),
               let entry = try? JSONDecoder().decode(WalletLedgerEntry.self, from: data) {
                walletStore.append(entry)
            }
        }
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
                conversations[idx].updatedAt = stored.timestamp
                conversations[idx].lastMessageAt = stored.timestamp
                conversations[idx].lastMessagePreview = String(content.prefix(100))
                if activeConversation?.id == conversation.id {
                    activeConversation = conversations[idx]
                }
                saveConversations()
            }
        } catch {
            // Encryption or broadcast failed
        }
    }

    // MARK: - Group Wallet

    /// Contribute to the group wallet — debits the local user's personal wallet,
    /// then appends an encrypted `.walletEntry` to the group's ledger.
    public func contributeToGroupWallet(
        amount: Double,
        conversationID: UUID,
        memo: String? = nil
    ) async -> Bool {
        guard amount > 0 else { return false }
        let debitMemo = memo ?? "Group wallet contribution"
        if let onPersonalWalletDebit,
           await !onPersonalWalletDebit(amount, conversationID, debitMemo) {
            return false
        }

        let entry = WalletLedgerEntry(
            conversationID: conversationID,
            authorID: currentUserID,
            kind: .contribution,
            amount: amount,
            memo: memo
        )
        await broadcastWalletEntry(entry)
        return true
    }

    /// Debit the group wallet to pay for something (typically an inference node).
    /// Caller is responsible for enforcing `GroupWalletPolicy.autoApproveDebitLimit`
    /// before calling this.
    public func debitGroupWallet(
        amount: Double,
        conversationID: UUID,
        memo: String? = nil,
        payeeNodeID: String? = nil,
        modelID: String? = nil,
        tokenCount: Int? = nil
    ) async {
        guard amount > 0 else { return }
        let entry = WalletLedgerEntry(
            conversationID: conversationID,
            authorID: currentUserID,
            kind: .debit,
            amount: amount,
            memo: memo,
            payeeNodeID: payeeNodeID,
            modelID: modelID,
            tokenCount: tokenCount
        )
        await broadcastWalletEntry(entry)
    }

    /// Encrypt and broadcast a ledger entry on the group's P2P channel.
    private func broadcastWalletEntry(_ entry: WalletLedgerEntry) async {
        // Apply locally first so the UI reflects it immediately.
        walletStore.append(entry)

        guard let data = try? JSONEncoder().encode(entry),
              let content = String(data: data, encoding: .utf8) else {
            return
        }
        await insertAgentMessage(
            content: content,
            messageType: .walletEntry,
            conversationID: entry.conversationID
        )
    }

    /// Encrypt and broadcast a tool-call message originating from the AI.
    /// Content is JSON-encoded so remote participants can re-render it.
    public func insertToolCall(_ call: ToolCall, conversationID: UUID) async {
        let data = (try? JSONEncoder().encode(call)) ?? Data()
        let content = String(data: data, encoding: .utf8) ?? "{}"
        await insertAgentMessage(content: content, messageType: .toolCall, conversationID: conversationID)
    }

    /// Encrypt and broadcast a tool-result message originating from the AI.
    public func insertToolResult(_ outcome: ToolOutcome, conversationID: UUID) async {
        let data = (try? JSONEncoder().encode(outcome)) ?? Data()
        let content = String(data: data, encoding: .utf8) ?? "{}"
        await insertAgentMessage(content: content, messageType: .toolResult, conversationID: conversationID)
    }

    /// Shared encryption + broadcast path for agent-originated messages.
    private func insertAgentMessage(
        content: String,
        messageType: MessageType,
        conversationID: UUID
    ) async {
        do {
            var senderKey = await keyManager.mySenderKey(for: conversationID)
            let payload = try GroupCrypto.encrypt(content, using: &senderKey)
            await keyManager.storeSenderKey(senderKey, for: conversationID)

            let stored = StoredMessage(
                conversationID: conversationID,
                senderNodeID: localNodeID,
                senderID: nil,
                payload: payload,
                messageType: messageType
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
            // Agent message encryption/broadcast failed — swallow silently.
        }
    }

    /// Insert a message into the *in-memory* active UI only — never persisted,
    /// never broadcast. Used by the scripted reservation demo so the
    /// conversation replays cleanly every time instead of accumulating a
    /// growing log of unrecoverable "missing key" stubs.
    public func insertDemoMessage(
        text: String,
        senderID: UUID?,
        messageType: MessageType,
        conversationID: UUID
    ) async {
        guard activeConversation?.id == conversationID else { return }
        // Construct a Message purely for display — no StoredMessage, no disk.
        let message = Message(
            id: UUID(),
            conversationID: conversationID,
            senderID: senderID,
            encryptedContent: "",
            encryptionKeyID: "demo",
            messageType: messageType,
            createdAt: Date()
        )
        let decrypted = DecryptedMessage(message: message, content: text)
        activeMessages.append(decrypted)
    }

    /// Wipe the persisted log + in-memory messages for a conversation (demo reset).
    public func resetConversationMessages(conversationID: UUID) async {
        await messageStore.clearMessages(groupID: conversationID)
        if activeConversation?.id == conversationID {
            activeMessages = []
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

            if let idx = conversations.firstIndex(where: { $0.id == conversationID }) {
                conversations[idx].updatedAt = stored.timestamp
                conversations[idx].lastMessageAt = stored.timestamp
                conversations[idx].lastMessagePreview = String(content.prefix(100))
                if activeConversation?.id == conversationID {
                    activeConversation = conversations[idx]
                }
                saveConversations()
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
                if decrypted.messageType == .walletEntry,
                   let data = decrypted.content.data(using: .utf8),
                   let entry = try? JSONDecoder().decode(WalletLedgerEntry.self, from: data) {
                    walletStore.append(entry)
                }
            }
        } else if message.messageType == .walletEntry,
                  let decrypted = await decryptMessage(message, groupID: message.conversationID),
                  let data = decrypted.content.data(using: .utf8),
                  let entry = try? JSONDecoder().decode(WalletLedgerEntry.self, from: data) {
            // Wallet entries must replicate into the store even when the
            // conversation isn't currently open in the UI.
            walletStore.append(entry)
        }

        if let idx = conversations.firstIndex(where: { $0.id == message.conversationID }) {
            conversations[idx].updatedAt = message.timestamp
            conversations[idx].lastMessageAt = message.timestamp
            if let decrypted = await decryptMessage(message, groupID: message.conversationID) {
                conversations[idx].lastMessagePreview = String(decrypted.content.prefix(100))
            }
            if activeConversation?.id == message.conversationID {
                activeConversation = conversations[idx]
            }
            saveConversations()
        }
    }

    // MARK: - Create Conversation

    /// Create a new group conversation (stored locally).
    public func createGroup(
        title: String,
        memberIDs: [UUID],
        agentConfig: AgentConfig = .default
    ) async -> Conversation? {
        let conversation = Conversation(
            type: .group,
            title: title,
            createdBy: currentUserID,
            agentConfig: agentConfig
        )
        conversations.insert(conversation, at: 0)
        saveConversations()
        return conversation
    }

    /// Create a DM conversation (stored locally).
    public func createDM(
        with otherUserID: UUID,
        title: String? = nil,
        agentConfig: AgentConfig = .default
    ) async -> Conversation? {
        let conversation = Conversation(
            type: .dm,
            title: title,
            createdBy: currentUserID,
            agentConfig: agentConfig
        )
        conversations.insert(conversation, at: 0)
        saveConversations()
        return conversation
    }

    // MARK: - Update

    /// Update a conversation's title, agent config, and optional heartbeat flag.
    public func updateConversation(
        id: UUID,
        title: String?,
        agentConfig: AgentConfig,
        heartbeatsEnabled: Bool? = nil
    ) async {
        guard let idx = conversations.firstIndex(where: { $0.id == id }) else { return }
        conversations[idx].title = title
        conversations[idx].agentConfig = agentConfig
        if let heartbeatsEnabled {
            conversations[idx].heartbeatsEnabled = heartbeatsEnabled
        }
        conversations[idx].updatedAt = Date()
        if activeConversation?.id == id {
            activeConversation = conversations[idx]
        }
        saveConversations()
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

// MARK: - Group Intelligence Context Conformance

extension ChatService: GroupIntelligenceContext {
    public var activeConversationID: UUID? {
        activeConversation?.id
    }

    public var activeMessageContents: [(id: UUID, content: String, senderName: String?, isFromAgent: Bool, createdAt: Date)] {
        activeMessages.compactMap { msg in
            // Only text and AI responses are worth searching — tool call/result
            // payloads are structured JSON noise from the user's perspective.
            guard msg.messageType == .text || msg.messageType == .aiResponse else { return nil }
            let senderName = activeParticipants.first { $0.participant.userID == msg.senderID }?.displayName
            return (
                id: msg.id,
                content: msg.content,
                senderName: senderName,
                isFromAgent: msg.isFromAgent,
                createdAt: msg.createdAt
            )
        }
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
