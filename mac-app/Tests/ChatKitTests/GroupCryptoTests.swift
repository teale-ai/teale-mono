import XCTest
@testable import ChatKit

final class GroupCryptoTests: XCTestCase {
    func testArchivedDecryptReplaysHistoryAfterLiveRatchetAdvances() throws {
        var sender = SenderKey.generate(memberID: UUID())
        var receiver = sender.distributableCopy

        let first = try GroupCrypto.encrypt("hello", using: &sender)
        let second = try GroupCrypto.encrypt("world", using: &sender)

        XCTAssertEqual(try GroupCrypto.decrypt(first, using: &receiver), "hello")
        XCTAssertEqual(try GroupCrypto.decrypt(second, using: &receiver), "world")

        XCTAssertThrowsError(try GroupCrypto.decrypt(first, using: &receiver)) { error in
            guard case .replayDetected = error as? GroupCryptoError else {
                return XCTFail("expected replayDetected, got \(error)")
            }
        }

        XCTAssertEqual(try GroupCrypto.decryptArchived(first, using: receiver), "hello")
        XCTAssertEqual(try GroupCrypto.decryptArchived(second, using: receiver), "world")
    }

    func testLegacyKeyBackfillsArchiveAnchorForFutureMessages() throws {
        var sender = SenderKey.generate(memberID: UUID())
        _ = try GroupCrypto.encrypt("older", using: &sender)
        sender.baseChainKey = nil
        sender.baseMessageIndex = nil

        var receiver = sender.distributableCopy
        receiver.baseChainKey = nil
        receiver.baseMessageIndex = nil

        let future = try GroupCrypto.encrypt("future", using: &sender)
        XCTAssertEqual(sender.baseMessageIndex, 1)

        XCTAssertEqual(try GroupCrypto.decrypt(future, using: &receiver), "future")
        XCTAssertEqual(receiver.baseMessageIndex, 1)
        XCTAssertEqual(try GroupCrypto.decryptArchived(future, using: receiver), "future")
    }
}
