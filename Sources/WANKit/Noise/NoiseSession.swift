import Foundation

// MARK: - Noise Transport Session

/// Post-handshake symmetric transport layer.
/// Encrypts/decrypts messages using the derived transport keys from a Noise handshake.
/// Implements nonce tracking, anti-replay, and session expiry.
public final class NoiseSession: @unchecked Sendable {

    // Transport keys
    private let sendKey: Data
    private let receiveKey: Data
    public let handshakeHash: Data

    // Nonce counters
    private var sendNonce: UInt64 = 0
    private var receiveNonce: UInt64 = 0

    // Anti-replay window (bitmap of 2048 most recent received nonces)
    private static let windowSize: UInt64 = 2048
    private var replayBitmap: [UInt64]  // 32 x 64-bit words = 2048 bits
    private var replayHighWater: UInt64 = 0

    // Session lifetime
    private let createdAt: Date
    private static let maxSessionAge: TimeInterval = 180  // 3 minutes, then rekey

    // Thread safety
    private let lock = NSLock()

    public init(keys: NoiseHandshake.TransportKeys) {
        self.sendKey = keys.sendKey
        self.receiveKey = keys.receiveKey
        self.handshakeHash = keys.handshakeHash
        self.createdAt = Date()
        self.replayBitmap = [UInt64](repeating: 0, count: 32)
    }

    /// Whether this session has expired and needs rekeying.
    public var isExpired: Bool {
        Date().timeIntervalSince(createdAt) > Self.maxSessionAge
    }

    /// Session age in seconds.
    public var age: TimeInterval {
        Date().timeIntervalSince(createdAt)
    }

    // MARK: - Encrypt

    /// Encrypt a message for sending.
    /// Returns: `[counter: 8 bytes LE] [ciphertext + tag]`
    public func encrypt(_ plaintext: Data) throws -> Data {
        lock.lock()
        let nonce = sendNonce
        sendNonce += 1
        lock.unlock()

        guard nonce < UInt64.max - 1 else {
            throw NoiseError.sessionExpired
        }

        let encrypted = try NoiseCrypto.encrypt(
            key: sendKey,
            nonce: nonce,
            ad: Data(),  // No additional data for transport messages
            plaintext: plaintext
        )

        // Prepend counter for receiver's nonce tracking
        var packet = Data(count: 8)
        withUnsafeBytes(of: nonce.littleEndian) { packet.replaceSubrange(0..<8, with: $0) }
        packet.append(encrypted)
        return packet
    }

    // MARK: - Decrypt

    /// Decrypt a received message.
    /// Input format: `[counter: 8 bytes LE] [ciphertext + tag]`
    public func decrypt(_ packet: Data) throws -> Data {
        guard packet.count >= 8 + 16 else {  // 8 byte counter + 16 byte tag minimum
            throw NoiseError.invalidMessage
        }

        // Extract counter
        let counterData = packet[packet.startIndex..<packet.index(packet.startIndex, offsetBy: 8)]
        let counter: UInt64 = counterData.withUnsafeBytes { $0.load(as: UInt64.self).littleEndian }

        // Anti-replay check
        lock.lock()
        guard !isReplay(counter) else {
            lock.unlock()
            throw NoiseError.replayDetected
        }

        let ciphertextAndTag = packet[packet.index(packet.startIndex, offsetBy: 8)...]
        do {
            let plaintext = try NoiseCrypto.decrypt(
                key: receiveKey,
                nonce: counter,
                ad: Data(),
                ciphertextAndTag: Data(ciphertextAndTag)
            )

            // Only mark as received after successful decryption
            markReceived(counter)
            lock.unlock()
            return plaintext
        } catch {
            lock.unlock()
            throw error
        }
    }

    // MARK: - Anti-Replay Window

    /// Check if a nonce has already been received (must be called under lock).
    private func isReplay(_ counter: UInt64) -> Bool {
        if counter > replayHighWater {
            return false  // New high, definitely not a replay
        }

        let distance = replayHighWater - counter
        if distance >= Self.windowSize {
            return true  // Too old, outside window
        }

        let wordIndex = Int(distance / 64)
        let bitIndex = Int(distance % 64)
        return (replayBitmap[wordIndex] & (1 << bitIndex)) != 0
    }

    /// Mark a nonce as received (must be called under lock).
    private func markReceived(_ counter: UInt64) {
        if counter > replayHighWater {
            // Shift window forward
            let shift = counter - replayHighWater
            if shift >= Self.windowSize {
                // Complete reset
                replayBitmap = [UInt64](repeating: 0, count: 32)
            } else {
                shiftWindow(by: shift)
            }
            replayHighWater = counter
            // Mark bit 0 (current high water)
            replayBitmap[0] |= 1
        } else {
            let distance = replayHighWater - counter
            let wordIndex = Int(distance / 64)
            let bitIndex = Int(distance % 64)
            replayBitmap[wordIndex] |= (1 << bitIndex)
        }
    }

    /// Shift the replay bitmap forward by `count` positions.
    private func shiftWindow(by count: UInt64) {
        let wordShift = Int(count / 64)
        let bitShift = Int(count % 64)

        if wordShift > 0 {
            // Shift entire words
            for i in stride(from: 31, through: wordShift, by: -1) {
                replayBitmap[i] = replayBitmap[i - wordShift]
            }
            for i in 0..<min(wordShift, 32) {
                replayBitmap[i] = 0
            }
        }

        if bitShift > 0 {
            // Shift bits within words
            for i in stride(from: 31, through: 1, by: -1) {
                replayBitmap[i] = (replayBitmap[i] << bitShift) | (replayBitmap[i - 1] >> (64 - bitShift))
            }
            replayBitmap[0] <<= bitShift
        }
    }
}
