import XCTest
@testable import AgentKit

final class AgentKitTests: XCTestCase {

    // MARK: - AgentProfile Tests

    func testAgentProfileCreation() {
        let profile = AgentProfile(
            nodeID: "abc123",
            agentType: .personal,
            displayName: "Alice",
            bio: "Personal assistant",
            capabilities: [.generalChat, .scheduling]
        )

        XCTAssertEqual(profile.nodeID, "abc123")
        XCTAssertEqual(profile.id, "abc123")
        XCTAssertEqual(profile.agentType, .personal)
        XCTAssertEqual(profile.displayName, "Alice")
        XCTAssertEqual(profile.capabilities.count, 2)
        XCTAssertEqual(profile.version, 1)
    }

    func testAgentProfileCodableRoundTrip() throws {
        let profile = AgentProfile(
            nodeID: "node1",
            agentType: .business,
            displayName: "Bob's Shop",
            bio: "Local retail",
            capabilities: [.shopping, .customerSupport],
            preferences: AgentPreferences(
                tone: .formal,
                language: "en",
                autoNegotiate: true,
                maxBudgetPerTransaction: 100.0,
                delegationRules: [
                    DelegationRule(capability: "shopping", maxCreditSpend: 50)
                ]
            ),
            businessInfo: BusinessInfo(
                businessName: "Bob's Shop",
                category: "retail",
                location: "NYC",
                verified: true
            )
        )

        let encoder = JSONEncoder()
        let data = try encoder.encode(profile)
        let decoded = try JSONDecoder().decode(AgentProfile.self, from: data)

        XCTAssertEqual(profile, decoded)
        XCTAssertEqual(decoded.businessInfo?.businessName, "Bob's Shop")
        XCTAssertEqual(decoded.preferences.tone, .formal)
        XCTAssertEqual(decoded.preferences.delegationRules.count, 1)
    }

    // MARK: - AgentMessage Tests

    func testAgentMessageCreation() {
        let message = AgentMessage(
            conversationID: UUID(),
            fromAgentID: "agent1",
            toAgentID: "agent2",
            type: .chat(ChatPayload(content: "Hello!"))
        )

        XCTAssertEqual(message.fromAgentID, "agent1")
        XCTAssertEqual(message.toAgentID, "agent2")
        XCTAssertNil(message.signature)
    }

    func testAgentMessageCodableRoundTrip() throws {
        let intentID = UUID()
        let message = AgentMessage(
            conversationID: UUID(),
            fromAgentID: "agent1",
            toAgentID: "agent2",
            type: .intent(IntentPayload(
                id: intentID,
                category: "scheduling",
                description: "Book a meeting",
                constraints: ["date": "2026-04-10", "duration": "1h"],
                urgency: .high
            ))
        )

        let data = try JSONEncoder().encode(message)
        let decoded = try JSONDecoder().decode(AgentMessage.self, from: data)

        XCTAssertEqual(message.id, decoded.id)
        XCTAssertEqual(message.conversationID, decoded.conversationID)

        if case .intent(let payload) = decoded.type {
            XCTAssertEqual(payload.category, "scheduling")
            XCTAssertEqual(payload.urgency, .high)
            XCTAssertEqual(payload.constraints["date"], "2026-04-10")
        } else {
            XCTFail("Expected intent type")
        }
    }

    func testAgentMessageSigningData() throws {
        let message = AgentMessage(
            conversationID: UUID(),
            fromAgentID: "agent1",
            toAgentID: "agent2",
            type: .chat(ChatPayload(content: "test")),
            signature: Data([1, 2, 3])
        )

        let signingData = try message.signingData()
        let decoded = try JSONDecoder().decode(AgentMessage.self, from: signingData)
        XCTAssertNil(decoded.signature)
        XCTAssertEqual(decoded.id, message.id)
    }

