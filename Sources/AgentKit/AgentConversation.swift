import Foundation

// MARK: - Conversation State

public enum ConversationState: String, Codable, Sendable, CaseIterable {
    case initiated    // intent sent, waiting for offers
    case negotiating  // offers/counter-offers in progress
    case accepted     // offer accepted, work in progress
    case completed    // work done, may be reviewed
    case rejected     // all offers rejected
    case expired      // timed out
    case chatting     // free-form chat (no negotiation)
}

// MARK: - Agent Conversation

public struct AgentConversation: Codable, Sendable, Identifiable, Equatable, Hashable {
    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    public var id: UUID
    public var participants: [String]
    public var state: ConversationState
    public var messages: [AgentMessage]
    public var intent: IntentPayload?
    public var acceptedOffer: OfferPayload?
    public var createdAt: Date
    public var updatedAt: Date
    public var metadata: [String: String]

    public init(
        id: UUID = UUID(),
        participants: [String],
        state: ConversationState = .initiated,
        messages: [AgentMessage] = [],
        intent: IntentPayload? = nil,
        acceptedOffer: OfferPayload? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        metadata: [String: String] = [:]
    ) {
        self.id = id
        self.participants = participants
        self.state = state
        self.messages = messages
        self.intent = intent
        self.acceptedOffer = acceptedOffer
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.metadata = metadata
    }
}

// MARK: - Conversation Store

public actor ConversationStore {
    private var conversations: [UUID: AgentConversation] = [:]
    private let fileURL: URL

    public init(directory: URL? = nil) {
        let dir = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("InferencePool", isDirectory: true)
        self.fileURL = dir.appendingPathComponent("agent_conversations.json")
    }

    // MARK: - Persistence

    public func load() throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        let data = try Data(contentsOf: fileURL)
        let decoded = try JSONDecoder().decode([AgentConversation].self, from: data)
        conversations = Dictionary(uniqueKeysWithValues: decoded.map { ($0.id, $0) })
    }

    public func save() throws {
        let dir = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(Array(conversations.values))
        try data.write(to: fileURL, options: .atomic)
    }

    // MARK: - CRUD

    public func create(participants: [String], state: ConversationState = .initiated, intent: IntentPayload? = nil, metadata: [String: String] = [:]) -> AgentConversation {
        let convo = AgentConversation(
            participants: participants,
            state: state,
            intent: intent,
            metadata: metadata
        )
        conversations[convo.id] = convo
        return convo
    }

    public func addMessage(_ message: AgentMessage) throws {
        guard var convo = conversations[message.conversationID] else {
            throw AgentError.conversationNotFound(message.conversationID)
        }
        convo.messages.append(message)
        convo.updatedAt = Date()
        conversations[convo.id] = convo
    }

    public func updateState(_ conversationID: UUID, to state: ConversationState) throws {
        guard var convo = conversations[conversationID] else {
            throw AgentError.conversationNotFound(conversationID)
        }
        convo.state = state
        convo.updatedAt = Date()
        conversations[conversationID] = convo
    }

    public func setAcceptedOffer(_ conversationID: UUID, offer: OfferPayload) throws {
        guard var convo = conversations[conversationID] else {
            throw AgentError.conversationNotFound(conversationID)
        }
        convo.acceptedOffer = offer
        convo.state = .accepted
        convo.updatedAt = Date()
        conversations[conversationID] = convo
    }

    public func getConversation(_ id: UUID) -> AgentConversation? {
        conversations[id]
    }

    public func listConversations() -> [AgentConversation] {
        Array(conversations.values).sorted { $0.updatedAt > $1.updatedAt }
    }

    public func deleteConversation(_ id: UUID) {
        conversations.removeValue(forKey: id)
    }

    // MARK: - Queries

    public func activeConversations() -> [AgentConversation] {
        conversations.values.filter {
            $0.state != .completed && $0.state != .expired && $0.state != .rejected
        }.sorted { $0.updatedAt > $1.updatedAt }
    }

    public func conversations(forParticipant nodeID: String) -> [AgentConversation] {
        conversations.values.filter {
            $0.participants.contains(nodeID)
        }.sorted { $0.updatedAt > $1.updatedAt }
    }

    public func conversations(withState state: ConversationState) -> [AgentConversation] {
        conversations.values.filter {
            $0.state == state
        }.sorted { $0.updatedAt > $1.updatedAt }
    }

    public func conversations(forCapability capability: String) -> [AgentConversation] {
        conversations.values.filter {
            $0.intent?.category == capability
        }.sorted { $0.updatedAt > $1.updatedAt }
    }
}

// MARK: - Agent Errors

public enum AgentError: Error, Sendable, Equatable {
    case conversationNotFound(UUID)
    case invalidState(expected: ConversationState, actual: ConversationState)
    case profileNotConfigured
    case transportNotAvailable
    case signatureVerificationFailed
    case signatureMissing
    case signerNotConfigured
    case unknownAgent(String)
    case offerExpired
    case insufficientCredits(required: Double, available: Double)
    case agentNotFound(String)
}
