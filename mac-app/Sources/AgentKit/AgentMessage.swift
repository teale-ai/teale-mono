import Foundation

// MARK: - Urgency

public enum Urgency: String, Codable, Sendable, CaseIterable, Comparable {
    case low
    case normal
    case high
    case urgent

    private var sortOrder: Int {
        switch self {
        case .low: return 0
        case .normal: return 1
        case .high: return 2
        case .urgent: return 3
        }
    }

    public static func < (lhs: Urgency, rhs: Urgency) -> Bool {
        lhs.sortOrder < rhs.sortOrder
    }
}

// MARK: - Task Status

public enum TaskStatus: String, Codable, Sendable {
    case pending
    case inProgress
    case completed
    case failed
}

// MARK: - Capability Action

public enum CapabilityAction: String, Codable, Sendable {
    case advertise
    case query
    case response
}

// MARK: - Message Payloads

public struct IntentPayload: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var category: String
    public var description: String
    public var constraints: [String: String]
    public var urgency: Urgency
    public var expiresAt: Date?

    public init(
        id: UUID = UUID(),
        category: String,
        description: String,
        constraints: [String: String] = [:],
        urgency: Urgency = .normal,
        expiresAt: Date? = nil
    ) {
        self.id = id
        self.category = category
        self.description = description
        self.constraints = constraints
        self.urgency = urgency
        self.expiresAt = expiresAt
    }
}

public struct OfferPayload: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var intentID: UUID
    public var description: String
    public var creditCost: Double
    public var estimatedDuration: TimeInterval?
    public var terms: [String: String]
    public var validUntil: Date

    public init(
        id: UUID = UUID(),
        intentID: UUID,
        description: String,
        creditCost: Double,
        estimatedDuration: TimeInterval? = nil,
        terms: [String: String] = [:],
        validUntil: Date = Date().addingTimeInterval(3600)
    ) {
        self.id = id
        self.intentID = intentID
        self.description = description
        self.creditCost = creditCost
        self.estimatedDuration = estimatedDuration
        self.terms = terms
        self.validUntil = validUntil
    }
}

public struct AcceptPayload: Codable, Sendable, Equatable {
    public var intentID: UUID
    public var offerID: UUID
    public var agreedCost: Double

    public init(intentID: UUID, offerID: UUID, agreedCost: Double) {
        self.intentID = intentID
        self.offerID = offerID
        self.agreedCost = agreedCost
    }
}

public struct RejectPayload: Codable, Sendable, Equatable {
    public var offerID: UUID
    public var reason: String

    public init(offerID: UUID, reason: String) {
        self.offerID = offerID
        self.reason = reason
    }
}

public struct CompletePayload: Codable, Sendable, Equatable {
    public var intentID: UUID
    public var outcome: String
    public var actualCost: Double

    public init(intentID: UUID, outcome: String, actualCost: Double) {
        self.intentID = intentID
        self.outcome = outcome
        self.actualCost = actualCost
    }
}

public struct ReviewPayload: Codable, Sendable, Equatable {
    public var conversationID: UUID
    public var rating: Int
    public var comment: String?

    public init(conversationID: UUID, rating: Int, comment: String? = nil) {
        self.conversationID = conversationID
        self.rating = max(1, min(5, rating))
        self.comment = comment
    }
}

public struct ChatPayload: Codable, Sendable, Equatable {
    public var content: String
    public var attachments: [String]?

    public init(content: String, attachments: [String]? = nil) {
        self.content = content
        self.attachments = attachments
    }
}

public struct CapabilityPayload: Codable, Sendable, Equatable {
    public var action: CapabilityAction
    public var capabilities: [AgentCapability]

    public init(action: CapabilityAction, capabilities: [AgentCapability]) {
        self.action = action
        self.capabilities = capabilities
    }
}

public struct StatusPayload: Codable, Sendable, Equatable {
    public var intentID: UUID
    public var status: TaskStatus
    public var message: String?

    public init(intentID: UUID, status: TaskStatus, message: String? = nil) {
        self.intentID = intentID
        self.status = status
        self.message = message
    }
}

// MARK: - Agent Message Type

public enum AgentMessageType: Codable, Sendable, Equatable {
    case intent(IntentPayload)
    case offer(OfferPayload)
    case counterOffer(OfferPayload)
    case accept(AcceptPayload)
    case reject(RejectPayload)
    case complete(CompletePayload)
    case review(ReviewPayload)
    case chat(ChatPayload)
    case capability(CapabilityPayload)
    case status(StatusPayload)
}

// MARK: - Agent Message

public struct AgentMessage: Codable, Sendable, Identifiable, Equatable {
    public var id: UUID
    public var conversationID: UUID
    public var fromAgentID: String
    public var toAgentID: String
    public var timestamp: Date
    public var type: AgentMessageType
    public var signature: Data?

    public init(
        id: UUID = UUID(),
        conversationID: UUID,
        fromAgentID: String,
        toAgentID: String,
        timestamp: Date = Date(),
        type: AgentMessageType,
        signature: Data? = nil
    ) {
        self.id = id
        self.conversationID = conversationID
        self.fromAgentID = fromAgentID
        self.toAgentID = toAgentID
        self.timestamp = timestamp
        self.type = type
        self.signature = signature
    }

    /// Returns the message data to be signed (everything except the signature field).
    public func signingData() throws -> Data {
        var copy = self
        copy.signature = nil
        return try JSONEncoder().encode(copy)
    }
}