    func testAllMessageTypesEncodeDecode() throws {
        let convoID = UUID()
        let intentID = UUID()
        let offerID = UUID()

        let messages: [AgentMessage] = [
            AgentMessage(conversationID: convoID, fromAgentID: "a", toAgentID: "b",
                         type: .intent(IntentPayload(category: "test", description: "test"))),
            AgentMessage(conversationID: convoID, fromAgentID: "a", toAgentID: "b",
                         type: .offer(OfferPayload(intentID: intentID, description: "offer", creditCost: 10))),
            AgentMessage(conversationID: convoID, fromAgentID: "a", toAgentID: "b",
                         type: .counterOffer(OfferPayload(intentID: intentID, description: "counter", creditCost: 5))),
            AgentMessage(conversationID: convoID, fromAgentID: "a", toAgentID: "b",
                         type: .accept(AcceptPayload(intentID: intentID, offerID: offerID, agreedCost: 10))),
            AgentMessage(conversationID: convoID, fromAgentID: "a", toAgentID: "b",
                         type: .reject(RejectPayload(offerID: offerID, reason: "too expensive"))),
            AgentMessage(conversationID: convoID, fromAgentID: "a", toAgentID: "b",
                         type: .complete(CompletePayload(intentID: intentID, outcome: "done", actualCost: 10))),
            AgentMessage(conversationID: convoID, fromAgentID: "a", toAgentID: "b",
                         type: .review(ReviewPayload(conversationID: convoID, rating: 5, comment: "great"))),
            AgentMessage(conversationID: convoID, fromAgentID: "a", toAgentID: "b",
                         type: .chat(ChatPayload(content: "hello", attachments: ["file.txt"]))),
            AgentMessage(conversationID: convoID, fromAgentID: "a", toAgentID: "b",
                         type: .capability(CapabilityPayload(action: .advertise, capabilities: [.inference]))),
            AgentMessage(conversationID: convoID, fromAgentID: "a", toAgentID: "b",
                         type: .status(StatusPayload(intentID: intentID, status: .inProgress, message: "working"))),
        ]

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        for msg in messages {
            let data = try encoder.encode(msg)
            let decoded = try decoder.decode(AgentMessage.self, from: data)
            XCTAssertEqual(msg.id, decoded.id)
            XCTAssertEqual(msg.type, decoded.type)
        }
    }

    // MARK: - AgentConversation Tests

    func testConversationStateTransitions() async throws {
        let store = ConversationStore(directory: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString))

        let convo = await store.create(
            participants: ["agent1", "agent2"],
            state: .initiated,
            intent: IntentPayload(category: "scheduling", description: "book meeting")
        )

        XCTAssertEqual(convo.state, .initiated)

        try await store.updateState(convo.id, to: .negotiating)
        let updated = await store.getConversation(convo.id)
        XCTAssertEqual(updated?.state, .negotiating)

        try await store.updateState(convo.id, to: .accepted)
        let accepted = await store.getConversation(convo.id)
        XCTAssertEqual(accepted?.state, .accepted)

