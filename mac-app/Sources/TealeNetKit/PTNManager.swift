import Foundation
import CryptoKit
import SharedTypes

// MARK: - PTN Manager

/// Top-level PTN coordinator. Manages memberships, handles create/join/invite flows.
@Observable
public final class PTNManager: @unchecked Sendable {
    public private(set) var memberships: [PTNMembershipInfo] = []

    private let store = PTNStore()

    /// The local node's identity (Ed25519 public key hex).
    public let localNodeID: String
    public let localDisplayName: String

    /// Pending join requests from other nodes (inviter side).
    public private(set) var pendingJoinRequests: [PTNJoinRequestPayload] = []

    public init(localNodeID: String, localDisplayName: String) {
        self.localNodeID = localNodeID
        self.localDisplayName = localDisplayName
    }

    /// Load all persisted PTN memberships on startup.
    public func loadMemberships() async {
        do {
            memberships = try await store.loadAll()
        } catch {
            FileHandle.standardError.write(Data("[PTN] Failed to load memberships: \(error.localizedDescription)\n".utf8))
        }
    }

    /// Active PTN identifiers for broadcasting in WAN capabilities.
    public var activePTNIDs: [PTNIdentifier] {
        memberships.filter(\.isCertificateValid).map(\.identifier)
    }

    // MARK: - Create PTN

    /// Create a new PTN. This device becomes the admin and holds the CA private key.
    public func createPTN(name: String) async throws -> PTNMembershipInfo {
        let ca = PTNCertificateAuthority()

        // Self-sign an admin certificate for the creator
        let certificate = try ca.issueCertificate(
            nodeID: localNodeID,
            role: .admin,
            issuerNodeID: localNodeID
        )

        let membership = PTNMembershipInfo(
            ptnID: ca.ptnID,
            ptnName: name,
            caPublicKeyHex: ca.ptnID,
            certificate: certificate,
            role: .admin,
            isCreator: true
        )

        // Persist membership and CA key
        try await store.save(membership)
        try await store.saveCAKey(ca.privateKeyData, ptnID: ca.ptnID)

        memberships.append(membership)
        return membership
    }

    // MARK: - Generate Invite

    /// Generate an invite code for a PTN this device administers.
    public func generateInviteToken(ptnID: String, validForSeconds: TimeInterval = 3600) throws -> String {
        guard let membership = memberships.first(where: { $0.ptnID == ptnID }) else {
            throw PTNError.ptnNotFound
        }
        guard membership.role == .admin else {
            throw PTNError.notPTNAdmin
        }

        let token = PTNInviteToken(
            ptnID: ptnID,
            ptnName: membership.ptnName,
            inviterNodeID: localNodeID,
            validForSeconds: validForSeconds
        )
        return try token.encode()
    }

    // MARK: - Handle Join Request (inviter side)

    /// Process a join request from a remote node. Called when a PTNJoinRequestPayload arrives.
    /// Returns the signed certificate to send back, or throws if rejected.
    public func handleJoinRequest(_ request: PTNJoinRequestPayload) async throws -> PTNJoinResponsePayload {
        let ptnID = request.inviteToken.ptnID

        guard let membership = memberships.first(where: { $0.ptnID == ptnID }) else {
            throw PTNError.ptnNotFound
        }
        guard membership.role == .admin || membership.isCreator else {
            throw PTNError.notPTNAdmin
        }

        // Load CA key to sign the certificate
        guard let caKeyData = try await store.loadCAKey(ptnID: ptnID) else {
            throw PTNError.caKeyNotFound
        }
        let ca = try PTNCertificateAuthority(privateKeyData: caKeyData)

        // Verify the invite token is for this PTN and not expired
        guard request.inviteToken.ptnID == ptnID, !request.inviteToken.isExpired else {
            throw PTNError.inviteExpired
        }

        // Issue certificate for the joiner
        let certificate = try ca.issueCertificate(
            nodeID: request.joinerNodeID,
            role: .provider,  // Default role for new members
            issuerNodeID: localNodeID
        )

        return PTNJoinResponsePayload(
            certificate: certificate,
            ptnName: membership.ptnName,
            caPublicKeyHex: membership.caPublicKeyHex
        )
    }

    // MARK: - Join PTN (joiner side, after receiving response)

