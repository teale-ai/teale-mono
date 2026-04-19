import Foundation

// MARK: - Phone Invite Token

/// A richer invitation payload that carries everything a recipient needs to
/// decrypt a group and enroll themselves without a central coordinator.
/// Encoded as base64-URL-safe JSON and embedded in `teale://invite/<token>` deep links.
public struct PhoneInviteToken: Codable, Sendable, Equatable {
    public let groupID: UUID
    public let groupTitle: String
    public let inviterID: UUID
    public let inviterName: String
    /// The invitee's phone number in E.164 (`+14155551212`) or free-form — it's
    /// a hint only; anyone with the token can join (same security model as
    /// Signal/WhatsApp group links).
    public let inviteePhone: String?
    public let createdAt: Date
    public let expiresAt: Date

    public var isExpired: Bool { Date() > expiresAt }

    public init(
        groupID: UUID,
        groupTitle: String,
        inviterID: UUID,
        inviterName: String,
        inviteePhone: String? = nil,
        createdAt: Date = Date(),
        expiresAt: Date = Date().addingTimeInterval(7 * 24 * 3600)
    ) {
        self.groupID = groupID
        self.groupTitle = groupTitle
        self.inviterID = inviterID
        self.inviterName = inviterName
        self.inviteePhone = inviteePhone
        self.createdAt = createdAt
        self.expiresAt = expiresAt
    }
}

// MARK: - Invitation Service

/// Manages group invitations. Two flavors:
///   1. `GroupInvitation` — legacy lightweight token (still supported on receive)
///   2. `PhoneInviteToken` — the new invite-a-phone flow with deep-link sharing
public final class InvitationService: Sendable {
    private let currentUserID: UUID

    public init(currentUserID: UUID) {
        self.currentUserID = currentUserID
    }

    // MARK: - Legacy (kept for compat)

    public func createInvitation(groupID: UUID, groupTitle: String) -> GroupInvitation {
        GroupInvitation(
            id: UUID(),
            groupID: groupID,
            groupTitle: groupTitle,
            inviterID: currentUserID,
            createdAt: Date()
        )
    }

    public func encode(_ invitation: GroupInvitation) -> String? {
        guard let data = try? JSONEncoder().encode(invitation) else { return nil }
        return data.base64EncodedString()
    }

    public func decode(_ token: String) -> GroupInvitation? {
        guard let data = Data(base64Encoded: token) else { return nil }
        return try? JSONDecoder().decode(GroupInvitation.self, from: data)
    }

    // MARK: - Phone Invites

    /// Create a phone-targeted invite for a group. The phone number is a hint —
    /// the recipient just needs the token to join.
    public func createPhoneInvite(
        groupID: UUID,
        groupTitle: String,
        inviterName: String,
        inviteePhone: String?
    ) -> PhoneInviteToken {
        PhoneInviteToken(
            groupID: groupID,
            groupTitle: groupTitle,
            inviterID: currentUserID,
            inviterName: inviterName,
            inviteePhone: inviteePhone
        )
    }

    /// Encode a phone invite to a URL-safe string for embedding in a deep link.
    public func encodePhoneInvite(_ token: PhoneInviteToken) -> String? {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(token) else { return nil }
        return data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Decode a phone invite from a URL-safe string.
    public func decodePhoneInvite(_ encoded: String) -> PhoneInviteToken? {
        var padded = encoded
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        // Re-pad base64.
        while padded.count % 4 != 0 { padded.append("=") }
        guard let data = Data(base64Encoded: padded) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(PhoneInviteToken.self, from: data)
    }

    /// Full deep-link URL suitable for sharing via iMessage/SMS/etc.
    public func deepLink(for token: PhoneInviteToken) -> URL? {
        guard let encoded = encodePhoneInvite(token) else { return nil }
        return URL(string: "teale://invite/\(encoded)")
    }

    /// Parse an incoming `teale://invite/<encoded>` URL back into a phone invite.
    public func parseDeepLink(_ url: URL) -> PhoneInviteToken? {
        guard url.scheme == "teale", url.host == "invite" else { return nil }
        let encoded = url.pathComponents.last.flatMap { $0.isEmpty ? nil : $0 }
            ?? url.lastPathComponent
        guard !encoded.isEmpty else { return nil }
        return decodePhoneInvite(encoded)
    }

    /// Pretty-format a phone number as best we can without a full libphonenumber dep.
    public static func formatPhone(_ raw: String) -> String {
        let digits = raw.filter(\.isNumber)
        // US-ish default: +1 (NNN) NNN-NNNN
        if digits.count == 11, digits.first == "1" {
            let area = digits.dropFirst().prefix(3)
            let mid = digits.dropFirst(4).prefix(3)
            let last = digits.suffix(4)
            return "+1 (\(area)) \(mid)-\(last)"
        }
        if digits.count == 10 {
            let area = digits.prefix(3)
            let mid = digits.dropFirst(3).prefix(3)
            let last = digits.suffix(4)
            return "(\(area)) \(mid)-\(last)"
        }
        return raw
    }
}

// MARK: - Legacy token

/// A group invitation token shared between peers (legacy format).
public struct GroupInvitation: Codable, Sendable {
    public let id: UUID
    public let groupID: UUID
    public let groupTitle: String
    public let inviterID: UUID
    public let createdAt: Date
}
