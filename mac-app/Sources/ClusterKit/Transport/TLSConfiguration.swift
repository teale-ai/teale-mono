import Foundation
import CryptoKit
import Network
import Security

// MARK: - Cluster Security

public struct ClusterSecurity: Sendable {
    /// Hash a passcode for comparison during handshake.
    ///
    /// With a passcode set, the Hello exchange runs inside the TLS-PSK
    /// channel (`pskTLSOptions`), so this hash is only ever sent to peers
    /// that already proved knowledge of the passcode by completing the TLS
    /// handshake; it is no longer an authenticator a LAN observer can
    /// capture and replay. It remains the cluster/organization identifier.
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

    /// PSK identity sent in the clear during the TLS handshake. Versioned so
    /// a future key-derivation change can be told apart.
    static let pskIdentity = "teale-cluster-psk-v1"

    /// 32-byte TLS pre-shared key: HMAC-SHA256(key: passcode, msg: identity).
    /// Never sent on the wire; both sides derive it independently.
    static func preSharedKey(passcode: String) -> Data {
        let key = SymmetricKey(data: Data(passcode.utf8))
        let mac = HMAC<SHA256>.authenticationCode(for: Data(pskIdentity.utf8), using: key)
        return Data(mac)
    }

    /// TLS 1.2 PSK options (TLS_PSK_WITH_AES_128_GCM_SHA256). The handshake
    /// fails unless both peers derived the same key from the same passcode,
    /// which gives mutual authentication plus encryption without
    /// certificates. This replaces the never-used certificate TLS manager,
    /// whose verify block accepted every certificate.
    static func pskTLSOptions(passcode: String) -> NWProtocolTLS.Options {
        let tlsOptions = NWProtocolTLS.Options()
        let psk = preSharedKey(passcode: passcode)
        let identity = Data(pskIdentity.utf8)
        let pskData = psk.withUnsafeBytes { DispatchData(bytes: $0) }
        let identityData = identity.withUnsafeBytes { DispatchData(bytes: $0) }
        sec_protocol_options_add_pre_shared_key(
            tlsOptions.securityProtocolOptions,
            pskData as __DispatchData,
            identityData as __DispatchData
        )
        if let suite = tls_ciphersuite_t(rawValue: UInt16(TLS_PSK_WITH_AES_128_GCM_SHA256)) {
            sec_protocol_options_append_tls_ciphersuite(tlsOptions.securityProtocolOptions, suite)
        }
        sec_protocol_options_set_min_tls_protocol_version(tlsOptions.securityProtocolOptions, .TLSv12)
        sec_protocol_options_set_max_tls_protocol_version(tlsOptions.securityProtocolOptions, .TLSv12)
        return tlsOptions
    }
}