    /// Complete the join flow after receiving a signed certificate from the inviter.
    public func completeJoin(response: PTNJoinResponsePayload) async throws -> PTNMembershipInfo {
        // Verify the certificate
        guard response.accepted else {
            throw PTNError.joinRejected
        }
        guard response.certificate.verify(caPublicKeyHex: response.caPublicKeyHex) else {
            throw PTNError.certificateVerificationFailed
        }
        guard response.certificate.payload.nodeID == localNodeID else {
            throw PTNError.certificateVerificationFailed
        }

        let membership = PTNMembershipInfo(
            ptnID: response.certificate.payload.ptnID,
            ptnName: response.ptnName,
            caPublicKeyHex: response.caPublicKeyHex,
            certificate: response.certificate,
            role: response.certificate.payload.role,
            isCreator: false
        )

        try await store.save(membership)
        memberships.append(membership)
        return membership
    }

    // MARK: - Leave PTN

    /// Leave a PTN and delete local membership data.
    public func leavePTN(ptnID: String) async throws {
        try await store.delete(ptnID: ptnID)
        memberships.removeAll { $0.ptnID == ptnID }
    }

    // MARK: - Verification

    /// Verify a remote peer's PTN certificate.
    public func verifyCertificate(_ cert: PTNCertificate, forPTN ptnID: String) -> Bool {
        guard let membership = memberships.first(where: { $0.ptnID == ptnID }) else {
            return false
        }
        return cert.verify(caPublicKeyHex: membership.caPublicKeyHex) && cert.isValid
    }

    /// Get this device's certificate for a specific PTN (for sending to peers).
    public func certificateForPTN(_ ptnID: String) -> PTNCertificate? {
        memberships.first(where: { $0.ptnID == ptnID })?.certificate
    }

    /// Check if this device is a member of a PTN.
    public func isMember(of ptnID: String) -> Bool {
        memberships.contains { $0.ptnID == ptnID && $0.isCertificateValid }
    }

    // MARK: - Multi-Admin

    /// Export the CA private key for a PTN (so another admin can import it).
    /// Only the creator or an existing admin with the CA key can do this.
    public func exportCAKey(ptnID: String) async throws -> Data {
        guard let membership = memberships.first(where: { $0.ptnID == ptnID }) else {
            throw PTNError.ptnNotFound
        }
        guard membership.role == .admin else {
            throw PTNError.notPTNAdmin
        }
        guard let keyData = try await store.loadCAKey(ptnID: ptnID) else {
            throw PTNError.caKeyNotFound
        }
        return keyData
    }

    /// Import a CA private key to become an admin of a PTN this device already belongs to.
    /// The device must already be a member (have a valid certificate).
    public func importCAKey(_ keyData: Data, ptnID: String) async throws {
        guard var membership = memberships.first(where: { $0.ptnID == ptnID }) else {
            throw PTNError.ptnNotFound
        }

        // Verify the key matches the PTN's CA public key
        let ca = try PTNCertificateAuthority(privateKeyData: keyData)
        guard ca.ptnID == ptnID else {
            throw PTNError.certificateVerificationFailed
        }

        // Save the CA key and upgrade role to admin
        try await store.saveCAKey(keyData, ptnID: ptnID)
        membership.role = .admin
        membership.isCreator = false // Not the original creator, but now an admin
        try await store.save(membership)

        if let idx = memberships.firstIndex(where: { $0.ptnID == ptnID }) {
            memberships[idx] = membership
        }
    }

    /// Promote a remote device to admin by issuing an admin certificate and
    /// returning the CA key for them to import.
    /// Returns (certificate JSON, CA key data) — caller sends both to the target device.
    public func promoteToAdmin(ptnID: String, targetNodeID: String) async throws -> (certData: Data, caKeyData: Data) {
        guard let membership = memberships.first(where: { $0.ptnID == ptnID }) else {
            throw PTNError.ptnNotFound
        }
        guard membership.role == .admin else {
            throw PTNError.notPTNAdmin
        }
        guard let caKeyData = try await store.loadCAKey(ptnID: ptnID) else {
            throw PTNError.caKeyNotFound
        }

        let ca = try PTNCertificateAuthority(privateKeyData: caKeyData)
        let cert = try ca.issueCertificate(
            nodeID: targetNodeID,
            role: .admin,
            issuerNodeID: localNodeID
        )

        let response = PTNJoinResponsePayload(
            certificate: cert,
            ptnName: membership.ptnName,
            caPublicKeyHex: membership.caPublicKeyHex
        )
        let certJSON = try JSONEncoder().encode(response)

        return (certData: certJSON, caKeyData: caKeyData)
    }

    // MARK: - Recovery (all admins lost)

    /// Recover a PTN when all admin devices are gone.
    /// Creates a new CA keypair (new PTN ID), preserves the name, and
    /// auto-issues certificates for all known member node IDs.
    /// The recovering device becomes the new admin.
    ///
    /// Returns the new PTN membership and certificates for known members
    /// (caller should distribute these to the other members).
    /// Minimum days all admins must be absent before recovery is allowed.
    public static let recoveryGracePeriodDays: Int = 30

