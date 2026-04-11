import Foundation
import Supabase
import Auth
import AuthKit
import SharedTypes

// MARK: - Chat Service

/// Main orchestrator for Supabase-backed conversations with AI agents.
/// Manages conversations, messages, participants, and realtime sync.
@MainActor
@Observable
public final class ChatService {
    // MARK: - State

    public private(set) var conversations: [Conversation] = []
    public private(set) var activeConversation: Conversation?
    public private(set) var activeMessages: [Message] = []
    public private(set) var activeParticipants: [ParticipantInfo] = []
    public private(set) var isLoadingConversations: Bool = false
    public private(set) var isLoadingMessages: Bool = false
    public private(set) var isSending: Bool = false

    // MARK: - Dependencies

    private let client: SupabaseClient
    private let currentUserID: UUID
    private let realtimeService: RealtimeService
    public let aiParticipant: AIParticipant
    public let invitationService: InvitationService

    // MARK: - Init

    public init(config: SupabaseConfig, currentUserID: UUID) {
        self.client = SupabaseClient(
            supabaseURL: config.url,
            supabaseKey: config.anonKey,
            options: SupabaseClientOptions(
                auth: .init(storage: ChatFileStorage())
            )
        )
        self.currentUserID = currentUserID
        self.realtimeService = RealtimeService(client: client)
        self.aiParticipant = AIParticipant()
        self.invitationService = InvitationService(client: client, currentUserID: currentUserID)
    }

    // MARK: - Conversation List

    /// Fetch all conversations the current user participates in
    public func loadConversations() async {
        isLoadingConversations = true
        defer { isLoadingConversations = false }

        do {
            let result: [Conversation] = try await client
                .from("conversations")
                .select()
                .order("last_message_at", ascending: false)
                .execute()
                .value

            conversations = result
        } catch {
            // Silently fail — conversations stay empty
        }
    }

    // MARK: - Open Conversation

    /// Open a conversation and subscribe to realtime updates
    public func openConversation(_ conversation: Conversation) async {
        activeConversation = conversation
        isLoadingMessages = true

        // Load messages
        do {
            let messages: [Message] = try await client
                .from("messages")
                .select()
                .eq("conversation_id", value: conversation.id.uuidString)
                .order("created_at", ascending: true)
                .limit(100)
                .execute()
                .value

            activeMessages = messages
        } catch {
            activeMessages = []
        }

        // Load participants with display names
        await loadParticipants(for: conversation.id)

        isLoadingMessages = false

        // Subscribe to new messages via realtime
        await realtimeService.subscribeToMessages(
            conversationID: conversation.id
        ) { [weak self] message in
            Task { @MainActor in
                guard let self, self.activeConversation?.id == message.conversationID else { return }
                // Append if not already present (avoid duplicates from own sends)
                if !self.activeMessages.contains(where: { $0.id == message.id }) {
                    self.activeMessages.append(message)
                }
            }
        }

        // Mark as read
        await markAsRead(conversation.id)
    }

    /// Close the current conversation and unsubscribe from realtime
    public func closeConversation() async {
        if let id = activeConversation?.id {
            await realtimeService.unsubscribeFromMessages(conversationID: id)
        }
        activeConversation = nil
        activeMessages = []
        activeParticipants = []
    }

    // MARK: - Send Message

    /// Send a text message in the active conversation
    public func sendMessage(_ content: String) async {
        guard let conversation = activeConversation else { return }
        guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        isSending = true
        defer { isSending = false }

        let message = Message(
            conversationID: conversation.id,
            senderID: currentUserID,
            content: content,
            messageType: .text
        )

        do {
            // Insert to Supabase — realtime will broadcast to other participants
            try await client
                .from("messages")
                .insert(message)
                .execute()

            // Optimistically add to local state
            if !activeMessages.contains(where: { $0.id == message.id }) {
                activeMessages.append(message)
            }

            // Update conversation list preview
            if let idx = conversations.firstIndex(where: { $0.id == conversation.id }) {
                conversations[idx].lastMessageAt = message.createdAt
                conversations[idx].lastMessagePreview = String(content.prefix(100))
            }
        } catch {
            // TODO: surface error to UI
        }
    }

