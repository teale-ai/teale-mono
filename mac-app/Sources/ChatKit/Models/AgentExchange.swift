import Foundation

// MARK: - Agent Exchange

public enum AgentExchangeDirection: String, Codable, Sendable {
    case outbound  // our agent → their agent
    case inbound   // their agent → our agent
}

/// A single structured message in an agent-to-agent channel. Encoded as JSON
/// and carried in a `Message` with `messageType == .agentRequest` (outbound)
/// or `.agentResponse` (inbound).
public struct AgentExchange: Codable, Sendable, Equatable {
    public let id: UUID
    public let direction: AgentExchangeDirection
    /// Display name of the other side: "TrueFood Agent", "Alice's Agent", etc.
    public let counterpartyName: String
    /// Short verb phrase shown in the chip: "Requesting reservation", "Confirming", "ETA update".
    public let headline: String
    /// Key-value pairs shown in the expanded chip view. Kept simple for demo rendering.
    public let payload: [String: String]
    public let createdAt: Date

    public init(
        id: UUID = UUID(),
        direction: AgentExchangeDirection,
        counterpartyName: String,
        headline: String,
        payload: [String: String] = [:],
        createdAt: Date = Date()
    ) {
        self.id = id
        self.direction = direction
        self.counterpartyName = counterpartyName
        self.headline = headline
        self.payload = payload
        self.createdAt = createdAt
    }
}

// MARK: - Disclosure Consent

public struct DisclosureConsent: Codable, Sendable, Equatable {
    /// Who the agent wants to share context with ("TrueFood Agent").
    public let counterpartyName: String
    /// Human-readable disclosure items ("Party size", "Dietary restrictions", "Proof-of-funds ≥ $200").
    public let disclosures: [String]
    /// Was the user's response recorded? If `nil`, the consent is still pending.
    public var decision: Bool?

    public init(counterpartyName: String, disclosures: [String], decision: Bool? = nil) {
        self.counterpartyName = counterpartyName
        self.disclosures = disclosures
        self.decision = decision
    }
}
