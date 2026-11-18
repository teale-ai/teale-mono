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

    /// Offsets of `needle` in `text` counted in Unicode scalars, the unit the
    /// Python helper (str indices) and the Rust node use.
    private func scalarSpan(of needle: String, in text: String) -> (start: Int, end: Int) {
        let range = text.range(of: needle)!
        let scalars = text.unicodeScalars
        let start = scalars.distance(from: scalars.startIndex, to: range.lowerBound)
        let end = scalars.distance(from: scalars.startIndex, to: range.upperBound)
        return (start, end)
    }

    func testPlannerUsesUnicodeScalarOffsetsAfterEmoji() {
        // ZWJ family emoji = 7 scalars but 1 grapheme; flag = 2 scalars, 1 grapheme.
        let family = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}\u{200D}\u{1F466}"
        let flag = "\u{1F1FA}\u{1F1F8}"
        let text = "\(family) mail alice@example.com \(flag) call +1 415 555 0100 now"

        let email = scalarSpan(of: "alice@example.com", in: text)
        let phone = scalarSpan(of: "+1 415 555 0100", in: text)
        // Sanity: grapheme offsets differ, so a Character-based slicer would cut wrong.
        let emailGraphemeStart = text.distance(from: text.startIndex, to: text.range(of: "alice@example.com")!.lowerBound)
        XCTAssertNotEqual(email.start, emailGraphemeStart)

        var planner = PrivacyPlaceholderPlanner()
        let redacted = planner.replaceSpans(
            in: text,
            spans: [
                .init(label: "private_email", start: email.start, end: email.end, text: "alice@example.com"),
                .init(label: "private_phone", start: phone.start, end: phone.end, text: "+1 415 555 0100"),
            ]
        )

        XCTAssertEqual(redacted, "\(family) mail <PRIVATE_EMAIL_1> \(flag) call <PRIVATE_PHONE_1> now")
        XCTAssertFalse(redacted.contains("alice"))
        XCTAssertFalse(redacted.contains("555"))
    }

    func testPlannerSkipsOutOfRangeSpans() {
        var planner = PrivacyPlaceholderPlanner()
        let redacted = planner.replaceSpans(
            in: "short",
            spans: [.init(label: "private_person", start: 2, end: 99, text: "ort")]
        )
        XCTAssertEqual(redacted, "short")
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
