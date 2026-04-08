import Foundation
import CryptoKit

// MARK: - WAN Configuration

public struct WANConfig: Sendable {
    public var relayServerURLs: [URL]
    public var stunServerURLs: [URL]
    public var identity: WANNodeIdentity
    public var displayName: String
    public var maxWANPeers: Int
    public var maxUploadBandwidthKBs: Int
    public var maxDownloadBandwidthKBs: Int
    public var connectionTimeoutSeconds: TimeInterval
    public var heartbeatIntervalSeconds: TimeInterval

    public init(
        relayServerURLs: [URL] = [URL(string: "wss://relay.teale.com/ws")!],
        stunServerURLs: [URL] = [
            URL(string: "stun://stun.l.google.com:19302")!,
            URL(string: "stun://stun1.l.google.com:19302")!,
        ],
        identity: WANNodeIdentity,
        displayName: String = "",
        maxWANPeers: Int = 16,
        maxUploadBandwidthKBs: Int = 10_000,
        maxDownloadBandwidthKBs: Int = 50_000,
        connectionTimeoutSeconds: TimeInterval = 30,
        heartbeatIntervalSeconds: TimeInterval = 15
    ) {
        self.relayServerURLs = relayServerURLs
        self.stunServerURLs = stunServerURLs
        self.identity = identity
        self.displayName = displayName.isEmpty ? (Host.current().localizedName ?? "Mac") : displayName
        self.maxWANPeers = maxWANPeers
        self.maxUploadBandwidthKBs = maxUploadBandwidthKBs
        self.maxDownloadBandwidthKBs = maxDownloadBandwidthKBs
        self.connectionTimeoutSeconds = connectionTimeoutSeconds
        self.heartbeatIntervalSeconds = heartbeatIntervalSeconds
    }
}

// MARK: - WAN Node Identity (Ed25519 keypair via CryptoKit)

public struct WANNodeIdentity: Sendable {
    public let privateKey: Curve25519.Signing.PrivateKey
    public let publicKey: Curve25519.Signing.PublicKey

    /// Hex-encoded public key serving as node ID
    public var nodeID: String {
        publicKey.rawRepresentation.map { String(format: "%02x", $0) }.joined()
    }

    /// Generate a new random identity
    public init() {
        self.privateKey = Curve25519.Signing.PrivateKey()
        self.publicKey = privateKey.publicKey
    }

    /// Restore from a raw private key
    public init(privateKeyData: Data) throws {
        self.privateKey = try Curve25519.Signing.PrivateKey(rawRepresentation: privateKeyData)
        self.publicKey = privateKey.publicKey
    }

    /// Sign data with this identity's private key
    public func sign(_ data: Data) throws -> Data {
        try privateKey.signature(for: data)
    }

    /// Verify a signature against a public key
    public static func verify(
        signature: Data,
        data: Data,
        publicKey: Curve25519.Signing.PublicKey
    ) -> Bool {
        publicKey.isValidSignature(signature, for: data)
    }

    /// Verify a signature against a hex-encoded public key
    public static func verify(
        signature: Data,
        data: Data,
        publicKeyHex: String
    ) -> Bool {
        guard let keyData = Data(hexString: publicKeyHex),
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData)
        else { return false }
        return key.isValidSignature(signature, for: data)
    }

    // MARK: - File-based persistence (~/Library/Application Support/Teale/)

    private static let identityFileName = "wan-identity.key"

    private static var identityFileURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("Teale", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(identityFileName)
    }

    /// Load identity from disk, or generate and store a new one
    public static func loadOrCreate() throws -> WANNodeIdentity {
        if let existing = try? loadFromFile() {
            return existing
        }
        let identity = WANNodeIdentity()
        try saveToFile(identity)
        return identity
    }

    /// Load the private key from file
    public static func loadFromFile() throws -> WANNodeIdentity {
        let url = identityFileURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw WANError.identityLoadFailed
        }
        let data = try Data(contentsOf: url)
        return try WANNodeIdentity(privateKeyData: data)
    }

    /// Save the private key to file (owner-only permissions)
    public static func saveToFile(_ identity: WANNodeIdentity) throws {
        let data = identity.privateKey.rawRepresentation
        let url = identityFileURL
        try data.write(to: url, options: [.atomic, .completeFileProtection])
        // Restrict to owner read/write (0600)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path
        )
    }
}

// MARK: - WAN Errors

public enum WANError: LocalizedError, Sendable {
    case identityLoadFailed
    case identitySaveFailed
    case relayConnectionFailed(String)
    case relayMessageFailed(String)
    case stunFailed(String)
    case natTraversalFailed(String)
    case peerConnectionFailed(String)
    case peerDisconnected
    case noWANPeerAvailable
    case authenticationFailed
    case timeout
    case invalidPublicKey

    public var errorDescription: String? {
        switch self {
        case .identityLoadFailed: return "Failed to load WAN identity from disk"
        case .identitySaveFailed: return "Failed to save WAN identity to disk"
        case .relayConnectionFailed(let msg): return "Relay connection failed: \(msg)"
        case .relayMessageFailed(let msg): return "Relay message failed: \(msg)"
        case .stunFailed(let msg): return "STUN request failed: \(msg)"
        case .natTraversalFailed(let msg): return "NAT traversal failed: \(msg)"
        case .peerConnectionFailed(let msg): return "Peer connection failed: \(msg)"
        case .peerDisconnected: return "WAN peer disconnected"
        case .noWANPeerAvailable: return "No WAN peer available for this request"
        case .authenticationFailed: return "Peer authentication failed"
        case .timeout: return "Operation timed out"
        case .invalidPublicKey: return "Invalid public key"
        }
    }
}

// MARK: - Hex Data Extension

extension Data {
    init?(hexString: String) {
        let hex = hexString.dropFirst(hexString.hasPrefix("0x") ? 2 : 0)
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
}
