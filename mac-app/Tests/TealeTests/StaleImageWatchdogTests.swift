import Foundation
import XCTest
@testable import AppCore

final class StaleImageWatchdogTests: XCTestCase {
    // #335: a swapped bundle must be detected from the version pair.

    func testVersionMismatchIsStale() {
        XCTAssertTrue(StaleImageWatchdog.isStaleImage(launchVersion: "202609112036", onDiskVersion: "202609121440"))
    }

    func testSameVersionIsNotStale() {
        XCTAssertFalse(StaleImageWatchdog.isStaleImage(launchVersion: "202609112036", onDiskVersion: "202609112036"))
    }

    func testUnreadableOnDiskPlistNeverKills() {
        // A plist that can't be read (permissions, transient I/O) must not
        // terminate a healthy process.
        XCTAssertFalse(StaleImageWatchdog.isStaleImage(launchVersion: "202609112036", onDiskVersion: nil))
    }

    func testMissingLaunchVersionNeverKills() {
        XCTAssertFalse(StaleImageWatchdog.isStaleImage(launchVersion: nil, onDiskVersion: "202609121440"))
    }

    func testEmptyVersionsNeverKill() {
        XCTAssertFalse(StaleImageWatchdog.isStaleImage(launchVersion: "", onDiskVersion: "202609121440"))
        XCTAssertFalse(StaleImageWatchdog.isStaleImage(launchVersion: "202609112036", onDiskVersion: ""))
    }
}
