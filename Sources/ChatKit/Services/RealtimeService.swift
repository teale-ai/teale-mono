import Foundation

// MARK: - P2P Message Listener

/// Replaces Supabase Realtime with a callback-based P2P message listener.
/// The transport layer (ClusterKit/WANKit) delivers incoming messages
/// and this service routes them to the appropriate handler.
public actor P2PMessageListener {
    private var messageHandlers: [UUID: @Sendable (StoredMessage) async -> Void] = [:]

    public init() {}

    /// Subscribe to messages for a specific conversation.
    public func subscribe(
        conversationID: UUID,
        handler: @escaping @Sendable (StoredMessage) async -> Void
    ) {
        messageHandlers[conversationID] = handler
    }

    /// Unsubscribe from a conversation.
    public func unsubscribe(conversationID: UUID) {
        messageHandlers.removeValue(forKey: conversationID)
    }

    /// Route an incoming message to the appropriate handler.
    public func deliver(_ message: StoredMessage) async {
        if let handler = messageHandlers[message.conversationID] {
            await handler(message)
        }
    }

    /// Remove all subscriptions.
    public func removeAllSubscriptions() {
        messageHandlers.removeAll()
    }
}
