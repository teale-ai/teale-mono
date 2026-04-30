import CryptoKit
import Foundation
#if os(iOS)
import Security
#endif

/// Ed25519 device identity shared by macOS and iOS.
///
/// `deviceID` = lowercase hex of the 32-byte public key — identical convention
/// to the Android app and the Rust gateway. On iOS the seed lives in the
/// Keychain; on macOS it lives in a 0600 file under Application Support.
public final class GatewayIdentity: @unchecked Sendable {

    public static let shared = GatewayIdentity()

    private let privateKey: Curve25519.Signing.PrivateKey

    /// 64-char lowercase hex of the public key.
    public var deviceID: String { hexLower(privateKey.publicKey.rawRepresentation) }

    public var publicKey: Data { privateKey.publicKey.rawRepresentation }
    public var privateKeyRawRepresentation: Data { privateKey.rawRepresentation }

    /// Signs arbitrary bytes and returns the raw 64-byte Ed25519 signature.
    public func sign(_ bytes: Data) -> Data {
        (try? privateKey.signature(for: bytes)) ?? Data()
    }

    public init(seedData: Data) throws {
        self.privateKey = try Curve25519.Signing.PrivateKey(rawRepresentation: seedData)
    }

    private init() {
        #if os(iOS)
        if let seed = Self.loadSeedKeychain(), seed.count == 32,
           let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: seed) {
            self.privateKey = key
            return
        }
        let fresh = Curve25519.Signing.PrivateKey()
        Self.saveSeedKeychain(fresh.rawRepresentation)
        self.privateKey = fresh
        #else
        if let seed = Self.loadSeedFile(), seed.count == 32,
           let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: seed) {
            self.privateKey = key
            return
        }
        let fresh = Curve25519.Signing.PrivateKey()
        Self.saveSeedFile(fresh.rawRepresentation)
        self.privateKey = fresh
        #endif
    }

    // MARK: - iOS Keychain

    #if os(iOS)
    private static let keychainService = "com.teale.companion.gateway-identity"
    private static let keychainAccount = "wan-seed"

    private static func loadSeedKeychain() -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess else { return nil }
        return item as? Data
    }

    private static func saveSeedKeychain(_ data: Data) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
        ]
        SecItemDelete(base as CFDictionary)
        var attrs = base
        attrs[kSecValueData as String] = data
        attrs[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(attrs as CFDictionary, nil)
    }
    #endif

    // MARK: - macOS file-based storage

    #if os(macOS)
    private static var seedFileURL: URL {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!
        return appSupport.appendingPathComponent("Teale/gateway-identity-seed")
    }

    private static func loadSeedFile() -> Data? {
        try? Data(contentsOf: seedFileURL)
    }

    private static func saveSeedFile(_ data: Data) {
        let url = seedFileURL
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o600)],
            ofItemAtPath: url.path
        )
    }
    #endif
}

// MARK: - Hex helpers (internal to GatewayKit)

func hexLower(_ data: Data) -> String {
    data.map { String(format: "%02x", $0) }.joined()
}

func dataFromHex(_ hex: String) -> Data? {
    guard hex.count % 2 == 0 else { return nil }
    var data = Data(capacity: hex.count / 2)
    var idx = hex.startIndex
    while idx < hex.endIndex {
        let next = hex.index(idx, offsetBy: 2)
        guard let byte = UInt8(hex[idx..<next], radix: 16) else { return nil }
        data.append(byte)
        idx = next
    }
    return data
}
