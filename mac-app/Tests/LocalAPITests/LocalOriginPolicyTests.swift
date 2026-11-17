import XCTest
@testable import LocalAPI

final class LocalOriginPolicyTests: XCTestCase {
    func testBundledOriginsAreAllowedAndEchoedNormalized() {
        let allowed = LocalOriginPolicy.allowedOrigins(environment: [:])
        XCTAssertEqual(LocalOriginPolicy.matchedOrigin("teale://localhost", allowed: allowed), "teale://localhost")
        XCTAssertEqual(LocalOriginPolicy.matchedOrigin("http://teale.localhost", allowed: allowed), "http://teale.localhost")
        XCTAssertEqual(LocalOriginPolicy.matchedOrigin("https://teale.localhost", allowed: allowed), "https://teale.localhost")
        XCTAssertEqual(LocalOriginPolicy.matchedOrigin("TEALE://LOCALHOST", allowed: allowed), "teale://localhost")
    }

    func testForeignOriginsAreRejected() {
        let allowed = LocalOriginPolicy.allowedOrigins(environment: [:])
        XCTAssertNil(LocalOriginPolicy.matchedOrigin("https://evil.example", allowed: allowed))
        XCTAssertNil(LocalOriginPolicy.matchedOrigin("null", allowed: allowed))
        XCTAssertNil(LocalOriginPolicy.matchedOrigin("http://localhost:3000", allowed: allowed))
        XCTAssertNil(LocalOriginPolicy.matchedOrigin("teale://localhost.evil.example", allowed: allowed))
    }

    func testHTTPSOverrideOriginIsAllowedButHTTPOverrideIsIgnored() {
        let https = LocalOriginPolicy.allowedOrigins(
            environment: ["TEALE_DESKTOP_WEB_URL": "https://dev.teale.com/desktop/index.html"]
        )
        XCTAssertEqual(LocalOriginPolicy.matchedOrigin("https://dev.teale.com", allowed: https), "https://dev.teale.com")
        XCTAssertNil(LocalOriginPolicy.matchedOrigin("https://teale.com", allowed: https))

        let withPort = LocalOriginPolicy.allowedOrigins(
            environment: ["TEALE_DESKTOP_WEB_URL": "https://dev.teale.com:8443/"]
        )
        XCTAssertNotNil(LocalOriginPolicy.matchedOrigin("https://dev.teale.com:8443", allowed: withPort))

        let http = LocalOriginPolicy.allowedOrigins(
            environment: ["TEALE_DESKTOP_WEB_URL": "http://dev.teale.com/"]
        )
        XCTAssertEqual(http, LocalOriginPolicy.bundledOrigins)
        XCTAssertNil(LocalOriginPolicy.desktopWebOverrideURL(environment: ["TEALE_DESKTOP_WEB_URL": "http://x.test/"]))
    }

    func testOriginOfOmitsDefaultPorts() {
        XCTAssertEqual(LocalOriginPolicy.origin(of: URL(string: "https://a.example:443/x")!), "https://a.example")
        XCTAssertEqual(LocalOriginPolicy.origin(of: URL(string: "https://a.example:444/x")!), "https://a.example:444")
        XCTAssertEqual(LocalOriginPolicy.origin(of: URL(string: "teale://localhost/")!), "teale://localhost")
    }

    func testHostGuardAcceptsOnlyLoopbackOnOurPort() {
        XCTAssertTrue(LocalOriginPolicy.isAllowedHost("127.0.0.1:11435", port: 11435))
        XCTAssertTrue(LocalOriginPolicy.isAllowedHost("localhost:11435", port: 11435))
        XCTAssertTrue(LocalOriginPolicy.isAllowedHost("LOCALHOST:11435", port: 11435))
        XCTAssertTrue(LocalOriginPolicy.isAllowedHost("[::1]:11435", port: 11435))
        XCTAssertTrue(LocalOriginPolicy.isAllowedHost(nil, port: 11435))
        XCTAssertFalse(LocalOriginPolicy.isAllowedHost("attacker.example:11435", port: 11435))
        XCTAssertFalse(LocalOriginPolicy.isAllowedHost("127.0.0.1:11436", port: 11435))
        XCTAssertFalse(LocalOriginPolicy.isAllowedHost("127.0.0.1", port: 11435))
    }
}
