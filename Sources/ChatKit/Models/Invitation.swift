import Foundation

// MARK: - Invitation Type

public enum InvitationType: String, Codable, Sendable {
    /// Invite to join a specific conversation
    case chat
    /// Invite to join the app (referral)
    case app
}

// MARK: - Invitation

public struct Invitation: Codable, Sendable, Identifiable, Equatable {
    public var id: UUID
    /// nil for app-level referrals
    public var conversationID: UUID?
    public var inviterID: UUID
    /// Short shareable code (e.g. "TEALE-A7K9")
    public var inviteCode: String
    public var inviteType: InvitationType
    public var maxUses: Int
    public var currentUses: Int
    /// Credits awarded to inviter per accepted invite
    public var creditsReward: Double
    public var expiresAt: Date
    public var createdAt: Date

    public var isExpired: Bool { Date() > expiresAt }
    public var isExhausted: Bool { currentUses >= maxUses }
    public var isValid: Bool { !isExpired && !isExhausted }

    /// Deep link URL for sharing
    public var deepLink: URL {
        URL(string: "teale://invite/\(inviteCode)")!
    }

    public init(
        id: UUID = UUID(),
        conversationID: UUID? = nil,
        inviterID: UUID,
        inviteCode: String,
        inviteType: InvitationType,
        maxUses: Int = 1,
        currentUses: Int = 0,
        creditsReward: Double = 25.0,
        expiresAt: Date = Date().addingTimeInterval(7 * 24 * 3600),
        createdAt: Date = Date()
    ) {
        self.id = id
        self.conversationID = conversationID
        self.inviterID = inviterID
        self.inviteCode = inviteCode
        self.inviteType = inviteType
        self.maxUses = maxUses
        self.currentUses = currentUses
        self.creditsReward = creditsReward
        self.expiresAt = expiresAt
        self.createdAt = createdAt
    }

    /// Generate a random invite code like "TEALE-A7K9"
    public static func generateCode() -> String {
        let chars = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789" // no ambiguous chars (0/O, 1/I/L)
        let random = (0..<4).map { _ in chars.randomElement()! }
        return "TEALE-\(String(random))"
    }

    enum CodingKeys: String, CodingKey {
        case id
        case conversationID = "conversation_id"
        case inviterID = "inviter_id"
        case inviteCode = "invite_code"
        case inviteType = "invite_type"
        case maxUses = "max_uses"
        case currentUses = "current_uses"
        case creditsReward = "credits_reward"
        case expiresAt = "expires_at"
        case createdAt = "created_at"
    }
}

// MARK: - Invitation Redemption

public struct InvitationRedemption: Codable, Sendable, Identifiable, Equatable {
    public var id: UUID
    public var invitationID: UUID
    public var redeemedBy: UUID
    public var redeemedAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case invitationID = "invitation_id"
        case redeemedBy = "redeemed_by"
        case redeemedAt = "redeemed_at"
    }
}
