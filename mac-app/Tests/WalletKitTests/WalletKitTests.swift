import XCTest
@testable import WalletKit

final class WalletKitTests: XCTestCase {

    // MARK: - Base58

    func testBase58EncodeEmptyData() {
        XCTAssertEqual(Base58.encode(Data()), "")
    }

    func testBase58RoundTrip() {
        let original = Data([0x00, 0x01, 0x02, 0x03, 0xFF])
        let encoded = Base58.encode(original)
        let decoded = Base58.decode(encoded)
        XCTAssertEqual(decoded, original)
    }

    func testBase58LeadingZeros() {
        // Leading zero bytes should map to '1' characters
        let data = Data([0x00, 0x00, 0x01])
        let encoded = Base58.encode(data)
        XCTAssertTrue(encoded.hasPrefix("11"))
    }

    func testBase58KnownVector() {
        // "Hello World" in Base58 = "JxF12TrwUP45BMd"
        let data = "Hello World".data(using: .utf8)!
        let encoded = Base58.encode(data)
        XCTAssertEqual(encoded, "JxF12TrwUP45BMd")
    }

    // MARK: - SolanaIdentity

    func testSolanaIdentityGeneration() {
        let identity = SolanaIdentity()
        XCTAssertFalse(identity.solanaAddress.isEmpty)
        XCTAssertFalse(identity.nodeID.isEmpty)
        XCTAssertEqual(identity.nodeID.count, 64) // 32 bytes hex = 64 chars
    }

    func testSolanaIdentityDeterministic() throws {
        let identity1 = SolanaIdentity()
        let identity2 = try SolanaIdentity(privateKeyData: identity1.privateKey.rawRepresentation)
        XCTAssertEqual(identity1.solanaAddress, identity2.solanaAddress)
        XCTAssertEqual(identity1.nodeID, identity2.nodeID)
    }

    func testSolanaSecretKeyLength() {
        let identity = SolanaIdentity()
        // Solana secret key = 64 bytes (32 seed + 32 public)
        XCTAssertEqual(identity.solanaSecretKey.count, 64)
    }
}
