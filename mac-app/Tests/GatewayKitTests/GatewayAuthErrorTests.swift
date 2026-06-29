import XCTest
@testable import GatewayKit

final class GatewayAuthErrorTests: XCTestCase {
    func testLocalizedDescriptionUsesGatewayErrorDescription() {
        XCTAssertEqual(
            GatewayAuthError.http(401, "unauthorized").localizedDescription,
            "HTTP 401: unauthorized"
        )
        XCTAssertEqual(
            GatewayAuthError.network("offline").localizedDescription,
            "network: offline"
        )
        XCTAssertEqual(
            GatewayAuthError.decode("missing field").localizedDescription,
            "decode: missing field"
        )
    }
}
