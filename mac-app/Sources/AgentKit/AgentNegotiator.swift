import Foundation

// MARK: - Negotiation Decision

public enum NegotiationDecision: Sendable, Equatable {
    case autoAccept
    case autoReject(reason: String)
    case askHuman(reason: String)
    case counterOffer(OfferPayload)
}

// MARK: - Agent Negotiator

public actor AgentNegotiator {

    public init() {}

    /// Evaluate an incoming offer against the intent, delegation rules, and available balance.
    public func evaluateOffer(
        offer: OfferPayload,
        intent: IntentPayload,
        rules: [DelegationRule],
        preferences: AgentPreferences,
        senderProfile: AgentDirectoryEntry?,
        creditBalance: Double
    ) -> NegotiationDecision {

        // Check if offer has expired
        if offer.validUntil < Date() {
            return .autoReject(reason: "Offer has expired")
        }

        // Check if intent has expired
        if let expiresAt = intent.expiresAt, expiresAt < Date() {
            return .autoReject(reason: "Intent has expired")
        }

        // Check credit balance
        if offer.creditCost > creditBalance {
            return .autoReject(reason: "Insufficient credit balance (\(creditBalance) available, \(offer.creditCost) required)")
        }

        // Check per-transaction budget
        if let maxBudget = preferences.maxBudgetPerTransaction, offer.creditCost > maxBudget {
            return .askHuman(reason: "Cost \(offer.creditCost) exceeds per-transaction budget of \(maxBudget)")
        }

        // Find matching delegation rule
        let matchingRule = rules.first { $0.capability == intent.category }

        guard let rule = matchingRule else {
            // No delegation rule for this capability — ask human
            return .askHuman(reason: "No delegation rule configured for capability '\(intent.category)'")
        }

        // Check if the rule requires approval
        if rule.requiresApproval {
            return .askHuman(reason: "Delegation rule requires human approval for '\(intent.category)'")
        }

        // Check rule's max credit spend
        if offer.creditCost > rule.maxSpend {
            // Try counter-offer at the max allowed
            if rule.maxSpend > 0 {
                let counter = OfferPayload(
                    intentID: offer.intentID,
                    description: offer.description,
                    creditCost: rule.maxSpend,
                    estimatedDuration: offer.estimatedDuration,
                    terms: offer.terms,
                    validUntil: offer.validUntil
                )
                return .counterOffer(counter)
            }
            return .autoReject(reason: "Cost \(offer.creditCost) exceeds delegation rule limit of \(rule.maxSpend)")
        }

        // Check allowed agent types
        if let sender = senderProfile {
            if !rule.allowedAgentTypes.contains(sender.profile.agentType) {
                return .autoReject(reason: "Agent type '\(sender.profile.agentType.rawValue)' not allowed by delegation rule")
            }
        }

        // Check intent constraints against offer terms
        if let budgetStr = intent.constraints["budget"], let budget = Double(budgetStr) {
            if offer.creditCost > budget {
                return .askHuman(reason: "Cost \(offer.creditCost) exceeds intent budget constraint of \(budget)")
            }
        }

        // Auto-negotiate is disabled — always ask
        if !preferences.autoNegotiate {
            return .askHuman(reason: "Auto-negotiation is disabled")
        }

        // All checks passed
        return .autoAccept
    }

    /// Select the best offer from multiple offers for an intent.
    public func selectBestOffer(
        offers: [OfferPayload],
        intent: IntentPayload,
        senderProfiles: [UUID: AgentDirectoryEntry]
    ) -> OfferPayload? {
        guard !offers.isEmpty else { return nil }

        // Score each offer
        let scored = offers.map { offer -> (OfferPayload, Double) in
            var score = 100.0

            // Lower cost is better
            score -= offer.creditCost

            // Higher-rated agents are better
            if let profile = senderProfiles[offer.id], let rating = profile.rating {
                score += rating * 10
            }

            // Shorter duration is better for urgent intents
            if intent.urgency >= .high, let duration = offer.estimatedDuration {
                score -= duration / 3600.0 // penalize by hours
            }

            return (offer, score)
        }

        return scored.max(by: { $0.1 < $1.1 })?.0
    }
}
