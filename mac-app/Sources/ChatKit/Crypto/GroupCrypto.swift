import Foundation
import CryptoKit

// MARK: - Group Crypto (Signal-style Sender Keys with Hash Ratchet)

/// E2E encryption for group chat messages.
///
/// Each group member has a **sender key** with a chain key that ratchets forward
/// (Signal's Sender Keys protocol). Messages are signed with Ed25519 for authentication.
///
/// ```
/// For message N:
///   mk_N = HMAC-SHA256(ck_{N-1}, "msg")    ← message key (used once)
///   ck_N = HMAC-SHA256(ck_{N-1}, "chain")   ← new chain key
///   ciphertext = ChaCha20-Poly1305(plaintext, mk_N)
///   signature = Ed25519.sign(ciphertext || messageIndex)
/// ```
public enum GroupCrypto {

    /// Encrypt and sign a message using the sender's key. Advances the chain ratchet.
    public static func encrypt(_ plaintext: String, using key: inout SenderKey) throws -> EncryptedPayload {
        guard let chainKey = key.chainKey else {
            throw GroupCryptoError.missingSenderKey
        }
        guard let signingKey = key.signingKeyPrivate else {
            throw GroupCryptoError.missingSenderKey
        }

        if key.baseChainKey == nil {
            key.baseChainKey = chainKey
            key.baseMessageIndex = key.messageIndex
        }

        // Derive message key from chain key
        let messageKey = deriveKey(from: chainKey, label: "msg")
        // Advance chain key (forward secrecy — old chain key is gone)
        let nextChainKey = deriveKey(from: chainKey, label: "chain")
        let messageIndex = key.messageIndex

        // Encrypt with derived message key
        let symmetricKey = SymmetricKey(data: messageKey)
        let plaintextData = Data(plaintext.utf8)
        let sealed = try ChaChaPoly.seal(plaintextData, using: symmetricKey)
        let ciphertext = sealed.nonce.withUnsafeBytes { Data($0) } + sealed.ciphertext + sealed.tag

        // Sign: ciphertext || messageIndex (4 bytes LE)
        let signingData = ciphertext + withUnsafeBytes(of: messageIndex.littleEndian) { Data($0) }
        let edKey = try Curve25519.Signing.PrivateKey(rawRepresentation: signingKey)
        let signature = try edKey.signature(for: signingData)

        // Advance ratchet state
        key.chainKey = nextChainKey
        key.messageIndex = messageIndex + 1

        return EncryptedPayload(
            keyID: key.keyID,
            ciphertext: ciphertext,
            messageIndex: messageIndex,
            signature: signature
        )
    }

    /// Verify signature and decrypt a message using the sender's key.
    public static func decrypt(_ payload: EncryptedPayload, using key: inout SenderKey) throws -> String {
        guard let chainKey = key.chainKey else {
            throw GroupCryptoError.missingSenderKey
        }
        guard let verifyKey = key.verifyKey else {
            throw GroupCryptoError.missingSenderKey
        }

        if key.baseChainKey == nil {
            key.baseChainKey = chainKey
            key.baseMessageIndex = key.messageIndex
        }

        // Verify signature first (reject spoofed messages before any decryption)
        try verifySignature(payload, verifyKey: verifyKey)

        // Advance chain key to match message index (skip if receiver is behind)
        var currentChain = chainKey
        var currentIndex = key.messageIndex
        guard payload.messageIndex >= currentIndex else {
            throw GroupCryptoError.replayDetected
        }
        while currentIndex < payload.messageIndex {
            currentChain = deriveKey(from: currentChain, label: "chain")
            currentIndex += 1
        }

        // Derive message key
        let messageKey = deriveKey(from: currentChain, label: "msg")
        let nextChainKey = deriveKey(from: currentChain, label: "chain")

        let text = try plaintext(for: payload, messageKey: messageKey)

        // Advance receiver's ratchet state
        key.chainKey = nextChainKey
        key.messageIndex = payload.messageIndex + 1

        return text
    }

    /// Decrypt a stored historical message without mutating the sender key's
    /// current ratchet state. Used when replaying local thread history.
    public static func decryptArchived(_ payload: EncryptedPayload, using key: SenderKey) throws -> String {
        guard let verifyKey = key.verifyKey else {
            throw GroupCryptoError.missingSenderKey
        }

        try verifySignature(payload, verifyKey: verifyKey)

        guard let archiveChainKey = key.baseChainKey ?? key.chainKey else {
            throw GroupCryptoError.missingSenderKey
        }
        let archiveIndex = key.baseMessageIndex ?? key.messageIndex
        guard payload.messageIndex >= archiveIndex else {
            throw GroupCryptoError.replayDetected
        }

        var currentChain = archiveChainKey
        var currentIndex = archiveIndex
        while currentIndex < payload.messageIndex {
            currentChain = deriveKey(from: currentChain, label: "chain")
            currentIndex += 1
        }

        return try plaintext(for: payload, messageKey: deriveKey(from: currentChain, label: "msg"))
    }

    // MARK: - Key Derivation

    /// HMAC-SHA256 based key derivation (same pattern as Signal's chain ratchet).
    private static func deriveKey(from chainKey: Data, label: String) -> Data {
        let key = SymmetricKey(data: chainKey)
        let mac = HMAC<SHA256>.authenticationCode(for: Data(label.utf8), using: key)
        return Data(mac)
    }

