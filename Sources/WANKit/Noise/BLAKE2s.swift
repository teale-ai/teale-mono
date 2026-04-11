import Foundation

// MARK: - BLAKE2s-256 (RFC 7693)

/// Pure Swift implementation of BLAKE2s with 32-byte (256-bit) output.
/// Used by the Noise protocol for HMAC and key derivation.
public enum BLAKE2s {

    /// Output size in bytes (BLAKE2s-256)
    public static let outputSize = 32
    /// Block size in bytes
    static let blockSize = 64

    // Initialization vector (same as SHA-256, fractional parts of square roots of first 8 primes)
    private static let iv: [UInt32] = [
        0x6A09E667, 0xBB67AE85, 0x3C6EF372, 0xA54FF53A,
        0x510E527F, 0x9B05688C, 0x1F83D9AB, 0x5BE0CD19,
    ]

    // Sigma permutation schedule for 10 rounds
    private static let sigma: [[Int]] = [
        [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15],
        [14, 10, 4, 8, 9, 15, 13, 6, 1, 12, 0, 2, 11, 7, 5, 3],
        [11, 8, 12, 0, 5, 2, 15, 13, 10, 14, 3, 6, 7, 1, 9, 4],
        [7, 9, 3, 1, 13, 12, 11, 14, 2, 6, 5, 10, 4, 0, 15, 8],
        [9, 0, 5, 7, 2, 4, 10, 15, 14, 1, 11, 12, 6, 8, 3, 13],
        [2, 12, 6, 10, 0, 11, 8, 3, 4, 13, 7, 5, 15, 14, 1, 9],
        [12, 5, 1, 15, 14, 13, 4, 10, 0, 7, 6, 3, 9, 2, 8, 11],
        [13, 11, 7, 14, 12, 1, 3, 9, 5, 0, 15, 4, 8, 6, 2, 10],
        [6, 15, 14, 9, 11, 3, 0, 8, 12, 2, 13, 7, 1, 4, 10, 5],
        [10, 2, 8, 4, 7, 6, 1, 5, 15, 11, 9, 14, 3, 12, 13, 0],
    ]

    // MARK: - Public API

    /// Hash data with BLAKE2s-256 (unkeyed)
    public static func hash(_ data: Data) -> Data {
        return hash(data, key: Data())
    }

    /// Hash data with BLAKE2s-256 (keyed MAC)
    public static func hash(_ data: Data, key: Data) -> Data {
        let keyLen = key.count
        precondition(keyLen <= 32, "BLAKE2s key must be <= 32 bytes")

        // Initialize state
        var h = iv
        // Parameter block: fanout=1, depth=1, leaf_length=0, digest_length=32, key_length
        h[0] ^= 0x01010000 ^ (UInt32(keyLen) << 8) ^ UInt32(outputSize)

        var t: UInt64 = 0  // bytes compressed so far
        var buffer = Data()

        // If keyed, first block is the key padded to 64 bytes
        if keyLen > 0 {
            var keyBlock = Data(count: blockSize)
            keyBlock.replaceSubrange(0..<keyLen, with: key)
            buffer.append(keyBlock)
        }

        buffer.append(data)

        // Process all complete blocks except the last
        var offset = 0
        while buffer.count - offset > blockSize {
            let block = buffer[offset..<(offset + blockSize)]
            t += UInt64(blockSize)
            compress(&h, block: Array(block), t: t, isFinal: false)
            offset += blockSize
        }

        // Final block (pad with zeros)
        let remaining = buffer[offset...]
        t += UInt64(remaining.count)
        var lastBlock = Array(remaining)
        while lastBlock.count < blockSize {
            lastBlock.append(0)
        }
        compress(&h, block: lastBlock, t: t, isFinal: true)

        // Produce output (little-endian)
        var result = Data(count: outputSize)
        for i in 0..<8 {
            let val = h[i]
            result[i * 4 + 0] = UInt8(truncatingIfNeeded: val)
            result[i * 4 + 1] = UInt8(truncatingIfNeeded: val >> 8)
            result[i * 4 + 2] = UInt8(truncatingIfNeeded: val >> 16)
            result[i * 4 + 3] = UInt8(truncatingIfNeeded: val >> 24)
        }
        return result
    }

    // MARK: - Compression

    private static func compress(_ h: inout [UInt32], block: [UInt8], t: UInt64, isFinal: Bool) {
        // Parse message block as 16 little-endian UInt32 words
        var m = [UInt32](repeating: 0, count: 16)
        for i in 0..<16 {
            let offset = i * 4
            m[i] = UInt32(block[offset])
                | (UInt32(block[offset + 1]) << 8)
                | (UInt32(block[offset + 2]) << 16)
                | (UInt32(block[offset + 3]) << 24)
        }

        // Initialize working variables
        var v = [UInt32](repeating: 0, count: 16)
        v[0] = h[0]; v[1] = h[1]; v[2] = h[2]; v[3] = h[3]
        v[4] = h[4]; v[5] = h[5]; v[6] = h[6]; v[7] = h[7]
        v[8] = iv[0]; v[9] = iv[1]; v[10] = iv[2]; v[11] = iv[3]
        v[12] = iv[4] ^ UInt32(truncatingIfNeeded: t)
        v[13] = iv[5] ^ UInt32(truncatingIfNeeded: t >> 32)
        v[14] = isFinal ? ~iv[6] : iv[6]
        v[15] = iv[7]

        // 10 rounds of mixing
        for round in 0..<10 {
            let s = sigma[round]
            mix(&v, 0, 4,  8, 12, m[s[0]], m[s[1]])
            mix(&v, 1, 5,  9, 13, m[s[2]], m[s[3]])
            mix(&v, 2, 6, 10, 14, m[s[4]], m[s[5]])
            mix(&v, 3, 7, 11, 15, m[s[6]], m[s[7]])
            mix(&v, 0, 5, 10, 15, m[s[8]], m[s[9]])
            mix(&v, 1, 6, 11, 12, m[s[10]], m[s[11]])
            mix(&v, 2, 7,  8, 13, m[s[12]], m[s[13]])
            mix(&v, 3, 4,  9, 14, m[s[14]], m[s[15]])
        }

        // Finalize: h = h ^ v[0..7] ^ v[8..15]
        for i in 0..<8 {
            h[i] ^= v[i] ^ v[i + 8]
        }
    }

    @inline(__always)
    private static func mix(_ v: inout [UInt32], _ a: Int, _ b: Int, _ c: Int, _ d: Int, _ x: UInt32, _ y: UInt32) {
        v[a] = v[a] &+ v[b] &+ x
        v[d] = (v[d] ^ v[a]).rotatedRight(by: 16)
        v[c] = v[c] &+ v[d]
        v[b] = (v[b] ^ v[c]).rotatedRight(by: 12)
        v[a] = v[a] &+ v[b] &+ y
        v[d] = (v[d] ^ v[a]).rotatedRight(by: 8)
        v[c] = v[c] &+ v[d]
        v[b] = (v[b] ^ v[c]).rotatedRight(by: 7)
    }
}

// MARK: - UInt32 rotation helper

private extension UInt32 {
    @inline(__always)
    func rotatedRight(by n: Int) -> UInt32 {
        (self >> n) | (self << (32 - n))
    }
}
