import Foundation
import Supabase
import Realtime

// MARK: - Realtime Service

/// Manages Supabase Realtime channel subscriptions for live message delivery.
public actor RealtimeService {
    private let client: SupabaseClient
    private var messageChannels: [UUID: RealtimeChannelV2] = [:]

    init(client: SupabaseClient) {
        self.client = client
    }

    // MARK: - Message Subscriptions

    /// Subscribe to new messages in a conversation
    func subscribeToMessages(
        conversationID: UUID,
        onMessage: @escaping @Sendable (Message) -> Void
    ) async {
        // Remove existing subscription if any
        await unsubscribeFromMessages(conversationID: conversationID)

        let channel = client.realtimeV2.channel("messages:\(conversationID.uuidString)")

        let changes = channel.postgresChange(
            InsertAction.self,
            schema: "public",
            table: "messages",
            filter: "conversation_id=eq.\(conversationID.uuidString)"
        )

        await channel.subscribe()

        messageChannels[conversationID] = channel

        // Listen for inserts in background
        Task {
            for await insert in changes {
                do {
                    let message = try insert.decodeRecord(as: Message.self, decoder: JSONDecoder.supabaseDecoder)
                    onMessage(message)
                } catch {
                    // Failed to decode message — skip
                }
            }
        }
    }

    /// Unsubscribe from a conversation's messages
    func unsubscribeFromMessages(conversationID: UUID) async {
        if let channel = messageChannels.removeValue(forKey: conversationID) {
            await channel.unsubscribe()
        }
    }

    /// Remove all subscriptions
    func removeAllSubscriptions() async {
        for (_, channel) in messageChannels {
            await channel.unsubscribe()
        }
        messageChannels.removeAll()
    }
}

// MARK: - JSON Decoder for Supabase

private extension JSONDecoder {
    static let supabaseDecoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
