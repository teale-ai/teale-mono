import Foundation
import Supabase

// MARK: - Invitation Service

/// Manages invitation creation, sharing, and redemption.
public final class InvitationService: Sendable {
    private let client: SupabaseClient
    private let currentUserID: UUID

    init(client: SupabaseClient, currentUserID: UUID) {
        self.client = client
        self.currentUserID = currentUserID
    }

    // MARK: - Create Invitations

    /// Create a chat invite for a specific conversation
    public func createChatInvite(
        conversationID: UUID,
        maxUses: Int = 1,
        creditsReward: Double = 25.0
    ) async throws -> Invitation {
        let invitation = Invitation(
            conversationID: conversationID,
            inviterID: currentUserID,
            inviteCode: Invitation.generateCode(),
            inviteType: .chat,
            maxUses: maxUses,
            creditsReward: creditsReward
        )

        try await client.from("invitations").insert(invitation).execute()
        return invitation
    }

    /// Create an app referral invite (not tied to a conversation)
    public func createAppReferral(
        maxUses: Int = 10,
        creditsReward: Double = 25.0
    ) async throws -> Invitation {
        let invitation = Invitation(
            inviterID: currentUserID,
            inviteCode: Invitation.generateCode(),
            inviteType: .app,
            maxUses: maxUses,
            creditsReward: creditsReward
        )

        try await client.from("invitations").insert(invitation).execute()
        return invitation
    }

    // MARK: - Redeem Invitation

    /// Redeem an invitation code. Returns the conversation ID if it's a chat invite.
    public func redeemInvitation(code: String) async throws -> UUID? {
        let result: AnyJSON = try await client.rpc("redeem_invitation", params: [
            "p_invite_code": code
        ]).execute().value

        // The RPC returns a UUID (conversation_id) or null
        if case .string(let uuidString) = result, let uuid = UUID(uuidString: uuidString) {
            return uuid
        }
        return nil
    }

    // MARK: - My Invitations

    /// Fetch all invitations created by the current user
    public func myInvitations() async throws -> [Invitation] {
        try await client.from("invitations")
            .select()
            .eq("inviter_id", value: currentUserID.uuidString)
            .order("created_at", ascending: false)
            .execute()
            .value
    }
}
