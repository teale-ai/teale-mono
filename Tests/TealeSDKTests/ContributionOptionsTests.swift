import XCTest
@testable import TealeSDK

final class ContributionOptionsTests: XCTestCase {
    func testDefaultOptions() {
        let options = ContributionOptions()
        XCTAssertTrue(options.requireWiFi)
        XCTAssertTrue(options.requirePluggedIn)
        XCTAssertEqual(options.maxConcurrentRequests, 1)
        XCTAssertNil(options.allowedModelFamilies)
    }

    func testScheduleConversion() {
        let options = ContributionOptions(schedule: .afterHours, requireWiFi: true, requirePluggedIn: true)
        let schedule = options.toContributionSchedule()
        XCTAssertTrue(schedule.onlyOnWiFi)
        XCTAssertTrue(schedule.onlyWhenPluggedIn)
    }
}
