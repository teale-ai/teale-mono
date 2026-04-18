import XCTest
import Foundation
@testable import SharedTypes

final class InferenceEngineTests: XCTestCase {

    func testThrottleLevelOrdering() {
        XCTAssertTrue(ThrottleLevel.paused < ThrottleLevel.minimal)
        XCTAssertTrue(ThrottleLevel.minimal < ThrottleLevel.reduced)
        XCTAssertTrue(ThrottleLevel.reduced < ThrottleLevel.full)
    }

    func testThrottleLevelValues() {
        XCTAssertEqual(ThrottleLevel.paused.rawValue, 0)
        XCTAssertEqual(ThrottleLevel.minimal.rawValue, 25)
        XCTAssertEqual(ThrottleLevel.reduced.rawValue, 75)
        XCTAssertEqual(ThrottleLevel.full.rawValue, 100)
    }
}
