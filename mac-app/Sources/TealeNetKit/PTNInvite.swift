import Foundation
import SharedTypes

// MARK: - PTN Invite Token

/// An invite token that can be shared as a string for others to join a PTN.
/// Encoded as base64url JSON — typically 100-150 characters.
public struct PTNInviteToken: Codable, Sendable {
    public var ptnID: String
    public var ptnName: String
    public var inviterNodeID: String
    public var nonce: String            // 16 random bytes hex (prevents replay)
    public var expiresAt: TimeInterval  // Unix timestamp

    public init(
        ptnID: String,
        ptnName: String,
        inviterNodeID: String,
        validForSeconds: TimeInterval = 3600  // 1 hour default
    ) {
        self.ptnID = ptnID
        self.ptnName = ptnName
        self.inviterNodeID = inviterNodeID
        self.nonce = Self.randomNonce()
        self.expiresAt = Date().timeIntervalSince1970 + validForSeconds
    }

    /// Whether the invite has expired.
    public var isExpired: Bool {
        Date().timeIntervalSince1970 > expiresAt
    }

    /// Encode to a shareable string (base64url of JSON).
    public func encode() throws -> String {
        let data = try JSONEncoder().encode(self)
        return data.base64URLEncodedString()
    }

    /// Decode from a shareable string.
    public static func decode(from string: String) throws -> PTNInviteToken {
        guard let data = Data(base64URLEncoded: string) else {
            throw PTNError.invalidInviteCode
        }
        let token = try JSONDecoder().decode(PTNInviteToken.self, from: data)
        guard !token.isExpired else {
            throw PTNError.inviteExpired
        }
        return token
    }

    private static func randomNonce() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).hexString
    }
}

// MARK: - Join Request / Response Payloads

/// Sent by the joiner to the inviter over relay.
public struct PTNJoinRequestPayload: Codable, Sendable {
    public var inviteToken: PTNInviteToken
    public var joinerNodeID: String
    public var joinerDisplayName: String

    public init(inviteToken: PTNInviteToken, joinerNodeID: String, joinerDisplayName: String) {
        self.inviteToken = inviteToken
        self.joinerNodeID = joinerNodeID
        self.joinerDisplayName = joinerDisplayName
    }
}

/// Sent by the inviter back to the joiner with the signed certificate.
public struct PTNJoinResponsePayload: Codable, Sendable {
    public var certificate: PTNCertificate
    public var ptnName: String
    public var caPublicKeyHex: String
    public var accepted: Bool

    public init(certificate: PTNCertificate, ptnName: String, caPublicKeyHex: String, accepted: Bool = true) {
        self.certificate = certificate
        self.ptnName = ptnName
        self.caPublicKeyHex = caPublicKeyHex
        self.accepted = accepted
    }
}

// MARK: - PTN Errors

public enum PTNError: LocalizedError {
    case invalidInviteCode
    case inviteExpired
    case notPTNAdmin
    case caKeyNotFound
    case ptnNotFound
    case certificateVerificationFailed
    case joinRequestTimeout
    case joinRejected
    case recoveryTooEarly(daysRemaining: Int)

    public var errorDescription: String? {
        switch self {
        case .invalidInviteCode: return "Invalid invite code."
        case .inviteExpired: return "This invite has expired."
        case .notPTNAdmin: return "Only PTN admins can invite new members."
        case .caKeyNotFound: return "CA private key not found. Only the PTN creator can invite."
        case .ptnNotFound: return "PTN not found in your memberships."
        case .certificateVerificationFailed: return "Certificate verification failed."
        case .joinRequestTimeout: return "Join request timed out. The inviter may be offline."
        case .joinRejected: return "Join request was rejected."
        case .recoveryTooEarly(let days): return "Recovery not available yet. All admins must be absent for 30 days. \(days) day(s) remaining."
        }
    }
}

// MARK: - Base64URL Encoding

extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .trimmingCharacters(in: CharacterSet(charactersIn: "="))
    }

    init?(base64URLEncoded string: String) {
        var base64 = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = base64.count % 4
        if remainder > 0 {
            base64 += String(repeating: "=", count: 4 - remainder)
        }
        self.init(base64Encoded: base64)
    }
}
