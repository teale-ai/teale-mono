import Foundation

// MARK: - Demo Reservation Driver

/// Plays a scripted agent-to-agent reservation flow into a dedicated
/// "Demo · Dinner reservation" conversation. Optimized for screen recording:
/// realistic pacing, clear arc (plan → consent → agent handshake → commitment
/// → post-commitment ETA update).
@MainActor
public final class DemoReservationDriver {
    public static let conversationTitle = "Demo · Dinner reservation"
    public static let conversationIDKey = "teale.demoReservationConversationID"

    /// Hardcoded "participant" IDs so the same demo looks consistent across launches.
    public static let alexID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    public static let jamieID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
    public static let samID = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!

    private weak var chatService: ChatService?
    private var isRunning = false

    public init(chatService: ChatService) {
        self.chatService = chatService
    }

    // MARK: - Seed the demo conversation (idempotent)

    public static func ensureConversationExists(chatService: ChatService, currentUserID: UUID) async -> UUID {
        if let raw = UserDefaults.standard.string(forKey: conversationIDKey),
           let id = UUID(uuidString: raw),
           chatService.conversations.contains(where: { $0.id == id }) {
            // Wipe any stale demo messages from a prior app session. The demo
            // is purely ephemeral now — messages replay on each Play demo press.
            await chatService.resetConversationMessages(conversationID: id)
            return id
        }
        let created = await chatService.createGroup(
            title: conversationTitle,
            memberIDs: [],
            agentConfig: AgentConfig(autoRespond: false, mentionOnly: true, persona: "assistant")
        )
        let id = created?.id ?? UUID()
        UserDefaults.standard.set(id.uuidString, forKey: conversationIDKey)
        return id
    }

    // MARK: - Run the scripted arc

