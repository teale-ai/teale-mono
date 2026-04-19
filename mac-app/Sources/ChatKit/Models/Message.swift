import Foundation

// MARK: - Message Type

public enum MessageType: String, Codable, Sendable {
    case text
    case aiResponse = "ai_response"
    case system
    case toolResult = "tool_result"
    case toolCall = "tool_call"
    /// Append-only entry in the group wallet ledger (contribution/debit/withdrawal).
    /// Content is a JSON-encoded `WalletLedgerEntry`.
    case walletEntry = "wallet_entry"
    /// Outbound agent-to-agent request (this group's agent → another agent).
    /// Content is a JSON-encoded `AgentExchange`.
    case agentRequest = "agent_request"
    /// Inbound agent-to-agent response.
    case agentResponse = "agent_response"
    /// Scoped-disclosure consent card shown to the user before sharing context
    /// with another agent. Content is JSON with the list of proposed disclosures.
    case disclosureConsent = "disclosure_consent"
}

// MARK: - Message Metadata

/// Type-safe metadata for different message types
public enum MessageMetadata: Codable, Sendable, Equatable {
    /// AI response metadata
    case ai(AIResponseMeta)
    /// Tool call metadata
    case toolCall(ToolCallMeta)
    /// Tool result metadata
    case toolResult(ToolResultMeta)
    /// Text with mentions
    case mentions([UUID])
    /// Raw JSON fallback
    case raw([String: String])

    public struct AIResponseMeta: Codable, Sendable, Equatable {
        public var model: String
        public var tokensPrompt: Int?
        public var tokensCompletion: Int?
        public var inferenceNodeID: String?
        public var cost: Double?
    }

    public struct ToolCallMeta: Codable, Sendable, Equatable {
        public var tool: String
        public var params: [String: String]
        public var requesterID: UUID?
    }

    public struct ToolResultMeta: Codable, Sendable, Equatable {
        public var tool: String
        public var success: Bool
        public var resultSummary: String?
    }

    // Encode/decode as a flat JSON object with a "_type" discriminator
    enum CodingKeys: String, CodingKey {
        case type = "_type"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decodeIfPresent(String.self, forKey: .type) ?? "raw"
        switch type {
        case "ai":
            self = .ai(try AIResponseMeta(from: decoder))
        case "tool_call":
            self = .toolCall(try ToolCallMeta(from: decoder))
        case "tool_result":
            self = .toolResult(try ToolResultMeta(from: decoder))
        case "mentions":
            let singleContainer = try decoder.singleValueContainer()
            self = .mentions(try singleContainer.decode([UUID].self))
        default:
            self = .raw([:])
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .ai(let meta):
            try container.encode("ai", forKey: .type)
            try meta.encode(to: encoder)
        case .toolCall(let meta):
            try container.encode("tool_call", forKey: .type)
            try meta.encode(to: encoder)
        case .toolResult(let meta):
            try container.encode("tool_result", forKey: .type)
            try meta.encode(to: encoder)
        case .mentions(let ids):
            try container.encode("mentions", forKey: .type)
            var single = encoder.singleValueContainer()
            try single.encode(ids)
        case .raw(let dict):
            try container.encode("raw", forKey: .type)
            var single = encoder.singleValueContainer()
            try single.encode(dict)
        }
    }
}

// MARK: - Message

/// All messages are E2E encrypted. The `encryptedContent` field holds a base64-encoded
/// `EncryptedPayload` that can only be decrypted with the matching sender key.
public struct Message: Codable, Sendable, Identifiable, Equatable {
    public var id: UUID
    public var conversationID: UUID
    /// nil = AI agent message
    public var senderID: UUID?
    /// Base64-encoded EncryptedPayload. Decrypt with the sender key matching `encryptionKeyID`.
    public var encryptedContent: String
    /// The sender key ID used to encrypt this message.
    public var encryptionKeyID: String
    public var messageType: MessageType
    public var replyToID: UUID?
    public var createdAt: Date
    public var editedAt: Date?

    public var isFromAgent: Bool { senderID == nil }

    public init(
        id: UUID = UUID(),
        conversationID: UUID,
        senderID: UUID?,
        encryptedContent: String,
        encryptionKeyID: String,
        messageType: MessageType = .text,
        replyToID: UUID? = nil,
        createdAt: Date = Date(),
        editedAt: Date? = nil
    ) {
        self.id = id
        self.conversationID = conversationID
        self.senderID = senderID
        self.encryptedContent = encryptedContent
        self.encryptionKeyID = encryptionKeyID
        self.messageType = messageType
        self.replyToID = replyToID
        self.createdAt = createdAt
        self.editedAt = editedAt
    }

    enum CodingKeys: String, CodingKey {
        case id
        case conversationID = "conversation_id"
        case senderID = "sender_id"
        case encryptedContent = "encrypted_content"
        case encryptionKeyID = "encryption_key_id"
        case messageType = "message_type"
        case replyToID = "reply_to_id"
        case createdAt = "created_at"
        case editedAt = "edited_at"
    }
}

// MARK: - Decrypted Message

/// A decrypted message for display in the UI.
public struct DecryptedMessage: Identifiable, Equatable {
    public let message: Message
    public let content: String

    public var id: UUID { message.id }
    public var conversationID: UUID { message.conversationID }
    public var senderID: UUID? { message.senderID }
    public var messageType: MessageType { message.messageType }
    public var replyToID: UUID? { message.replyToID }
    public var createdAt: Date { message.createdAt }
    public var isFromAgent: Bool { message.isFromAgent }

    public init(message: Message, content: String) {
        self.message = message
        self.content = content
    }
}
