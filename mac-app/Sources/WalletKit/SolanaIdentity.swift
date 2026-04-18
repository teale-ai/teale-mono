import Foundation
import CryptoKit

// MARK: - Solana Wallet Identity (Ed25519 keypair via CryptoKit)

/// A Solana-compatible Ed25519 keypair stored in the Keychain.
/// Uses the same CryptoKit Curve25519.Signing as WANKit, but with a
/// separate Keychain entry and stricter access control since this key controls funds.
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

    // MARK: - Keychain Persistence

    private static let keychainService = "com.teale.app"
    private static let keychainAccount = "solana-wallet-key"

    /// Load identity from Keychain, or generate and store a new one
    public static func loadOrCreate() throws -> SolanaIdentity {
        if let existing = try? loadFromKeychain() {
            return existing
        }
        let identity = SolanaIdentity()
        try saveToKeychain(identity)
        return identity
    }

    /// Load the private key from Keychain
    public static func loadFromKeychain() throws -> SolanaIdentity {
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

    /// Save the private key to Keychain
    public static func saveToKeychain(_ identity: SolanaIdentity) throws {
        let data = identity.privateKey.rawRepresentation

        // Delete existing if present
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecValueData as String: data,
            // Stricter than WANKit's kSecAttrAccessibleAfterFirstUnlock — this key controls funds
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]

        let status = SecItemAdd(addQuery as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw WalletKitError.keychainSaveFailed
        }
    }

    /// Check if a Solana wallet exists in Keychain without loading it
    public static func exists() -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecReturnData as String: false,
        ]
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }
}
