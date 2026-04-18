import Foundation
import SharedTypes
import Observation

// MARK: - Companion Message

struct CompanionMessage: Identifiable {
    var id: UUID = UUID()
    var role: ChatRole
    var content: String
    var timestamp: Date = Date()
}

// MARK: - Companion Conversation

struct CompanionConversation: Identifiable {
    var id: UUID = UUID()
    var title: String
    var createdAt: Date = Date()
    var updatedAt: Date = Date()
}

// MARK: - Conversation Store

@Observable
final class CompanionConversationStore {
    var conversations: [CompanionConversation] = []
    var activeConversation: CompanionConversation?
    private var messagesByConversation: [UUID: [CompanionMessage]] = [:]

    // MARK: - CRUD

    func createConversation(title: String) -> CompanionConversation {
        let conversation = CompanionConversation(title: title)
        conversations.insert(conversation, at: 0)
        messagesByConversation[conversation.id] = []
        return conversation
    }

    func deleteConversation(_ id: UUID) {
        conversations.removeAll { $0.id == id }
        messagesByConversation.removeValue(forKey: id)
        if activeConversation?.id == id {
            activeConversation = conversations.first
        }
    }

    func messages(for conversationID: UUID) -> [CompanionMessage] {
        messagesByConversation[conversationID] ?? []
    }

    func addMessage(_ message: CompanionMessage, to conversationID: UUID) {
        messagesByConversation[conversationID, default: []].append(message)
        if let idx = conversations.firstIndex(where: { $0.id == conversationID }) {
            conversations[idx].updatedAt = Date()
        }
    }

    func appendToMessage(_ messageID: UUID, in conversationID: UUID, content: String) {
        guard var messages = messagesByConversation[conversationID],
              let idx = messages.firstIndex(where: { $0.id == messageID }) else { return }
        messages[idx].content += content
        messagesByConversation[conversationID] = messages
    }

    var activeMessages: [CompanionMessage] {
        guard let id = activeConversation?.id else { return [] }
        return messages(for: id)
    }

    func clearAll() {
        conversations.removeAll()
        messagesByConversation.removeAll()
        activeConversation = nil
    }
}
