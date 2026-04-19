import Foundation
import CryptoKit

// MARK: - Solana Wallet Identity (Ed25519 keypair via CryptoKit)

/// A Solana-compatible Ed25519 keypair stored on disk.
/// Uses file-based storage to avoid macOS Keychain prompts on ad-hoc signed apps.
/// The key file is stored at ~/Library/Application Support/Teale/wallet-key
/// with restrictive file permissions (owner-only read/write).
public struct SolanaIdentity: Sendable {
    public let privateKey: Curve25519.Signing.PrivateKey
    public let publicKey: Curve25519.Signing.PublicKey

    /// Solana address = Base58-encoded 32-byte public key
    public var solanaAddress: String {
        Base58.encode(Data(publicKey.rawRepresentation))
    }

    /// Hex-encoded public key (for cross-referencing with WANKit node IDs)
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

    /// Raw 64-byte Ed25519 secret key in Solana format (32-byte seed + 32-byte public key)
    public var solanaSecretKey: Data {
        var key = Data(privateKey.rawRepresentation)
        key.append(publicKey.rawRepresentation)
        return key
    }

    // MARK: - File-based Persistence (avoids Keychain prompts on unsigned/ad-hoc apps)

    private static var keyFileURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("Teale/wallet-key", isDirectory: false)
    }

    /// Load identity from disk, migrate from Keychain if needed, or generate a new one
    public static func loadOrCreate() throws -> SolanaIdentity {
        // Try file-based storage first
        if let existing = try? loadFromFile() {
            return existing
        }

        // Migrate from Keychain if an existing key is there (one-time migration)
        if let migrated = try? loadFromKeychain() {
            try? saveToFile(migrated)
            // Clean up the old Keychain entry so it won't prompt again
            deleteFromKeychain()
            return migrated
        }

        // Generate new
        let identity = SolanaIdentity()
        try saveToFile(identity)
        return identity
    }

    // MARK: - File Storage

    private static func loadFromFile() throws -> SolanaIdentity {
        let data = try Data(contentsOf: keyFileURL)
        return try SolanaIdentity(privateKeyData: data)
    }

    private static func saveToFile(_ identity: SolanaIdentity) throws {
        let data = identity.privateKey.rawRepresentation
        let dir = keyFileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try data.write(to: keyFileURL, options: [.atomic, .completeFileProtection])
        // Restrict to owner read/write only
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keyFileURL.path)
    }

    /// Check if a Solana wallet exists (file or Keychain)
    public static func exists() -> Bool {
        FileManager.default.fileExists(atPath: keyFileURL.path) || keychainExists()
    }

    // MARK: - Legacy Keychain (migration only)

    private static let keychainService = "com.teale.app"
    private static let keychainAccount = "solana-wallet-key"

    private static func loadFromKeychain() throws -> SolanaIdentity {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecReturnData as String: true,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            throw WalletKitError.keychainLoadFailed
        }
        return try SolanaIdentity(privateKeyData: data)
    }

    private static func deleteFromKeychain() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
        ]
        SecItemDelete(query as CFDictionary)
    }

    private static func keychainExists() -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecReturnData as String: false,
        ]
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }
}
