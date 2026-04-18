import XCTest
@testable import WalletKit
@testable import CreditKit

final class WalletKitTests: XCTestCase {

    // MARK: - Base58 Tests

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

    // MARK: - CreditAmount USD Conversion Tests

    func testCreditAmountUSDValue() {
        let amount = CreditAmount(10_000)
        XCTAssertEqual(amount.usdValue, 1.0, accuracy: 0.0001)
    }

    func testCreditAmountFromUSD() {
        let amount = CreditAmount.fromUSD(1.0)
        XCTAssertEqual(amount.value, 10_000, accuracy: 0.01)
    }

    func testCreditAmountFromMicroUSDC() {
        // 1_000_000 micro-USDC = $1.00 = 10,000 credits
        let amount = CreditAmount.fromMicroUSDC(1_000_000)
        XCTAssertEqual(amount.value, 10_000, accuracy: 0.01)
    }

    func testCreditAmountMicroUSDC() {
        let amount = CreditAmount(10_000) // = $1.00
        XCTAssertEqual(amount.microUSDC, 1_000_000)
    }

    func testCreditAmountUSDFormatted() {
        XCTAssertEqual(CreditAmount(10_000).usdFormatted, "$1.00")
        XCTAssertEqual(CreditAmount(0).usdFormatted, "$0.00")
        XCTAssertEqual(CreditAmount(50).usdFormatted, "$0.0050")
    }

    func testWelcomeBonusUSDValue() {
        // 100 credits welcome bonus = $0.01
        let bonus = CreditPricing.welcomeBonus
        XCTAssertEqual(bonus.usdValue, 0.01, accuracy: 0.0001)
    }

    // MARK: - SolanaIdentity Tests

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
