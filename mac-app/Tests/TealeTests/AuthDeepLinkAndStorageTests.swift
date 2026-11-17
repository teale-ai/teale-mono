import Foundation
import XCTest
@testable import AuthKit
@testable import Teale

final class AuthDeepLinkAndStorageTests: XCTestCase {
    // MARK: - Magic-link parsing (S1)

    func testSessionDeepLinkExtractsToken() {
        let url = URL(string: "teale://auth/session?token=tsess_abc123")!
        XCTAssertEqual(AuthManager.sessionToken(fromDeepLink: url), "tsess_abc123")
        XCTAssertTrue(AuthManager.isSessionDeepLink(url))
    }

    func testNonSessionLinksAreNotAdopted() {
        let urls = [
            "teale://auth/callback?code=abc",
            "teale://auth/session",
            "teale://auth/session?token=",
            "teale://invite/xyz",
            "https://auth/session?token=tsess_abc",
            "teale://localhost/auth/session?token=tsess_abc",
        ]
        for raw in urls {
            XCTAssertNil(AuthManager.sessionToken(fromDeepLink: URL(string: raw)!), raw)
        }
    }

    // MARK: - Token storage migration (S6)

    private final class MemoryStore: GatewaySessionTokenStore, @unchecked Sendable {
        var token: String?
        var failWrites = false
        init(_ token: String? = nil) { self.token = token }
        func read() -> String? { token }
        func write(_ token: String) throws {
            if failWrites { throw GatewaySessionTokenStoreError.keychain(-1) }
            self.token = token
        }
        func delete() { token = nil }
    }

    func testMigrationMovesLegacyTokenIntoPrimaryAndDeletesFile() {
        let primary = MemoryStore()
        let legacy = MemoryStore("tsess_old")
        let store = MigratingGatewaySessionTokenStore(primary: primary, legacy: legacy)
        store.migrateIfNeeded()
        XCTAssertEqual(primary.token, "tsess_old")
        XCTAssertNil(legacy.token)
        XCTAssertEqual(store.read(), "tsess_old")
    }

    func testMigrationKeepsLegacyTokenWhenPrimaryWriteFails() {
        let primary = MemoryStore()
        primary.failWrites = true
        let legacy = MemoryStore("tsess_old")
        let store = MigratingGatewaySessionTokenStore(primary: primary, legacy: legacy)
        store.migrateIfNeeded()
        XCTAssertEqual(legacy.token, "tsess_old")
        XCTAssertEqual(store.read(), "tsess_old")
    }

    func testMigrationPrefersExistingPrimaryToken() {
        let primary = MemoryStore("tsess_new")
        let legacy = MemoryStore("tsess_old")
        let store = MigratingGatewaySessionTokenStore(primary: primary, legacy: legacy)
        store.migrateIfNeeded()
        XCTAssertEqual(primary.token, "tsess_new")
        XCTAssertNil(legacy.token)
    }

    func testFileStoreRoundTripsWith0600Permissions() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = FileGatewaySessionTokenStore(directory: dir)
        XCTAssertNil(store.read())
        try store.write("tsess_file")
        XCTAssertEqual(store.read(), "tsess_file")
        let attrs = try FileManager.default.attributesOfItem(atPath: store.fileURL.path)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        store.delete()
        XCTAssertNil(store.read())
    }

    // MARK: - CLI guard (S12)

    func testBareFirstWordIsTreatedAsCLISubcommand() {
        XCTAssertEqual(TealeApp.cliSubcommand(in: ["supply", "on"]), "supply")
        XCTAssertEqual(TealeApp.cliSubcommand(in: ["mcp"]), "mcp")
        XCTAssertEqual(TealeApp.cliSubcommand(in: ["wallet", "balance"]), "wallet")
    }

    func testDashArgumentsAreTolerated() {
        XCTAssertNil(TealeApp.cliSubcommand(in: []))
        XCTAssertNil(TealeApp.cliSubcommand(in: ["--fleet-supply"]))
        XCTAssertNil(TealeApp.cliSubcommand(in: ["-NSDocumentRevisionsDebugMode", "YES"]))
        XCTAssertNil(TealeApp.cliSubcommand(in: ["-psn_0_12345"]))
    }
}
