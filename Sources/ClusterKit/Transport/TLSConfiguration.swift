import Foundation
import CryptoKit
import Network
import Security

// MARK: - Cluster Security

public struct ClusterSecurity: Sendable {
    /// Hash a passcode for comparison during handshake
    public static func hashPasscode(_ passcode: String) -> String {
        let data = Data(passcode.utf8)
        let hash = SHA256.hash(data: data)
        return hash.compactMap { String(format: "%02x", $0) }.joined()
    }

    /// Validate that two passcode hashes match
    public static func validatePasscode(local: String?, remote: String?) -> Bool {
        switch (local, remote) {
        case (nil, nil):
            return true  // No passcode required
        case (let l?, let r?):
            return l == r  // Both have passcode, must match
        default:
            return false  // One has passcode, other doesn't
        }
    }
}

// MARK: - Cluster TLS Manager

/// Manages TLS identity and trust-on-first-use (TOFU) peer certificate pinning
public actor ClusterTLSManager {
    private var localKeyPair: P256.Signing.PrivateKey?
    private var trustedPeerKeys: [String: Data] = [:]  // peerID -> raw public key bytes
    private let trustStorePath: URL

    public init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        self.trustStorePath = appSupport.appendingPathComponent("InferencePool/trusted_peers.json")
    }

    // MARK: - Key Management

    /// Get or create the local P256 signing key for TLS
    public func getOrCreateKey() -> P256.Signing.PrivateKey {
        if let existing = localKeyPair {
            return existing
        }
        let key = P256.Signing.PrivateKey()
        localKeyPair = key
        return key
    }

    /// Local public key fingerprint (SHA256 of raw public key)
    public var localFingerprint: String {
        let key = getOrCreateKey()
        let hash = SHA256.hash(data: key.publicKey.rawRepresentation)
        return hash.compactMap { String(format: "%02x", $0) }.joined()
    }

    // MARK: - TOFU Peer Pinning

    /// Pin a peer's public key on first contact
    public func pinPeerKey(peerID: String, publicKeyData: Data) {
        if trustedPeerKeys[peerID] == nil {
            trustedPeerKeys[peerID] = publicKeyData
            Task { try? self.saveTrustStore() }
        }
    }

    /// Verify a peer's public key against pinned key
    public func verifyPeerKey(peerID: String, publicKeyData: Data) -> TLSVerifyResult {
        guard let pinned = trustedPeerKeys[peerID] else {
            return .newPeer  // Not seen before, will be pinned
        }
        return pinned == publicKeyData ? .trusted : .mismatch
    }

    /// Remove a pinned peer key
    public func removePeerKey(peerID: String) {
        trustedPeerKeys.removeValue(forKey: peerID)
        Task { try? self.saveTrustStore() }
    }

    // MARK: - TLS Configuration

    /// Configure NWProtocolTLS.Options with custom TOFU verification
    public func configureTLSOptions() -> NWProtocolTLS.Options {
        let tlsOptions = NWProtocolTLS.Options()

        // Use custom verification that accepts self-signed certs (TOFU model)
        sec_protocol_options_set_verify_block(
            tlsOptions.securityProtocolOptions,
            { _, trust, completionHandler in
                // Accept all peers — actual trust is managed via TOFU at the application layer
                // after the Hello handshake where we exchange and pin public key fingerprints
                completionHandler(true)
            },
            DispatchQueue.global(qos: .userInitiated)
        )

        // Set minimum TLS version to 1.2
        sec_protocol_options_set_min_tls_protocol_version(
            tlsOptions.securityProtocolOptions,
            .TLSv12
        )

        return tlsOptions
    }

    // MARK: - Trust Store Persistence

    public func loadTrustStore() throws {
        guard FileManager.default.fileExists(atPath: trustStorePath.path) else { return }
        let data = try Data(contentsOf: trustStorePath)
        let store = try JSONDecoder().decode(TrustStore.self, from: data)
        trustedPeerKeys = store.peers.reduce(into: [:]) { dict, entry in
            if let keyData = Data(base64Encoded: entry.publicKeyBase64) {
                dict[entry.peerID] = keyData
            }
        }
    }

    public func saveTrustStore() throws {
        let entries = trustedPeerKeys.map { peerID, keyData in
            TrustStoreEntry(peerID: peerID, publicKeyBase64: keyData.base64EncodedString())
        }
        let store = TrustStore(peers: entries)
        let data = try JSONEncoder().encode(store)

        let dir = trustStorePath.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try data.write(to: trustStorePath, options: .atomic)
    }
}

// MARK: - TLS Types

public enum TLSVerifyResult: Sendable {
    case trusted      // Key matches pinned key
    case newPeer      // First time seeing this peer
    case mismatch     // Key doesn't match pinned key (possible MITM)
}

private struct TrustStore: Codable {
    var peers: [TrustStoreEntry]
}

private struct TrustStoreEntry: Codable {
    var peerID: String
    var publicKeyBase64: String
}
