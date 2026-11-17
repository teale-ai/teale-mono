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
        XCTAssertNil(UpdateChecker.releaseVersion(for: "mac-v2026.9.19.334"))
        XCTAssertNil(UpdateChecker.releaseVersion(for: "mac-v2026.09.19"))
    }

    func testCanaryTagsParseByTimestampAndAreFlagged() {
        XCTAssertEqual(
            UpdateChecker.releaseVersion(for: "mac-v2026.09.19.0334-canary-abc1234"),
            202609190334
        )
        XCTAssertTrue(UpdateChecker.isCanaryTag("mac-v2026.09.19.0334-canary-abc1234"))
        XCTAssertFalse(UpdateChecker.isCanaryTag("mac-v2026.09.19.0334"))
    }

    func testChecksumsParsingFindsTealeZip() {
        let zipHash = String(repeating: "ab", count: 32)
        let checksums = """
        \(String(repeating: "11", count: 32))  Teale.dmg
        \(zipHash.uppercased())  Teale.zip
        \(String(repeating: "22", count: 32))  teale-macos-arm64
        """
        XCTAssertEqual(UpdateChecker.expectedSHA256(in: checksums, for: "Teale.zip"), zipHash)
        XCTAssertEqual(
            UpdateChecker.expectedSHA256(in: "\(zipHash) *dist/Teale.zip\n", for: "Teale.zip"),
            zipHash
        )
        XCTAssertNil(UpdateChecker.expectedSHA256(in: "deadbeef  Teale.zip\n", for: "Teale.zip"))
        XCTAssertNil(UpdateChecker.expectedSHA256(in: checksums, for: "Missing.zip"))
    }

    func testSHA256OfFileMatchesKnownDigest() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("abc".utf8).write(to: url)
        XCTAssertEqual(
            try UpdateChecker.sha256Hex(of: url),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        )
    }
}
