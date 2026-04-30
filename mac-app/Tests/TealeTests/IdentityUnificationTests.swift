import Foundation
import XCTest
@testable import Teale
@testable import AppCore
import GatewayKit
import WANKit

final class IdentityUnificationTests: XCTestCase {
    func testGatewaySeedDerivesMatchingWANNodeIdentity() throws {
        let seed = Data((0..<32).map(UInt8.init))
        let gatewayIdentity = try GatewayIdentity(seedData: seed)
        let wanIdentity = try WANNodeIdentity(privateKeyData: gatewayIdentity.privateKeyRawRepresentation)

        XCTAssertEqual(gatewayIdentity.deviceID, wanIdentity.nodeID)
        XCTAssertEqual(gatewayIdentity.publicKey, wanIdentity.publicKey.rawRepresentation)
    }

    func testResolveCanonicalWANIdentityMigratesLegacyStoredIdentity() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let identityFileURL = tempDir.appendingPathComponent(WANNodeIdentity.identityFileName)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let legacyIdentity = WANNodeIdentity()
        try WANNodeIdentity.saveToFile(legacyIdentity, at: identityFileURL)

        let gatewayIdentity = try GatewayIdentity(seedData: Data((32..<64).map(UInt8.init)))
        let resolution = try AppState.resolveCanonicalWANIdentity(
            gatewayIdentity: gatewayIdentity,
            identityFileURL: identityFileURL
        )
        let storedIdentity = try WANNodeIdentity.loadFromFile(at: identityFileURL)

        XCTAssertEqual(resolution.identity.nodeID, gatewayIdentity.deviceID)
        XCTAssertEqual(storedIdentity.nodeID, gatewayIdentity.deviceID)
        XCTAssertEqual(resolution.previousStoredNodeID, legacyIdentity.nodeID)
        XCTAssertTrue(resolution.replacedLegacyIdentity)
    }

    func testServingStatusLineExplainsGatewayRequirements() {
        let line = CompanionEngineState.serving("Hermes 3 8B").statusLine

        XCTAssertTrue(line.contains("relay"))
        XCTAssertTrue(line.contains("gateway"))
        XCTAssertTrue(line.contains("identity"))
    }

    func testIdentityMismatchPreventsEarningEligibility() {
        let status = CompanionSupplyIdentityStatus(
            gatewayDeviceID: String(repeating: "a", count: 64),
            wanNodeID: String(repeating: "b", count: 64),
            localServingReady: true,
            relayConnected: true
        )

        XCTAssertTrue(status.identityMismatch)
        XCTAssertFalse(status.earningEligible)
        XCTAssertEqual(status.eligibilityLabel, "Not yet")
    }
}
