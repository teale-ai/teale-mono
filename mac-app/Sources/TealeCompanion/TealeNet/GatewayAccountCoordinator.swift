import Foundation
import Observation
import AuthKit
import GatewayKit

@MainActor
@Observable
final class GatewayAccountCoordinator {
    var summary: CompanionGatewayAccountSummary?
    var isLoading = false
    var errorMessage: String?
    var pendingWalletRecipient: String?

    private let authClient: GatewayAuthClient
    private let accountClient: GatewayCompanionAccountClient
    private var linkedAccountUserID: String?
    private var linkedAt: Date?
    private var fetchedAt: Date?

    init(authClient: GatewayAuthClient = GatewayAuthClient()) {
        self.authClient = authClient
        self.accountClient = GatewayCompanionAccountClient(authClient: authClient)
    }

    var localDeviceID: String {
        GatewayIdentity.shared.deviceID
    }

    func stageWalletRecipient(_ recipient: String) {
        pendingWalletRecipient = recipient
    }

    func consumePendingWalletRecipient() -> String? {
        let recipient = pendingWalletRecipient
        pendingWalletRecipient = nil
        return recipient
    }

    func refreshIfNeeded(
        authManager: AuthManager?,
        deviceName: String,
        force: Bool = false
    ) async {
        guard let authManager,
              authManager.authState.isAuthenticated,
              let user = authManager.currentUser else {
            clear()
            return
        }

        let now = Date()
        let accountUserID = user.id.uuidString
        let shouldLink = force
            || linkedAccountUserID != accountUserID
            || shouldRefresh(lastFetchedAt: linkedAt, now: now, interval: 60)
        let shouldFetch = force
            || shouldRefresh(lastFetchedAt: fetchedAt, now: now, interval: 12)

        guard shouldLink || shouldFetch else { return }

        isLoading = true
        defer { isLoading = false }

        do {
            if shouldLink {
                summary = try await accountClient.linkAccount(
                    CompanionGatewayAccountLinkRequest(
                        accountUserID: accountUserID,
                        deviceName: deviceName,
                        platform: "ios",
                        displayName: user.displayName,
                        phone: user.phone,
                        email: user.email,
                        githubUsername: nil
                    )
                )
                linkedAccountUserID = accountUserID
                linkedAt = now
                fetchedAt = now
            }

            if shouldFetch && !shouldLink {
                summary = try await accountClient.fetchAccountSummary()
                fetchedAt = now
            }

            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func clear() {
        summary = nil
        isLoading = false
        errorMessage = nil
        linkedAccountUserID = nil
        linkedAt = nil
        fetchedAt = nil
    }

    private func shouldRefresh(lastFetchedAt: Date?, now: Date, interval: TimeInterval) -> Bool {
        guard let lastFetchedAt else { return true }
        return now.timeIntervalSince(lastFetchedAt) >= interval
    }
}

actor GatewayCompanionAccountClient {
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
        case type
        case timestamp
        case deviceID = "device_id"
        case note
    }
}
