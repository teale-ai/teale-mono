import Foundation
import CryptoKit
import SharedTypes

// MARK: - PTN Certificate Authority

/// Manages a PTN's CA keypair. Only exists on the creator's device.
/// The CA private key is used to sign membership certificates for new members.
public struct PTNCertificateAuthority: Sendable {
    public let privateKey: Curve25519.Signing.PrivateKey
    public let publicKey: Curve25519.Signing.PublicKey

    /// The PTN ID is the hex-encoded CA public key.
    public var ptnID: String {
        publicKey.rawRepresentation.hexString
    }

    /// Generate a new CA keypair (called when creating a new PTN).
    public init() {
        self.privateKey = Curve25519.Signing.PrivateKey()
        self.publicKey = privateKey.publicKey
    }

    /// Restore from stored private key bytes.
    public init(privateKeyData: Data) throws {
        self.privateKey = try Curve25519.Signing.PrivateKey(rawRepresentation: privateKeyData)
        self.publicKey = privateKey.publicKey
    }

    /// Raw private key bytes for persistence.
    public var privateKeyData: Data {
        privateKey.rawRepresentation
    }

    /// Issue a membership certificate for a node.
    public func issueCertificate(
        nodeID: String,
        role: PTNRole,
        issuerNodeID: String,
        expiresAt: TimeInterval? = nil
    ) throws -> PTNCertificate {
        let payload = PTNCertificatePayload(
            ptnID: ptnID,
            nodeID: nodeID,
            role: role,
            issuedAt: Date().timeIntervalSince1970,
            expiresAt: expiresAt,
            issuerNodeID: issuerNodeID
        )

        let canonicalBytes = try PTNCertificate.canonicalBytes(for: payload)
        let signatureData = try privateKey.signature(for: canonicalBytes)

        return PTNCertificate(
            payload: payload,
            signature: signatureData.hexString
        )
    }
}
