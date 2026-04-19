import Foundation
import SharedTypes

// MARK: - PTN Membership Info

/// Complete local state for one PTN membership on this device.
public struct PTNMembershipInfo: Codable, Sendable, Identifiable {
    public var id: String { ptnID }
    public var ptnID: String              // CA public key hex (= PTN ID)
    public var ptnName: String
    public var caPublicKeyHex: String     // Same as ptnID (explicit for verification)
    public var certificate: PTNCertificate
    public var role: PTNRole
    public var isCreator: Bool            // Whether this device holds the CA private key
    public var joinedAt: Date
    /// Node IDs of known PTN members (learned from heartbeats/discovery).
    /// Used for recovery if all admins are lost.
    public var knownMemberNodeIDs: [String]?
    /// Last time ANY admin was seen online (heartbeat/discovery).
    /// Used for time-gated recovery — recovery only available after
    /// all admins have been absent for 30+ days.
    public var lastAdminSeenAt: Date?

    public init(
        ptnID: String,
        ptnName: String,
        caPublicKeyHex: String,
        certificate: PTNCertificate,
        role: PTNRole,
        isCreator: Bool,
        joinedAt: Date = Date(),
        knownMemberNodeIDs: [String]? = nil,
        lastAdminSeenAt: Date? = nil
    ) {
        self.ptnID = ptnID
        self.ptnName = ptnName
        self.caPublicKeyHex = caPublicKeyHex
        self.certificate = certificate
        self.role = role
        self.isCreator = isCreator
        self.joinedAt = joinedAt
        self.knownMemberNodeIDs = knownMemberNodeIDs
        self.lastAdminSeenAt = lastAdminSeenAt
    }

    /// Convert to a lightweight PTNIdentifier for broadcasting.
    public var identifier: PTNIdentifier {
        PTNIdentifier(ptnID: ptnID, ptnName: ptnName)
    }

    /// Verify this membership's certificate against the CA public key.
    public var isCertificateValid: Bool {
        certificate.verify(caPublicKeyHex: caPublicKeyHex) && certificate.isValid
    }
}
