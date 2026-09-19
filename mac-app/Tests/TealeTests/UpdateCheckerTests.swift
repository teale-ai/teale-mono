import XCTest
@testable import AppCore

@MainActor
final class UpdateCheckerTests: XCTestCase {
    func testMacReleaseTagBeatsOlderBuild() {
        XCTAssertTrue(UpdateChecker.isNewerRelease(
            tag: "mac-v2026.09.19.0334",
            thanBuild: 202609130159
        ))
    }

    func testCurrentAndOlderTagsDoNotUpdate() {
        XCTAssertFalse(UpdateChecker.isNewerRelease(
            tag: "mac-v2026.09.13.0159",
            thanBuild: 202609130159
        ))
        XCTAssertFalse(UpdateChecker.isNewerRelease(
            tag: "mac-v2026.09.11.2036",
            thanBuild: 202609130159
        ))
    }

    func testWindowsAndMalformedTagsNeverCompareAsMacUpdates() {
        XCTAssertNil(UpdateChecker.releaseVersion(for: "teale-2026.09.19.0430"))
        XCTAssertNil(UpdateChecker.releaseVersion(for: "mac-vnot-a-version"))
    }
}
