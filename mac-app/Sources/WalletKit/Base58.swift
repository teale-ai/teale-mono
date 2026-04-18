import Foundation

/// Base58 encoding/decoding using the Bitcoin alphabet (used by Solana for addresses).
public enum Base58 {
    private static let alphabet = Array("123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz")
    private static let base = UInt(alphabet.count) // 58

    /// Encode raw bytes to a Base58 string.
    public static func encode(_ data: Data) -> String {
        guard !data.isEmpty else { return "" }

        // Count leading zeros
        let leadingZeros = data.prefix(while: { $0 == 0 }).count

        // Convert byte array to a big integer, then repeatedly divide by 58
        var num = data.reduce(UInt(0)) { acc, byte in acc &* 256 &+ UInt(byte) }

        // For large keys we need arbitrary precision — use [UInt8] as big-integer
        var digits: [UInt8] = []
        var bytes = Array(data)

        // Big-integer division approach for arbitrary-length data
        while !bytes.isEmpty && !(bytes.count == 1 && bytes[0] == 0) {
            var remainder: UInt = 0
            var quotient: [UInt8] = []
            for byte in bytes {
                let acc = remainder * 256 + UInt(byte)
                let digit = acc / base
                remainder = acc % base
                if !quotient.isEmpty || digit > 0 {
                    quotient.append(UInt8(digit))
                }
            }
            digits.append(UInt8(remainder))
            bytes = quotient
        }

        // Leading zeros become '1' characters
        let prefix = String(repeating: alphabet[0], count: leadingZeros)
        let encoded = digits.reversed().map { alphabet[Int($0)] }
        return prefix + String(encoded)
    }

    /// Decode a Base58 string to raw bytes.
    public static func decode(_ string: String) -> Data? {
        guard !string.isEmpty else { return Data() }

        // Build reverse lookup
        var alphaMap = [Character: UInt]()
        for (i, c) in alphabet.enumerated() {
            alphaMap[c] = UInt(i)
        }

        // Count leading '1's (they map to 0x00 bytes)
        let leadingOnes = string.prefix(while: { $0 == alphabet[0] }).count

        // Convert Base58 digits to a big integer in [UInt8] form
        var bytes: [UInt8] = []
        for char in string {
            guard let value = alphaMap[char] else { return nil }

            // Multiply existing bytes by 58 and add the new digit
            var carry = value
            for i in (0..<bytes.count).reversed() {
                let acc = UInt(bytes[i]) * base + carry
                bytes[i] = UInt8(acc & 0xFF)
                carry = acc >> 8
            }
            while carry > 0 {
                bytes.insert(UInt8(carry & 0xFF), at: 0)
                carry >>= 8
            }
        }

        let leadingZeros = Data(repeating: 0, count: leadingOnes)
        return leadingZeros + Data(bytes)
    }
}
