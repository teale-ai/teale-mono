import Foundation

// MARK: - Agent Manager State

public struct AgentManagerState: Sendable {
    public var profile: AgentProfile?
    public var activeConversations: [AgentConversation]
    public var directoryEntries: [AgentDirectoryEntry]
    public var isConfigured: Bool

    public init(
        profile: AgentProfile? = nil,
        activeConversations: [AgentConversation] = [],
        directoryEntries: [AgentDirectoryEntry] = [],
        isConfigured: Bool = false
    ) {
        self.profile = profile
        self.activeConversations = activeConversations
        self.directoryEntries = directoryEntries
        self.isConfigured = isConfigured
    }
}

// MARK: - Incoming Message Action

/// Describes what happened when an incoming message was processed.
public enum IncomingMessageAction: Sendable {
    case conversationCreated(UUID)
    case negotiationDecision(NegotiationDecision, conversationID: UUID)
    case offerAccepted(conversationID: UUID)
    case conversationCompleted(conversationID: UUID)
    case chatReceived(conversationID: UUID)
    case error(String)
}

// MARK: - Agent Manager

public actor AgentManager {
    public let conversationStore: ConversationStore
    public let directory: AgentDirectory
    public let negotiator: AgentNegotiator
    public let router: AgentRouter

    private var profile: AgentProfile?
    private var creditBalance: Double = 0

    public init(
        conversationStore: ConversationStore? = nil,
        directory: AgentDirectory? = nil,
        negotiator: AgentNegotiator? = nil,
        router: AgentRouter? = nil
    ) {
        self.conversationStore = conversationStore ?? ConversationStore()
        self.directory = directory ?? AgentDirectory()
        self.negotiator = negotiator ?? AgentNegotiator()
        self.router = router ?? AgentRouter()
    }

    // MARK: - Setup

    public func setup(profile: AgentProfile, creditBalance: Double = 0) async {
        self.profile = profile
        self.creditBalance = creditBalance

        // Register ourselves in the directory
        await directory.register(profile: profile, source: .local)

        // Set up router message handler
        await router.onMessageReceived { [weak self] message in
            guard let self = self else { return }
            _ = await self.onIncomingMessage(message: message)
        }

        // Load persisted data
        try? await conversationStore.load()
        try? await directory.load()
    }

    public func updateCreditBalance(_ balance: Double) {
        self.creditBalance = balance
    }

    public func getProfile() -> AgentProfile? {
        profile
    }

    public func getState() async -> AgentManagerState {
        let active = await conversationStore.activeConversations()
        let entries = await directory.allEntries()
        return AgentManagerState(
            profile: profile,
            activeConversations: active,
            directoryEntries: entries,
            isConfigured: profile != nil
        )
    }

    // MARK: - Sending Intents

    /// Start a negotiation by sending an intent to another agent.
    public func sendIntent(to agentID: String, intent: IntentPayload) async throws -> AgentConversation {
        guard let profile = profile else { throw AgentError.profileNotConfigured }

        let convo = await conversationStore.create(
            participants: [profile.nodeID, agentID],
            state: .initiated,
            intent: intent
        )

        let message = AgentMessage(
            conversationID: convo.id,
            fromAgentID: profile.nodeID,
            toAgentID: agentID,
            type: .intent(intent)
        )

        try await conversationStore.addMessage(message)
        try await router.send(message: message, to: agentID)
        try await conversationStore.save()

        return convo
    }

    // MARK: - Responding to Intents

    /// Send an offer in response to an intent.
    public func respondToIntent(conversationID: UUID, offer: OfferPayload) async throws {
        guard let profile = profile else { throw AgentError.profileNotConfigured }
        guard let convo = await conversationStore.getConversation(conversationID) else {
            throw AgentError.conversationNotFound(conversationID)
        }

        let toAgentID = convo.participants.first { $0 != profile.nodeID } ?? ""

        let message = AgentMessage(
            conversationID: conversationID,
            fromAgentID: profile.nodeID,
            toAgentID: toAgentID,
            type: .offer(offer)
        )

        try await conversationStore.addMessage(message)
        try await conversationStore.updateState(conversationID, to: .negotiating)
        try await router.send(message: message, to: toAgentID)
        try await conversationStore.save()
    }

    // MARK: - Accept / Reject

    /// Accept an offer in a conversation.
    public func acceptOffer(conversationID: UUID, offer: OfferPayload) async throws {
        guard let profile = profile else { throw AgentError.profileNotConfigured }
        guard let convo = await conversationStore.getConversation(conversationID) else {
            throw AgentError.conversationNotFound(conversationID)
        }

        if offer.validUntil < Date() {
            throw AgentError.offerExpired
        }

        if offer.creditCost > creditBalance {
            throw AgentError.insufficientCredits(required: offer.creditCost, available: creditBalance)
        }

        let toAgentID = convo.participants.first { $0 != profile.nodeID } ?? ""

        let accept = AcceptPayload(
            intentID: offer.intentID,
            offerID: offer.id,
            agreedCost: offer.creditCost
        )

        let message = AgentMessage(
            conversationID: conversationID,
            fromAgentID: profile.nodeID,
            toAgentID: toAgentID,
            type: .accept(accept)
        )

        try await conversationStore.addMessage(message)
        try await conversationStore.setAcceptedOffer(conversationID, offer: offer)
        try await router.send(message: message, to: toAgentID)
        try await conversationStore.save()
    }

    /// Reject an offer.
    public func rejectOffer(conversationID: UUID, offerID: UUID, reason: String) async throws {
        guard let profile = profile else { throw AgentError.profileNotConfigured }
        guard let convo = await conversationStore.getConversation(conversationID) else {
            throw AgentError.conversationNotFound(conversationID)
        }

        let toAgentID = convo.participants.first { $0 != profile.nodeID } ?? ""

        let reject = RejectPayload(offerID: offerID, reason: reason)
        let message = AgentMessage(
            conversationID: conversationID,
            fromAgentID: profile.nodeID,
            toAgentID: toAgentID,
            type: .reject(reject)
        )

        try await conversationStore.addMessage(message)
        try await conversationStore.updateState(conversationID, to: .rejected)
        try await router.send(message: message, to: toAgentID)
        try await conversationStore.save()
    }

    // MARK: - Chat

    /// Send a free-form chat message to another agent.
    public func sendChat(to agentID: String, message content: String, conversationID: UUID? = nil) async throws -> AgentConversation {
        guard let profile = profile else { throw AgentError.profileNotConfigured }

        let convoID: UUID
        if let existing = conversationID, await conversationStore.getConversation(existing) != nil {
            convoID = existing
        } else {
            let convo = await conversationStore.create(
                participants: [profile.nodeID, agentID],
                state: .chatting
            )
            convoID = convo.id
        }

        let message = AgentMessage(
            conversationID: convoID,
            fromAgentID: profile.nodeID,
            toAgentID: agentID,
            type: .chat(ChatPayload(content: content))
        )

        try await conversationStore.addMessage(message)
        try await router.send(message: message, to: agentID)
        try await conversationStore.save()

        return await conversationStore.getConversation(convoID)!
    }

    // MARK: - Incoming Messages

    /// Handle an incoming agent message. Returns what action was taken.
    public func onIncomingMessage(message: AgentMessage) async -> IncomingMessageAction {
        // Ensure conversation exists
        var convo = await conversationStore.getConversation(message.conversationID)
        if convo == nil {
            // Create conversation for incoming messages
            let participants = [message.fromAgentID, message.toAgentID]
            let state: ConversationState
            switch message.type {
            case .intent: state = .initiated
            case .chat: state = .chatting
            default: state = .negotiating
            }
            convo = await conversationStore.create(
                participants: participants,
                state: state
            )
        }

        // Store the message (use the actual conversation ID)
        var storedMessage = message
        if let convo = convo, storedMessage.conversationID != convo.id {
            storedMessage = AgentMessage(
                id: message.id,
                conversationID: convo.id,
                fromAgentID: message.fromAgentID,
                toAgentID: message.toAgentID,
                timestamp: message.timestamp,
                type: message.type,
                signature: message.signature
            )
        }

        do {
            try await conversationStore.addMessage(storedMessage)
        } catch {
            return .error("Failed to store message: \(error)")
        }

        let conversationID = convo?.id ?? message.conversationID

        switch message.type {
        case .intent(let intent):
            // New intent received — update conversation with intent
            return .conversationCreated(conversationID)

        case .offer(let offer):
            // Evaluate offer using negotiator
            guard let profile = profile else { return .error("Profile not configured") }
            let senderEntry = await directory.get(nodeID: message.fromAgentID)

            let decision = await negotiator.evaluateOffer(
                offer: offer,
                intent: convo?.intent ?? IntentPayload(category: "", description: ""),
                rules: profile.preferences.delegationRules,
                preferences: profile.preferences,
                senderProfile: senderEntry,
                creditBalance: creditBalance
            )

            switch decision {
            case .autoAccept:
                do {
                    try await acceptOffer(conversationID: conversationID, offer: offer)
                } catch {
                    return .error("Auto-accept failed: \(error)")
                }
            case .autoReject(let reason):
                do {
                    try await rejectOffer(conversationID: conversationID, offerID: offer.id, reason: reason)
                } catch {
                    return .error("Auto-reject failed: \(error)")
                }
            default:
                break
            }

            return .negotiationDecision(decision, conversationID: conversationID)

        case .counterOffer(let offer):
            return .negotiationDecision(.askHuman(reason: "Counter-offer received"), conversationID: conversationID)

        case .accept:
            try? await conversationStore.updateState(conversationID, to: .accepted)
            return .offerAccepted(conversationID: conversationID)

        case .reject:
            try? await conversationStore.updateState(conversationID, to: .rejected)
            return .negotiationDecision(.autoReject(reason: "Offer was rejected"), conversationID: conversationID)

        case .complete:
            try? await conversationStore.updateState(conversationID, to: .completed)
            return .conversationCompleted(conversationID: conversationID)

        case .review(let review):
            await directory.updateRating(nodeID: message.fromAgentID, newRating: review.rating)
            return .conversationCompleted(conversationID: conversationID)

        case .chat:
            return .chatReceived(conversationID: conversationID)

        case .capability:
            return .chatReceived(conversationID: conversationID)

        case .status:
            return .chatReceived(conversationID: conversationID)
        }
    }
}
