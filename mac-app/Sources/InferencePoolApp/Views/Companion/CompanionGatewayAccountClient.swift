import Foundation
import GatewayKit

actor CompanionGatewayAccountClient {
    private let authClient: GatewayAuthClient

    init(authClient: GatewayAuthClient) {
        self.authClient = authClient
    }

    func linkAccount(_ request: CompanionGatewayAccountLinkRequest) async throws -> CompanionGatewayAccountSummary {
        let token = try await authClient.bearer()
        return try await authClient.postJSON(
            path: "/v1/account/link",
            body: request,
            bearerToken: token
        )
    }

    func fetchAccountSummary() async throws -> CompanionGatewayAccountSummary {
        let token = try await authClient.bearer()
        return try await authClient.getJSON(path: "/v1/account", bearerToken: token)
    }
}

struct CompanionGatewayAccountLinkRequest: Encodable {
    let accountUserID: String
    let deviceName: String?
    let platform: String?
    let displayName: String?
    let phone: String?
    let email: String?
    let githubUsername: String?
}

struct CompanionGatewayAccountSummary: Decodable {
    let accountUserID: String
    let balanceCredits: Int64
    let usdcCents: Int64
    let displayName: String?
    let phone: String?
    let email: String?
    let githubUsername: String?
    let devices: [CompanionGatewayAccountDevice]
    let transactions: [CompanionGatewayAccountTransaction]

    private enum CodingKeys: String, CodingKey {
        case accountUserID = "account_user_id"
        case balanceCredits = "balance_credits"
        case usdcCents = "usdc_cents"
        case displayName = "display_name"
        case phone
        case email
        case githubUsername = "github_username"
        case devices
        case transactions
    }
}

struct CompanionGatewayAccountDevice: Decodable, Identifiable, Hashable {
    let deviceID: String
    let deviceName: String?
    let platform: String?
    let linkedAt: Int64
    let lastSeen: Int64
    let walletBalanceCredits: Int64
    let walletUsdcCents: Int64

    var id: String { deviceID }

    private enum CodingKeys: String, CodingKey {
        case deviceID = "device_id"
        case deviceName = "device_name"
        case platform
        case linkedAt = "linked_at"
        case lastSeen = "last_seen"
        case walletBalanceCredits = "wallet_balance_credits"
        case walletUsdcCents = "wallet_usdc_cents"
    }
}

struct CompanionGatewayAccountTransaction: Decodable, Hashable {
    let id: Int64
    let accountUserID: String
    let asset: String
    let amount: Int64
    let type: String
    let timestamp: Int64
    let deviceID: String?
    let note: String?

    private enum CodingKeys: String, CodingKey {
        case id
        case accountUserID = "account_user_id"
        case asset
        case amount
        case type = "type"
        case timestamp
        case deviceID = "device_id"
        case note
    }
}
