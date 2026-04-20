#if os(iOS)
import CryptoKit
import Foundation
import Security

/// Ed25519 device identity. `deviceID` = lowercase hex of the 32-byte public
/// key — identical convention to `android-app/.../WanIdentity.kt` and the
/// Rust `node/src/identity.rs`. Private key lives in the iOS Keychain.
final class GatewayIdentity {

    static let shared = GatewayIdentity()

    private static let service = "com.teale.companion.gateway-identity"
    private static let account = "wan-seed"

    private let privateKey: Curve25519.Signing.PrivateKey

    /// 64-char hex of the public key.
    var deviceID: String {
        hexLower(privateKey.publicKey.rawRepresentation)
    }

    var publicKey: Data { privateKey.publicKey.rawRepresentation }

    /// Sign arbitrary bytes and return the raw signature (64 bytes).
    func sign(_ bytes: Data) -> Data {
        // Curve25519.Signing.PrivateKey.signature always succeeds for Ed25519.
        (try? privateKey.signature(for: bytes)) ?? Data()
    }

    private init() {
        if let seed = Self.loadSeed(), seed.count == 32,
           let loaded = try? Curve25519.Signing.PrivateKey(rawRepresentation: seed) {
            self.privateKey = loaded
            return
        }
        // First launch (or keychain cleared) → generate + persist.
        let fresh = Curve25519.Signing.PrivateKey()
        Self.saveSeed(fresh.rawRepresentation)
        self.privateKey = fresh
    }

    // MARK: - Keychain

    private static func loadSeed() -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return data
    }

    @discardableResult
    private static func saveSeed(_ data: Data) -> Bool {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        // Delete any stale entry, then add fresh. Easier than Update + Add logic.
        SecItemDelete(base as CFDictionary)
        var attrs = base
        attrs[kSecValueData as String] = data
        attrs[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(attrs as CFDictionary, nil) == errSecSuccess
    }
}

// MARK: - Hex helpers

@inline(__always)
func hexLower(_ data: Data) -> String {
    var out = ""
    out.reserveCapacity(data.count * 2)
    for b in data { out += String(format: "%02x", b) }
    return out
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
#endif