    /// Insert an AI response message (called by AIParticipant after generation)
    public func insertAIMessage(_ content: String, conversationID: UUID) async {
        let message = Message(
            conversationID: conversationID,
            senderID: nil,
            content: content,
            messageType: .aiResponse
        )

        do {
            try await client
                .from("messages")
                .insert(message)
                .execute()

            if activeConversation?.id == conversationID {
                if !activeMessages.contains(where: { $0.id == message.id }) {
                    activeMessages.append(message)
                }
            }
        } catch {
            // AI message failed to persist
        }
    }

    // MARK: - Create Conversation

    /// Create a new DM with another user
    public func createDM(with otherUserID: UUID) async -> Conversation? {
        let conversation = Conversation(
            type: .dm,
            createdBy: currentUserID
        )

        do {
            try await client.from("conversations").insert(conversation).execute()

            // Add both participants
            let ownerParticipant = Participant(
                conversationID: conversation.id,
                userID: currentUserID,
                role: .owner
            )
            let otherParticipant = Participant(
                conversationID: conversation.id,
                userID: otherUserID,
                role: .member
            )
            try await client.from("conversation_participants")
                .insert([ownerParticipant, otherParticipant])
                .execute()

            conversations.insert(conversation, at: 0)
            return conversation
        } catch {
            return nil
        }
    }

    /// Create a new group conversation
    public func createGroup(title: String, memberIDs: [UUID]) async -> Conversation? {
        let conversation = Conversation(
            type: .group,
            title: title,
            createdBy: currentUserID
        )

        do {
            try await client.from("conversations").insert(conversation).execute()

            // Add owner + all members
            var participants = [Participant(
                conversationID: conversation.id,
                userID: currentUserID,
                role: .owner
            )]
            for memberID in memberIDs {
                participants.append(Participant(
                    conversationID: conversation.id,
                    userID: memberID,
                    role: .member
                ))
            }
            try await client.from("conversation_participants")
                .insert(participants)
                .execute()

            conversations.insert(conversation, at: 0)
            return conversation
        } catch {
            return nil
        }
    }

    // MARK: - Participant Management

    public func leaveConversation(_ conversationID: UUID) async {
        do {
            try await client.from("conversation_participants")
                .update(["is_active": false])
                .eq("conversation_id", value: conversationID.uuidString)
                .eq("user_id", value: currentUserID.uuidString)
                .execute()

            conversations.removeAll { $0.id == conversationID }
            if activeConversation?.id == conversationID {
                await closeConversation()
            }
        } catch {
            // Failed to leave
        }
    }

    // MARK: - Read Receipts

    public func markAsRead(_ conversationID: UUID) async {
        do {
            try await client.from("conversation_participants")
                .update(["last_read_at": ISO8601DateFormatter().string(from: Date())])
                .eq("conversation_id", value: conversationID.uuidString)
                .eq("user_id", value: currentUserID.uuidString)
                .execute()
        } catch {
            // Non-critical
        }
    }

    // MARK: - Private

    private func loadParticipants(for conversationID: UUID) async {
        do {
            let participants: [Participant] = try await client
                .from("conversation_participants")
                .select()
                .eq("conversation_id", value: conversationID.uuidString)
                .eq("is_active", value: true)
                .execute()
                .value

            // For now, use user ID as display name — profiles join comes later
            activeParticipants = participants.map { p in
                ParticipantInfo(
                    participant: p,
                    displayName: p.userID == currentUserID ? "You" : "User"
                )
            }
        } catch {
            activeParticipants = []
        }
    }

    // MARK: - Cleanup

    public func cleanup() async {
        await closeConversation()
        await realtimeService.removeAllSubscriptions()
    }
}

// MARK: - File-based auth storage for ChatKit's Supabase client

private struct ChatFileStorage: AuthLocalStorage, @unchecked Sendable {
    private let directory: URL

    init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        self.directory = appSupport.appendingPathComponent("Teale/chat-auth", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func store(key: String, value: Data) throws {
        let url = directory.appendingPathComponent(safeFileName(key))
        try value.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    func retrieve(key: String) throws -> Data? {
        let url = directory.appendingPathComponent(safeFileName(key))
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try Data(contentsOf: url)
    }

    func remove(key: String) throws {
        let url = directory.appendingPathComponent(safeFileName(key))
        try? FileManager.default.removeItem(at: url)
    }

    private func safeFileName(_ key: String) -> String {
        key.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? key
    }
}