    private static func verifySignature(_ payload: EncryptedPayload, verifyKey: Data) throws {
        let signingData = payload.ciphertext + withUnsafeBytes(of: payload.messageIndex.littleEndian) { Data($0) }
        let edPubKey = try Curve25519.Signing.PublicKey(rawRepresentation: verifyKey)
        guard edPubKey.isValidSignature(payload.signature, for: signingData) else {
            throw GroupCryptoError.signatureInvalid
        }
    }

    private static func plaintext(for payload: EncryptedPayload, messageKey: Data) throws -> String {
        // Parse ciphertext: [12-byte nonce][ciphertext][16-byte tag]
        guard payload.ciphertext.count >= 28 else { // 12 + 0 + 16 minimum
            throw GroupCryptoError.decryptionFailed
        }
        let nonce = try ChaChaPoly.Nonce(data: payload.ciphertext.prefix(12))
        let rest = payload.ciphertext.dropFirst(12)
        let tagStart = rest.count - 16
        let ct = rest.prefix(tagStart)
        let tag = rest.suffix(16)

        let sealedBox = try ChaChaPoly.SealedBox(nonce: nonce, ciphertext: ct, tag: tag)
        let decrypted = try ChaChaPoly.open(sealedBox, using: SymmetricKey(data: messageKey))

        guard let text = String(data: decrypted, encoding: .utf8) else {
            throw GroupCryptoError.decryptionFailed
        }
        return text
    }
}

// MARK: - Sender Key

/// A sender key with hash ratchet for group E2E encryption.
/// Each group member generates one; all members hold each other's keys.
/// The chain key ratchets forward on every message for forward secrecy.
public struct SenderKey: Codable, Sendable, Identifiable {
    public let keyID: String
    /// Chain key for the hash ratchet (32 bytes). Advances on every encrypt/decrypt.
    public var chainKey: Data?
    /// Earliest chain key retained for historical local replay.
    public var baseChainKey: Data?
    /// Ratchet position for `baseChainKey`.
    public var baseMessageIndex: UInt32?
    /// Ed25519 signing private key (32 bytes). Only present for own keys.
    public let signingKeyPrivate: Data?
    /// Ed25519 verification public key (32 bytes). Present for all keys.
    public let verifyKey: Data?
    public let memberID: UUID
    public let createdAt: Date
    public var expired: Bool
    /// Message counter — tracks the ratchet position.
    public var messageIndex: UInt32

    public var id: String { keyID }

    /// Generate a new sender key for the local user.
    public static func generate(memberID: UUID) -> SenderKey {
        let chainKey = SymmetricKey(size: .bits256)
        let signingKey = Curve25519.Signing.PrivateKey()

        return SenderKey(
            keyID: UUID().uuidString,
            chainKey: chainKey.withUnsafeBytes { Data($0) },
            baseChainKey: chainKey.withUnsafeBytes { Data($0) },
            baseMessageIndex: 0,
            signingKeyPrivate: signingKey.rawRepresentation,
            verifyKey: signingKey.publicKey.rawRepresentation,
            memberID: memberID,
            createdAt: Date(),
            expired: false,
            messageIndex: 0
        )
    }

    /// Create a sender key received from another member (for decryption).
    public static func received(
        keyID: String,
        chainKey: Data,
        verifyKey: Data,
        memberID: UUID
    ) -> SenderKey {
        SenderKey(
            keyID: keyID,
            chainKey: chainKey,
            baseChainKey: chainKey,
            baseMessageIndex: 0,
            signingKeyPrivate: nil,
            verifyKey: verifyKey,
            memberID: memberID,
            createdAt: Date(),
            expired: false,
            messageIndex: 0
        )
    }

    /// The distributable portion of this key (chain key + verify key, no signing private key).
    public var distributableCopy: SenderKey {
        SenderKey(
            keyID: keyID,
            chainKey: chainKey,
            baseChainKey: baseChainKey,
            baseMessageIndex: baseMessageIndex,
            signingKeyPrivate: nil,
            verifyKey: verifyKey,
            memberID: memberID,
            createdAt: createdAt,
            expired: expired,
            messageIndex: messageIndex
        )
    }
}

// MARK: - Encrypted Payload

/// Encrypted + signed message payload for P2P transport and local storage.
public struct EncryptedPayload: Codable, Sendable {
    public let keyID: String
    /// [12-byte nonce][ciphertext][16-byte tag]
    public let ciphertext: Data
    /// Ratchet position — for chain advancement and replay detection.
    public let messageIndex: UInt32
    /// Ed25519 signature over (ciphertext || messageIndex).
    public let signature: Data

    public init(keyID: String, ciphertext: Data, messageIndex: UInt32, signature: Data) {
        self.keyID = keyID
        self.ciphertext = ciphertext
        self.messageIndex = messageIndex
        self.signature = signature
    }
}

// MARK: - Errors

public enum GroupCryptoError: LocalizedError {
    case missingSenderKey
    case decryptionFailed
    case invalidPayload
    case keyNotFound(String)
    case signatureInvalid
    case replayDetected

    public var errorDescription: String? {
        switch self {
        case .missingSenderKey: return "Missing sender key for encryption"
        case .decryptionFailed: return "Failed to decrypt message"
        case .invalidPayload: return "Invalid encrypted payload"
        case .keyNotFound(let id): return "Sender key not found: \(id)"
        case .signatureInvalid: return "Message signature verification failed"
        case .replayDetected: return "Replay attack detected — message index too old"
        }
    }
}
