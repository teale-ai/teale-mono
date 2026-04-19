import Foundation
import CryptoKit
import SharedTypes

// MARK: - PTN Membership Certificate

/// The payload of a PTN membership certificate (the data that gets signed).
public struct PTNCertificatePayload: Codable, Sendable {
    public var ptnID: String            // CA public key hex (= PTN ID)
    public var nodeID: String           // Member's Ed25519 public key hex
    public var role: PTNRole
    public var issuedAt: TimeInterval   // Unix timestamp
    public var expiresAt: TimeInterval? // nil = no expiry
    public var issuerNodeID: String     // Issuer's node public key hex

    public init(
        ptnID: String,
        nodeID: String,
        role: PTNRole,
        issuedAt: TimeInterval = Date().timeIntervalSince1970,
        expiresAt: TimeInterval? = nil,
        issuerNodeID: String
    ) {
        self.ptnID = ptnID
        self.nodeID = nodeID
        self.role = role
        self.issuedAt = issuedAt
        self.expiresAt = expiresAt
        self.issuerNodeID = issuerNodeID
    }
}

/// A signed PTN membership certificate. Verified against the PTN's CA public key.
public struct PTNCertificate: Codable, Sendable {
    public var payload: PTNCertificatePayload
    public var signature: String  // Hex-encoded Ed25519 signature of canonical JSON payload

    public init(payload: PTNCertificatePayload, signature: String) {
        self.payload = payload
        self.signature = signature
    }

    /// Verify this certificate's signature against a CA public key.
    public func verify(caPublicKeyHex: String) -> Bool {
        guard let keyData = Data(hexString: caPublicKeyHex),
              let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData),
              let signatureData = Data(hexString: signature),
              let canonicalBytes = try? Self.canonicalBytes(for: payload) else {
            return false
        }
        return publicKey.isValidSignature(signatureData, for: canonicalBytes)
    }

    /// Whether the certificate has expired.
    public var isExpired: Bool {
        guard let expiresAt = payload.expiresAt else { return false }
        return Date().timeIntervalSince1970 > expiresAt
    }

    /// Whether the certificate is currently valid (signature not checked here).
    public var isValid: Bool {
        !isExpired
    }

    /// Canonical bytes for signing: sorted-keys JSON of the payload.
    /// Deterministic encoding is critical for reproducible signatures.
    public static func canonicalBytes(for payload: PTNCertificatePayload) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(payload)
    }
}

// MARK: - Hex Data Extension

extension Data {
    /// Initialize from a hex string (e.g. "a1b2c3").
    public init?(hexString: String) {
        let hex = hexString.lowercased()
        guard hex.count % 2 == 0 else { return nil }

        var data = Data(capacity: hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let nextIndex = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<nextIndex], radix: 16) else { return nil }
            data.append(byte)
            index = nextIndex
        }
        self = data
    }

    /// Convert to hex string.
    public var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
