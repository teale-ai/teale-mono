import Foundation
import CryptoKit

// MARK: - Noise Protocol Crypto Utilities

/// Cryptographic primitives for the Noise protocol framework.
/// Uses CryptoKit for Curve25519 DH and ChaCha20-Poly1305 AEAD,
/// and our BLAKE2s implementation for hashing and key derivation.
public enum NoiseCrypto {

    // MARK: - Curve25519 Diffie-Hellman

    /// Perform X25519 Diffie-Hellman key agreement.
    public static func dh(
        privateKey: Curve25519.KeyAgreement.PrivateKey,
        publicKey: Curve25519.KeyAgreement.PublicKey
    ) throws -> Data {
        let shared = try privateKey.sharedSecretFromKeyAgreement(with: publicKey)
        // Extract raw bytes from SharedSecret via HKDF with empty salt/info
        // SharedSecret doesn't expose raw bytes directly, so we derive via HKDF
        let key = shared.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: Data(),
            sharedInfo: Data(),
            outputByteCount: 32
        )
        return key.withUnsafeBytes { Data($0) }
    }

    // MARK: - ChaCha20-Poly1305 AEAD

    /// Encrypt with ChaCha20-Poly1305.
    /// Nonce is 4 zero bytes + 8-byte little-endian counter (Noise convention).
    public static func encrypt(
        key: Data,
        nonce: UInt64,
        ad: Data,
        plaintext: Data
    ) throws -> Data {
        let symmetricKey = SymmetricKey(data: key)
        let nonceBytes = noiseNonce(nonce)
        let chaChaNonce = try ChaChaPoly.Nonce(data: nonceBytes)
        let sealed = try ChaChaPoly.seal(plaintext, using: symmetricKey, nonce: chaChaNonce, authenticating: ad)
        // Return ciphertext + tag (no nonce prefix — Noise tracks nonces separately)
        return sealed.ciphertext + sealed.tag
    }

    /// Decrypt with ChaCha20-Poly1305.
    public static func decrypt(
        key: Data,
        nonce: UInt64,
        ad: Data,
        ciphertextAndTag: Data
    ) throws -> Data {
        guard ciphertextAndTag.count >= 16 else {
            throw NoiseError.decryptionFailed
        }
        let symmetricKey = SymmetricKey(data: key)
        let nonceBytes = noiseNonce(nonce)
        let chaChaNonce = try ChaChaPoly.Nonce(data: nonceBytes)

        let tagStart = ciphertextAndTag.count - 16
        let ciphertext = ciphertextAndTag[..<ciphertextAndTag.index(ciphertextAndTag.startIndex, offsetBy: tagStart)]
        let tag = ciphertextAndTag[ciphertextAndTag.index(ciphertextAndTag.startIndex, offsetBy: tagStart)...]

        let sealedBox = try ChaChaPoly.SealedBox(
            nonce: chaChaNonce,
            ciphertext: ciphertext,
            tag: tag
        )
        return try ChaChaPoly.open(sealedBox, using: symmetricKey, authenticating: ad)
    }

    /// Construct a 12-byte Noise nonce: 4 zero bytes + 8-byte LE counter.
    private static func noiseNonce(_ counter: UInt64) -> Data {
        var nonce = Data(count: 12)
        // First 4 bytes are zero (Noise spec)
        // Last 8 bytes are little-endian counter
        var le = counter.littleEndian
        nonce.replaceSubrange(4..<12, with: Data(bytes: &le, count: 8))
        return nonce
    }

    // MARK: - BLAKE2s Hash

    /// BLAKE2s-256 hash.
    public static func hash(_ data: Data) -> Data {
        BLAKE2s.hash(data)
    }

    /// BLAKE2s-256 hash of concatenated data.
    public static func hash(_ parts: Data...) -> Data {
        var combined = Data()
        for part in parts {
            combined.append(part)
        }
        return BLAKE2s.hash(combined)
    }

    // MARK: - HMAC-BLAKE2s

    /// HMAC using BLAKE2s as the hash function.
    /// HMAC(key, data) = H((key ^ opad) || H((key ^ ipad) || data))
    public static func hmacBLAKE2s(key: Data, data: Data) -> Data {
        let blockSize = BLAKE2s.blockSize
        var normalizedKey: Data

        if key.count > blockSize {
            normalizedKey = BLAKE2s.hash(key)
        } else {
            normalizedKey = key
        }

        // Pad to block size
        if normalizedKey.count < blockSize {
            normalizedKey.append(Data(count: blockSize - normalizedKey.count))
        }

        var ipad = Data(count: blockSize)
        var opad = Data(count: blockSize)
        for i in 0..<blockSize {
            ipad[i] = normalizedKey[i] ^ 0x36
            opad[i] = normalizedKey[i] ^ 0x5C
        }

        let inner = BLAKE2s.hash(ipad + data)
        return BLAKE2s.hash(opad + inner)
    }

    // MARK: - HKDF-BLAKE2s

    /// Noise HKDF: derives 2 or 3 output keys from a chaining key and input key material.
    public static func hkdf(chainingKey: Data, inputKeyMaterial: Data, numOutputs: Int = 2) -> [Data] {
        precondition(numOutputs == 2 || numOutputs == 3)

        let tempKey = hmacBLAKE2s(key: chainingKey, data: inputKeyMaterial)
        let output1 = hmacBLAKE2s(key: tempKey, data: Data([0x01]))
        let output2 = hmacBLAKE2s(key: tempKey, data: output1 + Data([0x02]))

        if numOutputs == 2 {
            return [output1, output2]
        }

        let output3 = hmacBLAKE2s(key: tempKey, data: output2 + Data([0x03]))
        return [output1, output2, output3]
    }
}

// MARK: - Noise Errors

public enum NoiseError: LocalizedError, Sendable {
    case handshakeFailed(String)
    case decryptionFailed
    case invalidMessage
    case invalidPublicKey
    case replayDetected
    case sessionExpired

    public var errorDescription: String? {
        switch self {
        case .handshakeFailed(let msg): return "Noise handshake failed: \(msg)"
        case .decryptionFailed: return "Noise decryption failed"
        case .invalidMessage: return "Invalid Noise message"
        case .invalidPublicKey: return "Invalid public key"
        case .replayDetected: return "Replay attack detected"
        case .sessionExpired: return "Noise session expired"
        }
    }
}