    public func run(conversationID: UUID) async {
        guard !isRunning, let chatService else { return }
        isRunning = true
        defer { isRunning = false }

        // Open the conversation so the UI reflects each insertion.
        if let conversation = chatService.conversations.first(where: { $0.id == conversationID }) {
            await chatService.openConversation(conversation)
        }

        // Reset the conversation so the demo replays cleanly every time
        // (demo messages are in-memory only, but any old persisted entries
        // from prior builds would otherwise show up as "missing key" stubs).
        await chatService.resetConversationMessages(conversationID: conversationID)

        // Phase 0 — Multi-day planning (Monday, 4 days before)
        await sendSystem("— Monday · 4 days before —", conversationID: conversationID)
        await pause(0.8)
        await send(.human(Self.alexID, "Alex"), "anyone free for dinner this week?", to: conversationID)
        await pause(0.9)
        await send(.human(Self.jamieID, "Jamie"), "yes please, been too long", to: conversationID)
        await pause(0.7)
        await send(.human(Self.samID, "Sam"), "need it 😩 work's been brutal", to: conversationID)
        await pause(0.9)
        await send(.human(Self.alexID, "Alex"), "@teale check all our calendars for a good night this week", to: conversationID)
        await pause(1.4)
        await sendAgent(
            "Scanning all 4 calendars…\n\nThursday evening is the clearest fit — everyone's free from 6pm onward except Sam, who has a meeting 5–6pm at the Market St office. Friday also works. Thursday or Friday?",
            conversationID: conversationID
        )
        await pause(1.1)
        await send(.human(Self.samID, "Sam"), "thursday — my fridays are rough", to: conversationID)
        await pause(0.6)
        await send(.human(Self.jamieID, "Jamie"), "thursday ✅", to: conversationID)
        await pause(0.6)
        await send(.human(Self.alexID, "Alex"), "thursday it is. @teale pick us a restaurant", to: conversationID)
        await pause(1.6)
        await sendAgent(
            "Based on your group's history for a Thursday 7pm dinner:\n\n• TrueFood — shellfish-safe tasting menu (for Jamie), 2 of you are returning guests (−10% house wine)\n• Kaya — new veggie Thai, close to Jamie's apartment\n• Osteria Lina — your usual, last visit 3 weeks ago",
            conversationID: conversationID
        )
        await pause(1.1)
        await send(.human(Self.samID, "Sam"), "truefood — that chef's tasting is unreal", to: conversationID)
        await pause(0.6)
        await send(.human(Self.jamieID, "Jamie"), "truefood ✅", to: conversationID)
        await pause(0.6)
        await send(.human(Self.alexID, "Alex"), "truefood. @teale book a table for 4 at 7pm", to: conversationID)
        await pause(1.4)
        await sendAgent(
            "One heads-up before I book: Sam — your 5–6pm meeting + Market St traffic usually puts you ~10 min behind for a 7pm downtown. I can push the reservation to 7:15, or book at 7 and pre-flag a likely-late arrival to the venue. Which?",
            conversationID: conversationID
        )
        await pause(1.0)
        await send(.human(Self.samID, "Sam"), "7 is fine, i'll sprint. pre-flag it 🙏", to: conversationID)
        await pause(0.6)
        await send(.human(Self.alexID, "Alex"), "👍 do it", to: conversationID)
        await pause(1.0)

        // Phase 2: Teale proposes disclosure scope
        await sendAgent("Reaching out to TrueFood's agent. I'll share only what helps them confirm — here's the scope:", conversationID: conversationID)
        await pause(0.8)
        await sendDisclosureConsent(
            counterparty: "TrueFood Agent",
            disclosures: [
                "Party size (4)",
                "Dietary restrictions (1 vegetarian, 1 shellfish allergy)",
                "Past visits (2 of 4 are returning guests)",
                "Proof-of-funds ≥ $200 (attested, balance not shared)"
            ],
            conversationID: conversationID
        )
        await pause(1.6)

        // Phase 3: user approves
        await send(.human(Self.alexID, "Alex"), "👍 share it", to: conversationID)
        await pause(0.7)

        // Phase 4: outbound agent request with structured context
        await sendAgentExchange(
            AgentExchange(
                direction: .outbound,
                counterpartyName: "TrueFood Agent",
                headline: "Requesting reservation",
                payload: [
                    "party": "4",
                    "time": "Thursday 19:00",
                    "dietary": "1 vegetarian, 1 shellfish allergy",
                    "past_visits": "2 of 4",
                    "budget_attestation": "≥ $200 (verified)",
                    "late_arrival_flag": "1 guest likely +10 min (prior meeting)"
                ]
            ),
            conversationID: conversationID
        )
        await pause(1.8)

        // Phase 5: inbound agent response with commitment + reciprocal context
        await sendAgentExchange(
            AgentExchange(
                direction: .inbound,
                counterpartyName: "TrueFood Agent",
                headline: "Reservation confirmed",
                payload: [
                    "table": "7:00 PM · window booth",
                    "held_until": "7:20 PM grace (flag accommodated)",
                    "specials": "Chef's shellfish-safe tasting (5 courses)",
                    "advisory": "Valet full — rideshare recommended",
                    "loyalty": "Returning guests: -10% house wine"
                ]
            ),
            conversationID: conversationID
        )
        await pause(1.0)

        // Phase 6: Teale summarizes for humans
        await sendAgent(
            "Booked — Thursday 7pm, window booth for 4. Chef has a shellfish-safe tasting menu if you want to pre-order. Heads up: valet is full, plan on rideshare. Returning guests get 10% off house wine 🍷 Sam's late-arrival flag is in — the table's held until 7:20 by default.",
            conversationID: conversationID
        )
        await pause(0.9)
        await send(.human(Self.jamieID, "Jamie"), "nice — let's do the tasting menu", to: conversationID)
        await pause(0.7)
        await send(.human(Self.samID, "Sam"), "🙌", to: conversationID)
        await pause(1.2)

        // Phase 6.5: day-of proactive reminder
        await sendSystem("— Thursday · 5:30 PM · day of dinner —", conversationID: conversationID)
        await pause(0.8)
        await sendAgent(
            "Reservation in 90 min. Sam — your 5pm meeting just started, I'm watching the clock and will auto-notify TrueFood if you run past 6. Everyone else: rideshare recommended (valet's still full).",
            conversationID: conversationID
        )
        await pause(1.4)

        // Phase 7: post-commitment — ETA update (the flag pays off)
        await sendSystem("— 6:45 PM —", conversationID: conversationID)
        await pause(0.8)
        await send(.human(Self.samID, "Sam"), "meeting ran over + Market St is a parking lot 😬", to: conversationID)
        await pause(0.7)
        await sendAgent("Already in your pre-flagged window — extending the hold from +10 to +15 min with TrueFood now.", conversationID: conversationID)
        await pause(0.9)

        // Phase 8: another agent exchange on the persistent channel
        await sendAgentExchange(
            AgentExchange(
                direction: .outbound,
                counterpartyName: "TrueFood Agent",
                headline: "ETA update",
                payload: [
                    "delay": "+15 min",
                    "new_arrival": "7:15 PM",
                    "party_change": "none"
                ]
            ),
            conversationID: conversationID
        )
        await pause(1.4)
        await sendAgentExchange(
            AgentExchange(
                direction: .inbound,
                counterpartyName: "TrueFood Agent",
                headline: "Acknowledged",
                payload: [
                    "hold_extended_until": "7:30 PM",
                    "note": "Kitchen notified — tasting menu will time to arrival"
                ]
            ),
            conversationID: conversationID
        )
        await pause(0.8)
        await sendAgent("Table held until 7:30. Chef's re-timing your tasting menu. Drive safe 👋", conversationID: conversationID)

        // =============================================================
        // Phase 9: 5-min-to-reservation check-in from the restaurant agent
        // =============================================================
        await pause(1.2)
        await sendSystem("— 7:10 PM · 5 min to reservation —", conversationID: conversationID)
        await pause(0.8)
        await sendAgentExchange(
            AgentExchange(
                direction: .inbound,
                counterpartyName: "TrueFood Agent",
                headline: "Headcount check-in",
                payload: [
                    "question": "Missing guests? Current ETA?",
                    "tables_waiting_behind_you": "2"
                ]
            ),
            conversationID: conversationID
        )
        await pause(1.0)
        await sendAgentExchange(
            AgentExchange(
                direction: .outbound,
                counterpartyName: "TrueFood Agent",
                headline: "ETA report",
                payload: [
                    "on_site": "3 of 4 (Alex, Sam, you)",
                    "in_transit": "Jamie — 5 min out",
                    "traffic_note": "slow on Main St"
                ]
            ),
            conversationID: conversationID
        )
        await pause(1.2)
        await sendAgentExchange(
            AgentExchange(
                direction: .inbound,
                counterpartyName: "TrueFood Agent",
                headline: "Kitchen synced",
                payload: [
                    "first_course_fires_at": "7:25 PM",
                    "delay_accepted": "+10 min (traffic)",
                    "bread_basket": "going out now so you don't wait dry"
                ]
            ),
            conversationID: conversationID
        )
        await pause(0.7)
        await sendAgent("Kitchen is pacing around Jamie's arrival — first course fires at 7:25. Bread's on its way.", conversationID: conversationID)

        // =============================================================
        // Phase 10: during the meal — chef check-in + photos in the group
        // =============================================================
        await pause(1.4)
        await sendSystem("— 8:15 PM · during dinner —", conversationID: conversationID)
        await pause(0.7)
        await send(.human(Self.jamieID, "Jamie"), "finally made it 🙇‍♀️ these arancini are unreal", to: conversationID)
        await pause(0.7)
        await send(.human(Self.alexID, "Alex"), "📷 appetizers hitting the table", to: conversationID)
        await pause(0.9)
        await send(.human(Self.samID, "Sam"), "📷 whole crew, finally", to: conversationID)
        await pause(1.1)
        await sendAgentExchange(
            AgentExchange(
                direction: .inbound,
                counterpartyName: "TrueFood Agent",
                headline: "Chef check-in",
                payload: [
                    "question": "Anything we should adjust?",
                    "courses_delivered": "2 of 5",
                    "next_up": "sea bass (shellfish-safe plating for Jamie)"
                ]
            ),
            conversationID: conversationID
        )
        await pause(1.0)
        await sendAgentExchange(
            AgentExchange(
                direction: .outbound,
                counterpartyName: "TrueFood Agent",
                headline: "Feedback",
                payload: [
                    "overall": "group is happy",
                    "one_thing": "wine pairing could arrive a touch faster",
                    "confirm_allergies": "Jamie shellfish-safe plating confirmed"
                ]
            ),
            conversationID: conversationID
        )
        await pause(0.9)
        await send(.human(Self.alexID, "Alex"), "📷 sea bass plating is art", to: conversationID)
        await pause(0.8)
        await send(.human(Self.jamieID, "Jamie"), "10/10 would return", to: conversationID)

        // =============================================================
        // Phase 11: dessert photo triggers the bill settlement flow
        // =============================================================
        await pause(1.4)
        await send(.human(Self.samID, "Sam"), "📷 dessert flight, we ate good tonight", to: conversationID)
        await pause(0.8)
        await sendAgent("Dessert shot detected — looks like you're wrapping up. Want me to settle the bill with TrueFood now?", conversationID: conversationID)
        await pause(0.8)
        await send(.human(Self.alexID, "Alex"), "yes please 🙏", to: conversationID)
        await pause(0.7)
        await sendAgentExchange(
            AgentExchange(
                direction: .outbound,
                counterpartyName: "TrueFood Agent",
                headline: "Requesting check",
                payload: [
                    "party": "4",
                    "table": "window booth",
                    "settle_via": "Sam's stored card (group cashier)"
                ]
            ),
            conversationID: conversationID
        )
        await pause(1.4)
        await sendAgentExchange(
            AgentExchange(
                direction: .inbound,
                counterpartyName: "TrueFood Agent",
                headline: "Itemized check",
                payload: [
                    "food": "$186.00",
                    "wine_pairing": "$48.00",
                    "tax": "$19.82",
                    "tip_suggested": "20% ($46.76)",
                    "subtotal": "$253.82",
                    "grand_total": "$300.58"
                ]
            ),
            conversationID: conversationID
        )
        await pause(1.0)
        await sendAgentExchange(
            AgentExchange(
                direction: .outbound,
                counterpartyName: "TrueFood Agent",
                headline: "Approving & tipping",
                payload: [
                    "approved_total": "$300.58",
                    "tip": "22% ($55.85) — above suggestion (great service)",
                    "card": "Sam (group cashier)"
                ]
            ),
            conversationID: conversationID
        )
        await pause(1.2)
        await sendAgentExchange(
            AgentExchange(
                direction: .inbound,
                counterpartyName: "TrueFood Agent",
                headline: "Payment cleared",
                payload: [
                    "charged": "$309.67",
                    "card": "Sam •••• 4821",
                    "receipt_id": "TF-22041",
                    "thank_you": "Come back for the truffle tasting next month 🍄"
                ]
            ),
            conversationID: conversationID
        )

        // =============================================================
        // Phase 12: split + reimburse the group cashier from individual wallets
        // =============================================================
        await pause(1.2)
        await sendAgent("Bill settled — $309.67 on Sam's card. Splitting per your usual group pattern (Alex hosts drinks, even split on food).", conversationID: conversationID)
        await pause(0.8)

        // The cashier reimbursement hits the group wallet as a one-shot debit
        // equal to the bill amount (group pays Sam back).
        await appendWallet(
            WalletLedgerEntry(
                conversationID: conversationID,
                authorID: Self.samID,
                kind: .debit,
                amount: 309.67,
                memo: "Reimburse Sam (group cashier) for TrueFood bill",
                payeeNodeID: "sam-wallet",
                modelID: nil,
                tokenCount: nil
            ),
            conversationID: conversationID
        )
        await pause(0.9)

        // Now each member tops the group wallet back up with their own share.
        await appendWallet(
            WalletLedgerEntry(
                conversationID: conversationID,
                authorID: Self.alexID,
                kind: .contribution,
                amount: 103.22,
                memo: "Alex's share (includes drinks round)"
            ),
            conversationID: conversationID
        )
        await pause(0.5)
        await appendWallet(
            WalletLedgerEntry(
                conversationID: conversationID,
                authorID: Self.jamieID,
                kind: .contribution,
                amount: 68.82,
                memo: "Jamie's share"
            ),
            conversationID: conversationID
        )
        await pause(0.5)
        await appendWallet(
            WalletLedgerEntry(
                conversationID: conversationID,
                authorID: Self.samID,
                kind: .contribution,
                amount: 68.82,
                memo: "Sam's share (offsets reimbursement)"
            ),
            conversationID: conversationID
        )
        await pause(0.5)
        let youID = chatService.currentUserID
        await appendWallet(
            WalletLedgerEntry(
                conversationID: conversationID,
                authorID: youID,
                kind: .contribution,
                amount: 68.81,
                memo: "Your share"
            ),
            conversationID: conversationID
        )
        await pause(1.0)

        await sendAgent(
            "Split done: Alex $103.22 (drinks), Jamie $68.82, Sam $68.82, you $68.81. Sam — your card was fronted, group wallet reimbursed you automatically. Hope dinner was perfect 🍷",
            conversationID: conversationID
        )

        // =============================================================
        // Phase 13: testimonial opt-in (agent-to-agent social proof)
        // =============================================================
        await pause(1.6)
        await sendSystem("— On the way home —", conversationID: conversationID)
        await pause(0.8)
        await sendAgentExchange(
            AgentExchange(
                direction: .inbound,
                counterpartyName: "TrueFood Agent",
                headline: "Testimonial opt-in request",
                payload: [
                    "ask": "Route future agent inquiries about your experience to you?",
                    "why": "Other diners' agents verify places before they book",
                    "frequency_cap": "You set it"
                ]
            ),
            conversationID: conversationID
        )
        await pause(1.0)
        await sendAgent(
            "TrueFood wants to add you to their testimonial network. Checking your group prefs — you're open to this when (a) the asking agent verifies identity, (b) we cap it at 2 contacts/month, (c) we only share what you consented to share tonight. Confirming.",
            conversationID: conversationID
        )
        await pause(1.0)
        await sendAgentExchange(
            AgentExchange(
                direction: .outbound,
                counterpartyName: "TrueFood Agent",
                headline: "Testimonial opt-in · scoped",
                payload: [
                    "verification_required": "counterparty agent must be signed + identity-bound",
                    "frequency_cap": "2 inquiries / month",
                    "shareable": "dietary accommodation quality, service, price-value, would-return",
                    "not_shareable": "identities, photos, financials"
                ]
            ),
            conversationID: conversationID
        )
        await pause(1.2)
        await sendAgentExchange(
            AgentExchange(
                direction: .inbound,
                counterpartyName: "TrueFood Agent",
                headline: "Added to testimonial network",
                payload: [
                    "status": "live",
                    "routing": "inquiries → your agent",
                    "perk": "10% off next visit (2 months)",
                    "revoke_any_time": "your prefs → testimonials"
                ]
            ),
            conversationID: conversationID
        )
        await pause(0.8)
        await sendAgent(
            "Added you to TrueFood's testimonial network. If another Teale user's agent asks about places like this, I can vouch without bothering the group. You can see / revoke this anytime in your preferences — and TrueFood sent a 10% off perk for the next two months 👋",
            conversationID: conversationID
        )

        // =============================================================
        // Phase 14: three days later — a silent agent-to-agent testimonial
        //           handled entirely without bothering the humans.
        // =============================================================
        await pause(1.8)
        await sendSystem("— Three days later —", conversationID: conversationID)
        await pause(0.8)
        await sendAgentExchange(
            AgentExchange(
                direction: .inbound,
                counterpartyName: "Parker Family Agent",
                headline: "Reference inquiry",
                payload: [
                    "on_behalf_of": "Parker family (verified)",
                    "scope": "date-night, shellfish allergy in party",
                    "restaurant": "TrueFood",
                    "questions": "shellfish-safe options? service attentive? worth it?"
                ]
            ),
            conversationID: conversationID
        )
        await pause(1.0)
        await sendAgentExchange(
            AgentExchange(
                direction: .outbound,
                counterpartyName: "Parker Family Agent",
                headline: "Reference shared · scoped",
                payload: [
                    "shellfish_safe": "yes — chef's dedicated tasting plating",
                    "service": "attentive; kitchen re-timed courses around our late guest",
                    "worth_it": "would return",
                    "signed_by": "your group agent (consented 3 days ago)"
                ]
            ),
            conversationID: conversationID
        )
        await pause(0.7)
        await sendSystem(
            "Handled by your agent · 1 of 2 testimonial contacts used this month · no action needed",
            conversationID: conversationID
        )
    }