    public func recoverPTN(oldPTNID: String) async throws -> (newMembership: PTNMembershipInfo, memberCerts: [String: Data]) {
        guard let oldMembership = memberships.first(where: { $0.ptnID == oldPTNID }) else {
            throw PTNError.ptnNotFound
        }

        // Time gate: all admins must have been absent for 30+ days
        if let lastSeen = oldMembership.lastAdminSeenAt {
            let daysSinceAdmin = Date().timeIntervalSince(lastSeen) / 86400
            if daysSinceAdmin < Double(Self.recoveryGracePeriodDays) {
                let remaining = Self.recoveryGracePeriodDays - Int(daysSinceAdmin)
                throw PTNError.recoveryTooEarly(daysRemaining: remaining)
            }
        } else {
            // No admin ever seen — only allow if this device has been a member for 30+ days
            let daysSinceJoin = Date().timeIntervalSince(oldMembership.joinedAt) / 86400
            if daysSinceJoin < Double(Self.recoveryGracePeriodDays) {
                let remaining = Self.recoveryGracePeriodDays - Int(daysSinceJoin)
                throw PTNError.recoveryTooEarly(daysRemaining: remaining)
            }
        }

        let knownMembers = oldMembership.knownMemberNodeIDs ?? []

        // Create a new CA (new PTN ID, same name)
        let ca = PTNCertificateAuthority()

        // Self-sign admin cert for the recovering device
        let adminCert = try ca.issueCertificate(
            nodeID: localNodeID,
            role: .admin,
            issuerNodeID: localNodeID
        )

        let newMembership = PTNMembershipInfo(
            ptnID: ca.ptnID,
            ptnName: oldMembership.ptnName,
            caPublicKeyHex: ca.ptnID,
            certificate: adminCert,
            role: .admin,
            isCreator: true,
            knownMemberNodeIDs: knownMembers
        )

        // Persist new PTN
        try await store.save(newMembership)
        try await store.saveCAKey(ca.privateKeyData, ptnID: ca.ptnID)

        // Remove old PTN
        try await store.delete(ptnID: oldPTNID)
        memberships.removeAll { $0.ptnID == oldPTNID }
        memberships.append(newMembership)

        // Issue certs for known members
        var memberCerts: [String: Data] = [:]
        for nodeID in knownMembers where nodeID != localNodeID {
            let cert = try ca.issueCertificate(
                nodeID: nodeID,
                role: .provider,
                issuerNodeID: localNodeID
            )
            let response = PTNJoinResponsePayload(
                certificate: cert,
                ptnName: newMembership.ptnName,
                caPublicKeyHex: ca.ptnID
            )
            memberCerts[nodeID] = try JSONEncoder().encode(response)
        }

        return (newMembership: newMembership, memberCerts: memberCerts)
    }

    // MARK: - Member Tracking

    /// Update known members for a PTN (called when heartbeats reveal peer PTN membership).
    public func updateKnownMembers(ptnID: String, memberNodeIDs: [String]) async {
        guard var membership = memberships.first(where: { $0.ptnID == ptnID }) else { return }

        var known = Set(membership.knownMemberNodeIDs ?? [])
        known.formUnion(memberNodeIDs)
        membership.knownMemberNodeIDs = Array(known)

        try? await store.save(membership)
        if let idx = memberships.firstIndex(where: { $0.ptnID == ptnID }) {
            memberships[idx] = membership
        }
    }

    /// Record that an admin was seen online for a PTN.
    /// Called when heartbeats or discovery show a peer with admin role in this PTN.
    public func updateAdminSeen(ptnID: String) async {
        guard var membership = memberships.first(where: { $0.ptnID == ptnID }) else { return }
        membership.lastAdminSeenAt = Date()
        try? await store.save(membership)
        if let idx = memberships.firstIndex(where: { $0.ptnID == ptnID }) {
            memberships[idx] = membership
        }
    }

    /// Check if recovery is available for a PTN (all admins absent for 30+ days).
    public func isRecoveryAvailable(ptnID: String) -> Bool {
        guard let membership = memberships.first(where: { $0.ptnID == ptnID }) else { return false }
        guard membership.role != .admin else { return false } // Admins don't need recovery

        if let lastSeen = membership.lastAdminSeenAt {
            return Date().timeIntervalSince(lastSeen) / 86400 >= Double(Self.recoveryGracePeriodDays)
        } else {
            return Date().timeIntervalSince(membership.joinedAt) / 86400 >= Double(Self.recoveryGracePeriodDays)
        }
    }
}
