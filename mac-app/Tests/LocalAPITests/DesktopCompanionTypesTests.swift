import XCTest
@testable import LocalAPI

final class DesktopCompanionTypesTests: XCTestCase {
    func testNetworkStatsDecodeGatewayCamelCaseAndEncodeLocalSnakeCase() throws {
        let json = """
        {
          "totalDevices": 18,
          "totalRamGB": 3525.1541328430176,
          "totalModels": 5,
          "avgTtftMs": 325,
          "avgTps": 34.0,
          "totalCreditsEarned": 480593663,
          "totalCreditsSpent": 110095430,
          "totalUsdcDistributedCents": 0
        }
        """.data(using: .utf8)!

        let snapshot = try JSONDecoder().decode(DesktopCompanionNetworkStatsSnapshot.self, from: json)
        XCTAssertEqual(snapshot.total_devices, 18)
        XCTAssertEqual(snapshot.total_ram_gb, 3525.1541328430176, accuracy: 0.0001)
        XCTAssertEqual(snapshot.total_models, 5)
        XCTAssertEqual(snapshot.avg_ttft_ms, 325)
        XCTAssertEqual(snapshot.avg_tps ?? 0, 34.0, accuracy: 0.001)
        XCTAssertEqual(snapshot.total_credits_earned, 480593663)
        XCTAssertEqual(snapshot.total_credits_spent, 110095430)

        let encoded = try JSONEncoder().encode(snapshot)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertEqual(object["total_devices"] as? Int, 18)
        XCTAssertNil(object["totalDevices"])
    }

    func testAccountAPIKeyDecodeCurrentGatewayShape() throws {
        let json = """
        {
          "keyID": "key-1",
          "accountUserID": "account-1",
          "prefix": "tk_live_abcd",
          "name": "Hermes",
          "role": "live",
          "usageCredits": 42,
          "disabled": false,
          "createdAt": 1710000000,
          "lastUsedAt": 1710000100
        }
        """.data(using: .utf8)!

        let key = try JSONDecoder().decode(DesktopCompanionAccountAPIKeySnapshot.self, from: json)
        XCTAssertEqual(key.keyID, "key-1")
        XCTAssertEqual(key.tokenPreview, "tk_live_abcd")
        XCTAssertEqual(key.label, "Hermes")
        XCTAssertEqual(key.createdAt, 1710000000)
        XCTAssertEqual(key.lastUsedAt, 1710000100)
        XCTAssertNil(key.revokedAt)
    }

    func testMintedAPIKeyDecodeCurrentGatewayShape() throws {
        let json = """
        {
          "keyID": "key-2",
          "accountUserID": "account-1",
          "prefix": "tk_prov_abcd",
          "name": "Provisioning",
          "role": "provisioning",
          "usageCredits": 0,
          "disabled": false,
          "createdAt": 1710000200,
          "token": "tk_prov_abcd_secret"
        }
        """.data(using: .utf8)!

        let minted = try JSONDecoder().decode(DesktopCompanionAccountAPIKeyMintedResponse.self, from: json)
        XCTAssertEqual(minted.keyID, "key-2")
        XCTAssertEqual(minted.token, "tk_prov_abcd_secret")
        XCTAssertEqual(minted.label, "Provisioning")
        XCTAssertEqual(minted.createdAt, 1710000200)
    }
}