        try await store.updateState(convo.id, to: .completed)
        let completed = await store.getConversation(convo.id)
        XCTAssertEqual(completed?.state, .completed)
    }

    func testConversationStoreCRUD() async throws {
        let store = ConversationStore(directory: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString))

        // Create
        let convo1 = await store.create(participants: ["a", "b"], state: .chatting)
        _ = await store.create(participants: ["a", "c"], state: .initiated,
                                        intent: IntentPayload(category: "shopping", description: "buy stuff"))

        // List
        let all = await store.listConversations()
        XCTAssertEqual(all.count, 2)

        // Get
        let fetched = await store.getConversation(convo1.id)
        XCTAssertNotNil(fetched)
        XCTAssertEqual(fetched?.state, .chatting)

        // Add message
        let msg = AgentMessage(
            conversationID: convo1.id,
            fromAgentID: "a",
            toAgentID: "b",
            type: .chat(ChatPayload(content: "hi"))
        )
        try await store.addMessage(msg)
        let withMsg = await store.getConversation(convo1.id)
        XCTAssertEqual(withMsg?.messages.count, 1)

        // Delete
        await store.deleteConversation(convo1.id)
        let afterDelete = await store.listConversations()
        XCTAssertEqual(afterDelete.count, 1)

        // Filter by participant
        let forA = await store.conversations(forParticipant: "a")
        XCTAssertEqual(forA.count, 1)

        // Filter by state
        let initiated = await store.conversations(withState: .initiated)
        XCTAssertEqual(initiated.count, 1)

        // Filter by capability
        let shopping = await store.conversations(forCapability: "shopping")
        XCTAssertEqual(shopping.count, 1)

        // Active conversations
        let active = await store.activeConversations()
        XCTAssertEqual(active.count, 1)
    }

    func testConversationStorePersistence() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)

        // Create and save
        let store1 = ConversationStore(directory: dir)
        let convo = await store1.create(participants: ["x", "y"], state: .chatting)
        try await store1.save()

        // Load in new instance
        let store2 = ConversationStore(directory: dir)
        try await store2.load()
        let loaded = await store2.getConversation(convo.id)
        XCTAssertNotNil(loaded)
        XCTAssertEqual(loaded?.participants, ["x", "y"])

        // Cleanup
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: - AgentNegotiator Tests

    func testAutoAcceptWithinBudget() async {
        let negotiator = AgentNegotiator()

        let intent = IntentPayload(category: "scheduling", description: "book meeting")
        let offer = OfferPayload(
            intentID: intent.id,
            description: "I can schedule that",
            creditCost: 5.0,
            validUntil: Date().addingTimeInterval(3600)
        )

        let rules = [
            DelegationRule(capability: "scheduling", maxCreditSpend: 10.0, requiresApproval: false)
        ]

        let preferences = AgentPreferences(autoNegotiate: true)

        let decision = await negotiator.evaluateOffer(
            offer: offer,
            intent: intent,
            rules: rules,
            preferences: preferences,
            senderProfile: nil,
            creditBalance: 100.0
        )

        XCTAssertEqual(decision, .autoAccept)
    }

    func testAutoRejectOverBudget() async {
        let negotiator = AgentNegotiator()

        let intent = IntentPayload(category: "scheduling", description: "book meeting")
        let offer = OfferPayload(
            intentID: intent.id,
            description: "Premium scheduling",
            creditCost: 50.0,
            validUntil: Date().addingTimeInterval(3600)
        )

        let rules = [
            DelegationRule(capability: "scheduling", maxCreditSpend: 10.0, requiresApproval: false)
        ]

        let preferences = AgentPreferences(autoNegotiate: true)

        let decision = await negotiator.evaluateOffer(
            offer: offer,
            intent: intent,
            rules: rules,
            preferences: preferences,
            senderProfile: nil,
            creditBalance: 100.0
        )

        // Should counter-offer at the rule max since cost exceeds rule limit
        if case .counterOffer(let counter) = decision {
            XCTAssertEqual(counter.creditCost, 10.0)
        } else {
            XCTFail("Expected counter-offer, got \(decision)")
        }
    }

    func testAutoRejectInsufficientBalance() async {
        let negotiator = AgentNegotiator()

        let intent = IntentPayload(category: "scheduling", description: "book meeting")
        let offer = OfferPayload(
            intentID: intent.id,
            description: "Schedule it",
            creditCost: 50.0,
            validUntil: Date().addingTimeInterval(3600)
        )

        let decision = await negotiator.evaluateOffer(
            offer: offer,
            intent: intent,
            rules: [],
            preferences: AgentPreferences(),
            senderProfile: nil,
            creditBalance: 10.0
        )

        if case .autoReject(let reason) = decision {
            XCTAssertTrue(reason.contains("Insufficient"))
        } else {
            XCTFail("Expected auto-reject for insufficient balance")
        }
    }

    func testAskHumanWhenNoDelegationRule() async {
        let negotiator = AgentNegotiator()

        let intent = IntentPayload(category: "custom-task", description: "something unusual")
        let offer = OfferPayload(
            intentID: intent.id,
            description: "I can do it",
            creditCost: 5.0,
            validUntil: Date().addingTimeInterval(3600)
        )

        let decision = await negotiator.evaluateOffer(
            offer: offer,
            intent: intent,
            rules: [],  // no rules for "custom-task"
            preferences: AgentPreferences(autoNegotiate: true),
            senderProfile: nil,
            creditBalance: 100.0
        )

        if case .askHuman(let reason) = decision {
            XCTAssertTrue(reason.contains("No delegation rule"))
        } else {
            XCTFail("Expected ask-human, got \(decision)")
        }
    }

    func testAskHumanWhenRequiresApproval() async {
        let negotiator = AgentNegotiator()

        let intent = IntentPayload(category: "shopping", description: "buy groceries")
        let offer = OfferPayload(
            intentID: intent.id,
            description: "Grocery delivery",
            creditCost: 5.0,
            validUntil: Date().addingTimeInterval(3600)
        )

        let rules = [
            DelegationRule(capability: "shopping", maxCreditSpend: 100.0, requiresApproval: true)
        ]

        let decision = await negotiator.evaluateOffer(
            offer: offer,
            intent: intent,
            rules: rules,
            preferences: AgentPreferences(autoNegotiate: true),
            senderProfile: nil,
            creditBalance: 100.0
        )

        if case .askHuman(let reason) = decision {
            XCTAssertTrue(reason.contains("requires human approval"))
        } else {
            XCTFail("Expected ask-human for requires-approval rule")
        }
    }

    func testRejectExpiredOffer() async {
        let negotiator = AgentNegotiator()

        let intent = IntentPayload(category: "scheduling", description: "book meeting")
        let offer = OfferPayload(
            intentID: intent.id,
            description: "Expired offer",
            creditCost: 5.0,
            validUntil: Date().addingTimeInterval(-3600) // expired
        )

        let decision = await negotiator.evaluateOffer(
            offer: offer,
            intent: intent,
            rules: [],
            preferences: AgentPreferences(),
            senderProfile: nil,
            creditBalance: 100.0
        )

        if case .autoReject(let reason) = decision {
            XCTAssertTrue(reason.contains("expired"))
        } else {
            XCTFail("Expected auto-reject for expired offer")
        }
    }

    func testAskHumanWhenAutoNegotiateDisabled() async {
        let negotiator = AgentNegotiator()

        let intent = IntentPayload(category: "scheduling", description: "book meeting")
        let offer = OfferPayload(
            intentID: intent.id,
            description: "I can do it",
            creditCost: 5.0,
            validUntil: Date().addingTimeInterval(3600)
        )

        let rules = [
            DelegationRule(capability: "scheduling", maxCreditSpend: 100.0, requiresApproval: false)
        ]

        let decision = await negotiator.evaluateOffer(
            offer: offer,
            intent: intent,
            rules: rules,
            preferences: AgentPreferences(autoNegotiate: false),
            senderProfile: nil,
            creditBalance: 100.0
        )

        if case .askHuman(let reason) = decision {
            XCTAssertTrue(reason.contains("disabled"))
        } else {
            XCTFail("Expected ask-human when auto-negotiate disabled")
        }
    }

    // MARK: - AgentCapability Tests

    func testCapabilityMatching() {
        let profile = AgentProfile(
            nodeID: "node1",
            displayName: "Test Agent",
            capabilities: [.scheduling, .inference, .translation]
        )

        XCTAssertTrue(profile.capabilities.contains { $0.id == "scheduling" })
        XCTAssertTrue(profile.capabilities.contains { $0.id == "inference" })
        XCTAssertFalse(profile.capabilities.contains { $0.id == "shopping" })
    }

    func testWellKnownCapabilities() {
        let capabilities: [AgentCapability] = [
            .scheduling, .shopping, .customerSupport, .inference,
            .translation, .generalChat, .taskExecution, .informationRetrieval
        ]

        // All should have unique IDs
        let ids = Set(capabilities.map { $0.id })
        XCTAssertEqual(ids.count, capabilities.count)

        // Translation should have language parameters
        XCTAssertNotNil(AgentCapability.translation.parameters["languages"])
    }

    // MARK: - AgentDirectory Tests

    func testDirectorySearchByCapability() async {
        let directory = AgentDirectory(directory: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString))

        let profile1 = AgentProfile(
            nodeID: "node1",
            displayName: "Scheduler Bot",
            capabilities: [.scheduling, .generalChat]
        )
        let profile2 = AgentProfile(
            nodeID: "node2",
            agentType: .business,
            displayName: "Shop Bot",
            capabilities: [.shopping, .customerSupport]
        )

        await directory.register(profile: profile1, source: .lan)
        await directory.register(profile: profile2, source: .lan)

        let schedulers = await directory.search(capability: "scheduling")
        XCTAssertEqual(schedulers.count, 1)
        XCTAssertEqual(schedulers.first?.profile.nodeID, "node1")

        let businesses = await directory.search(agentType: .business)
        XCTAssertEqual(businesses.count, 1)
        XCTAssertEqual(businesses.first?.profile.nodeID, "node2")

        let queryResults = await directory.search(query: "Shop")
        XCTAssertEqual(queryResults.count, 1)

        let all = await directory.allEntries()
        XCTAssertEqual(all.count, 2)
    }

    func testDirectoryRating() async {
        let directory = AgentDirectory(directory: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString))

        let profile = AgentProfile(nodeID: "node1", displayName: "Test")
        await directory.register(profile: profile)

        await directory.updateRating(nodeID: "node1", newRating: 5)
        await directory.updateRating(nodeID: "node1", newRating: 3)

        let entry = await directory.get(nodeID: "node1")
        XCTAssertEqual(entry?.reviewCount, 2)
        XCTAssertEqual(entry?.rating, 4.0) // (5+3)/2
    }

    func testDirectoryOnlineOffline() async {
        let directory = AgentDirectory(directory: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString))

        let profile = AgentProfile(nodeID: "node1", displayName: "Test")
        await directory.register(profile: profile)

        var entry = await directory.get(nodeID: "node1")
        XCTAssertTrue(entry?.isOnline ?? false)

        await directory.markOffline(nodeID: "node1")
        entry = await directory.get(nodeID: "node1")
        XCTAssertFalse(entry?.isOnline ?? true)

        await directory.markOnline(nodeID: "node1")
        entry = await directory.get(nodeID: "node1")
        XCTAssertTrue(entry?.isOnline ?? false)
    }

    func testDirectoryNearbyAndWan() async {
        let directory = AgentDirectory(directory: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString))

        await directory.register(profile: AgentProfile(nodeID: "lan1", displayName: "LAN Agent"), source: .lan)
        await directory.register(profile: AgentProfile(nodeID: "wan1", displayName: "WAN Agent"), source: .wan)
        await directory.register(profile: AgentProfile(nodeID: "local1", displayName: "Local"), source: .local)

        let nearby = await directory.nearbyAgents()
        XCTAssertEqual(nearby.count, 1)
        XCTAssertEqual(nearby.first?.profile.nodeID, "lan1")

        let wan = await directory.wanAgents()
        XCTAssertEqual(wan.count, 1)
        XCTAssertEqual(wan.first?.profile.nodeID, "wan1")
    }

    // MARK: - IntentPayload / OfferPayload Codable

    func testIntentPayloadCodable() throws {
        let intent = IntentPayload(
            category: "scheduling",
            description: "Book a haircut",
            constraints: ["date": "2026-04-15", "time": "14:00"],
            urgency: .urgent,
            expiresAt: Date().addingTimeInterval(86400)
        )

        let data = try JSONEncoder().encode(intent)
        let decoded = try JSONDecoder().decode(IntentPayload.self, from: data)

        XCTAssertEqual(intent.id, decoded.id)
        XCTAssertEqual(decoded.category, "scheduling")
        XCTAssertEqual(decoded.urgency, .urgent)
        XCTAssertEqual(decoded.constraints["date"], "2026-04-15")
    }

    func testOfferPayloadCodable() throws {
        let offer = OfferPayload(
            intentID: UUID(),
            description: "Haircut at 2pm",
            creditCost: 25.0,
            estimatedDuration: 1800,
            terms: ["cancellation": "24h notice"],
            validUntil: Date().addingTimeInterval(7200)
        )

        let data = try JSONEncoder().encode(offer)
        let decoded = try JSONDecoder().decode(OfferPayload.self, from: data)

        XCTAssertEqual(offer.id, decoded.id)
        XCTAssertEqual(decoded.creditCost, 25.0)
        XCTAssertEqual(decoded.estimatedDuration, 1800)
        XCTAssertEqual(decoded.terms["cancellation"], "24h notice")
    }

    func testReviewPayloadClampingRating() {
        let low = ReviewPayload(conversationID: UUID(), rating: -1)
        XCTAssertEqual(low.rating, 1)

        let high = ReviewPayload(conversationID: UUID(), rating: 10)
        XCTAssertEqual(high.rating, 5)

        let normal = ReviewPayload(conversationID: UUID(), rating: 3)
        XCTAssertEqual(normal.rating, 3)
    }

    // MARK: - AgentTransportMessage Tests

    func testAgentTransportMessageRoundTrip() throws {
        let message = AgentMessage(
            conversationID: UUID(),
            fromAgentID: "sender",
            toAgentID: "receiver",
            type: .chat(ChatPayload(content: "Hello via transport"))
        )

        let transport = try AgentTransportMessage(message: message)
        let decoded = try transport.decode()

        XCTAssertEqual(message.id, decoded.id)
        XCTAssertEqual(message.fromAgentID, decoded.fromAgentID)
    }

    // MARK: - Urgency Comparison Tests

    func testUrgencyOrdering() {
        XCTAssertTrue(Urgency.low < Urgency.normal)
        XCTAssertTrue(Urgency.normal < Urgency.high)
        XCTAssertTrue(Urgency.high < Urgency.urgent)
        XCTAssertFalse(Urgency.urgent < Urgency.low)
    }
}