    // MARK: - Wallet chip helper

    private func appendWallet(_ entry: WalletLedgerEntry, conversationID: UUID) async {
        // Record the ledger entry locally (so the UI reflects the balance) and
        // also drop a `.walletEntry` message into the chat so the chip renders
        // in-line in the visible conversation.
        chatService?.walletStore.append(entry)
        guard let data = try? JSONEncoder().encode(entry),
              let content = String(data: data, encoding: .utf8) else { return }
        await chatService?.insertDemoMessage(
            text: content,
            senderID: nil,
            messageType: .walletEntry,
            conversationID: conversationID
        )
    }

    // MARK: - Primitives

    private enum Sender {
        case human(UUID, String)
        case agent
    }

    private func send(_ sender: Sender, _ text: String, to conversationID: UUID) async {
        guard let chatService else { return }
        switch sender {
        case .human(let id, _):
            await chatService.insertDemoMessage(
                text: text,
                senderID: id,
                messageType: .text,
                conversationID: conversationID
            )
        case .agent:
            await chatService.insertAIMessage(text, conversationID: conversationID)
        }
    }

    private func sendAgent(_ text: String, conversationID: UUID) async {
        await chatService?.insertAIMessage(text, conversationID: conversationID)
    }

    private func sendSystem(_ text: String, conversationID: UUID) async {
        await chatService?.insertDemoMessage(
            text: text,
            senderID: nil,
            messageType: .system,
            conversationID: conversationID
        )
    }

    private func sendDisclosureConsent(
        counterparty: String,
        disclosures: [String],
        conversationID: UUID
    ) async {
        let consent = DisclosureConsent(counterpartyName: counterparty, disclosures: disclosures)
        guard let data = try? JSONEncoder().encode(consent),
              let content = String(data: data, encoding: .utf8) else { return }
        await chatService?.insertDemoMessage(
            text: content,
            senderID: nil,
            messageType: .disclosureConsent,
            conversationID: conversationID
        )
    }

    private func sendAgentExchange(_ exchange: AgentExchange, conversationID: UUID) async {
        guard let data = try? JSONEncoder().encode(exchange),
              let content = String(data: data, encoding: .utf8) else { return }
        let type: MessageType = exchange.direction == .outbound ? .agentRequest : .agentResponse
        await chatService?.insertDemoMessage(
            text: content,
            senderID: nil,
            messageType: type,
            conversationID: conversationID
        )
    }

    private func pause(_ seconds: Double) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }
}
