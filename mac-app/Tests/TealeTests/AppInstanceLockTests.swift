import Foundation
import XCTest
@testable import AppCore

final class AppInstanceLockTests: XCTestCase {
    private func lockURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("app-instance.lock")
    }

    func testOnlyOneLiveOwnerCanAcquire() {
        let url = lockURL()
        let first = AppInstanceLock(lockURL: url)
        let second = AppInstanceLock(lockURL: url)

        XCTAssertTrue(first.acquire())
        XCTAssertFalse(second.acquire())
    }

    func testReleaseAllowsUpdaterReplacementToAcquire() {
        let url = lockURL()
        let oldImage = AppInstanceLock(lockURL: url)
        let replacement = AppInstanceLock(lockURL: url)

        XCTAssertTrue(oldImage.acquire())
        oldImage.release()
        XCTAssertTrue(replacement.acquire())
    }

    func testRepeatedAcquireBySameOwnerIsIdempotent() {
        let owner = AppInstanceLock(lockURL: lockURL())
        XCTAssertTrue(owner.acquire())
        XCTAssertTrue(owner.acquire())
    }
}
