import XCTest
@testable import PrivacyFilterKit

final class PrivacyFilterKitTests: XCTestCase {

    func testPlannerReusesPlaceholderForRepeatedSensitiveValue() {
        var planner = PrivacyPlaceholderPlanner()
        let first = planner.replaceSpans(
            in: "Alice emailed alice@example.com.",
            spans: [
                .init(label: "private_person", start: 0, end: 5, text: "Alice"),
                .init(label: "private_email", start: 14, end: 31, text: "alice@example.com"),
            ]
        )
        let second = planner.replaceSpans(
            in: "Alice replied later.",
            spans: [
                .init(label: "private_person", start: 0, end: 5, text: "Alice"),
            ]
        )

        XCTAssertEqual(first, "<PRIVATE_PERSON_1> emailed <PRIVATE_EMAIL_1>.")
        XCTAssertEqual(second, "<PRIVATE_PERSON_1> replied later.")
        XCTAssertEqual(planner.placeholderMap["<PRIVATE_PERSON_1>"], "Alice")
        XCTAssertEqual(planner.placeholderMap["<PRIVATE_EMAIL_1>"], "alice@example.com")
    }

    func testStreamingRestorerHoldsSplitPlaceholderUntilComplete() {
        let restorer = StreamingPlaceholderRestorer(
            placeholderMap: ["<PRIVATE_PERSON_1>": "Alice"]
        )

        XCTAssertEqual(restorer.consume("Hello <PRIV"), "Hello ")
        XCTAssertEqual(restorer.consume("ATE_PERSON_1> there"), "Alice there")
        XCTAssertEqual(restorer.finish(), "")
    }

    func testStreamingRestorerLeavesTransformedPlaceholderMasked() {
        let restorer = StreamingPlaceholderRestorer(
            placeholderMap: ["<PRIVATE_EMAIL_1>": "alice@example.com"]
        )

        XCTAssertEqual(
            restorer.consume("Contact <PRIVATE-EMAIL_1>"),
            "Contact <PRIVATE-EMAIL_1>"
        )
        XCTAssertEqual(restorer.finish(), "")
    }
}
