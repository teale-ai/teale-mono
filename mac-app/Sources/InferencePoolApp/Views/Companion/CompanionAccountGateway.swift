import Foundation
import Observation
import AppCore
import AuthKit
import GatewayKit
import SharedTypes

@MainActor
@Observable
final class CompanionAccountState {
    var snapshot: CompanionAccountWalletSnapshot?
    var loading = false
    var syncNotice: String?
    var syncNoticeIsError = false
    var sweepStatus = ""
    var sweepStatusIsError = false
    var sendStatus = ""
    var sendStatusIsError = false
    var isSending = false
    var sweepingDeviceID: String?

    func refresh(appState: AppState, authManager: AuthManager?) async {
        guard let user = signedInUser(from: authManager) else {
            reset()
            return
        }

        loading = true
        if snapshot == nil {
            syncNotice = appState.companionText(
                "account.syncing",
                fallback: "Linking this signed-in profile to the gateway account wallet."
            )
            syncNoticeIsError = false
        }

        do {
            snapshot = try await CompanionAccountGatewayClient.linkAndLoadSummary(
                appState: appState,
                user: user,
                deviceName: appState.companionDeviceName,
                platform: .macos
            )
            syncNotice = nil
            syncNoticeIsError = false
        } catch {
            if snapshot == nil {
                snapshot = nil
            }
            syncNotice = gatewayErrorMessage(error)
            syncNoticeIsError = true
        }

        loading = false
    }

    func sweep(deviceID: String, appState: AppState, authManager: AuthManager?) async {
        guard signedInUser(from: authManager) != nil else {
            snapshot = nil
            sweepStatus = appState.companionText(
                "account.signInForWallet",
                fallback: "Sign in to load the account wallet."
            )
            sweepStatusIsError = true
            return
        }

        sweepingDeviceID = deviceID
        sweepStatus = ""
        sweepStatusIsError = false

        do {
            let result = try await CompanionAccountGatewayClient.sweep(
                appState: appState,
                deviceID: deviceID
            )
            snapshot = result.account
            if result.sweptCredits > 0 || result.sweptUSCDCents > 0 {
                sweepStatus = appState.companionText(
                    "account.sweptSuccess",
                    fallback: "Swept {{amount}} into the account wallet.",
                    replacements: [
                        "amount": appState.companionDisplayAmountString(credits: result.sweptCredits)
                    ]
                )
            } else {
                sweepStatus = appState.companionText(
                    "account.nothingToSweep",
                    fallback: "This device wallet has nothing available to sweep."
                )
            }
        } catch {
            sweepStatus = gatewayErrorMessage(error)
            sweepStatusIsError = true
        }

        sweepingDeviceID = nil
    }

    func send(
        recipient: String,
        amountCredits: Int,
        memo: String,
        appState: AppState,
        authManager: AuthManager?
    ) async {
        guard signedInUser(from: authManager) != nil else {
            snapshot = nil
            sendStatus = appState.companionText(
                "account.signInForWallet",
                fallback: "Sign in to load the account wallet."
            )
            sendStatusIsError = true
            return
        }

        isSending = true
        sendStatus = ""
        sendStatusIsError = false

        do {
            let normalizedRecipient = try normalizedRecipientID(recipient)
            let trimmedMemo = memo.trimmingCharacters(in: .whitespacesAndNewlines)
            _ = try await CompanionAccountGatewayClient.send(
                appState: appState,
                recipient: normalizedRecipient,
                amountCredits: amountCredits,
                memo: trimmedMemo.isEmpty ? nil : trimmedMemo
            )
            snapshot = try await CompanionAccountGatewayClient.loadSummary(appState: appState)
            sendStatus = "\(appState.companionText("wallet.sentPrefix", fallback: "Sent")) \(appState.companionDisplayAmountString(credits: amountCredits))."
        } catch {
            sendStatus = gatewayErrorMessage(error)
            sendStatusIsError = true
        }

        isSending = false
    }

    private func reset() {
        snapshot = nil
        loading = false
        syncNotice = nil
        syncNoticeIsError = false
        sweepStatus = ""
        sweepStatusIsError = false
        sendStatus = ""
        sendStatusIsError = false
        isSending = false
        sweepingDeviceID = nil
    }

    private func signedInUser(from authManager: AuthManager?) -> UserProfile? {
        guard let authManager, authManager.authState.isAuthenticated else { return nil }
        return authManager.currentUser
    }
}

private enum CompanionAccountGatewayClient {
    @MainActor
    static func linkAndLoadSummary(
        appState: AppState,
        user: UserProfile,
        deviceName: String,
        platform: DevicePlatform
    ) async throws -> CompanionAccountWalletSnapshot {
        let request = CompanionAccountLinkRequest(
            accountUserID: user.id.uuidString,
            deviceName: deviceName,
            platform: platform.rawValue,
            displayName: user.displayName,
            phone: user.phone,
            email: user.email,
            githubUsername: nil
        )
        let _: CompanionAccountWalletSnapshot = try await postJSON(
            appState: appState,
            path: "/v1/account/link",
            body: request
        )
        return try await loadSummary(appState: appState)
    }

    @MainActor
    static func loadSummary(appState: AppState) async throws -> CompanionAccountWalletSnapshot {
        try await getJSON(
            appState: appState,
            path: "/v1/account/summary"
        )
    }

    @MainActor
    static func sweep(
        appState: AppState,
        deviceID: String
    ) async throws -> CompanionAccountSweepResult {
        try await postJSON(
            appState: appState,
            path: "/v1/account/sweep",
            body: CompanionAccountSweepRequest(deviceID: deviceID)
        )
    }

    @MainActor
    static func send(
        appState: AppState,
        recipient: String,
        amountCredits: Int,
        memo: String?
    ) async throws -> CompanionAccountTransferReceipt {
        try await postJSON(
            appState: appState,
            path: "/v1/account/send",
            body: CompanionAccountSendRequest(
                asset: "credits",
                recipient: recipient,
                amount: amountCredits,
                memo: memo
            )
        )
    }

    @MainActor
    private static func getJSON<Response: Decodable>(
        appState: AppState,
        path: String
    ) async throws -> Response {
        let client = GatewayAuthClient(baseURL: companionGatewayRootURL(for: appState.gatewayFallbackURL))
        let token = try await bearer(using: client, appState: appState)
        do {
            return try await client.getJSON(path: path, bearerToken: token)
        } catch let GatewayAuthError.http(code, _) where code == 401 {
            let refreshed = try await refreshBearer(using: client, appState: appState)
            return try await client.getJSON(path: path, bearerToken: refreshed)
        }
    }

    @MainActor
    private static func postJSON<Request: Encodable, Response: Decodable>(
        appState: AppState,
        path: String,
        body: Request
    ) async throws -> Response {
        let client = GatewayAuthClient(baseURL: companionGatewayRootURL(for: appState.gatewayFallbackURL))
        let token = try await bearer(using: client, appState: appState)
        do {
            return try await client.postJSON(path: path, body: body, bearerToken: token)
        } catch let GatewayAuthError.http(code, _) where code == 401 {
            let refreshed = try await refreshBearer(using: client, appState: appState)
            return try await client.postJSON(path: path, body: body, bearerToken: refreshed)
        }
    }

    @MainActor
    private static func bearer(using client: GatewayAuthClient, appState: AppState) async throws -> String {
        if !appState.gatewayAPIKey.isEmpty {
            return appState.gatewayAPIKey
        }
        let token = try await client.bearer()
        appState.gatewayAPIKey = token
        return token
    }

    @MainActor
    private static func refreshBearer(using client: GatewayAuthClient, appState: AppState) async throws -> String {
        appState.gatewayAPIKey = ""
        let token = try await client.bearer()
        appState.gatewayAPIKey = token
        return token
    }
}

struct CompanionAccountWalletSnapshot: Decodable {
    let accountUserID: String
    let balanceCredits: Int64
    let usdcCents: Int64
    let displayName: String?
    let phone: String?
    let email: String?
    let githubUsername: String?
    let devices: [CompanionAccountDeviceSnapshot]
    let transactions: [CompanionAccountLedgerEntry]

    enum CodingKeys: String, CodingKey {
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

struct CompanionAccountDeviceSnapshot: Decodable, Identifiable {
    let deviceID: String
    let deviceName: String?
    let platform: String?
    let linkedAt: Int64
    let lastSeen: Int64
    let walletBalanceCredits: Int64
    let walletUSCDCents: Int64

    var id: String { deviceID }

    enum CodingKeys: String, CodingKey {
        case deviceID = "device_id"
        case deviceName = "device_name"
        case platform
        case linkedAt = "linked_at"
        case lastSeen = "last_seen"
        case walletBalanceCredits = "wallet_balance_credits"
        case walletUSCDCents = "wallet_usdc_cents"
    }
}

struct CompanionAccountLedgerEntry: Decodable, Identifiable {
    let id: Int64
    let accountUserID: String
    let asset: String
    let amount: Int64
    let entryType: String
    let timestamp: Int64
    let deviceID: String?
    let note: String?

    enum CodingKeys: String, CodingKey {
        case id
        case accountUserID = "account_user_id"
        case asset
        case amount
        case entryType = "type"
        case timestamp
        case deviceID = "device_id"
        case note
    }
}

struct CompanionAccountSweepResult: Decodable {
    let sweptCredits: Int64
    let sweptUSCDCents: Int64
    let account: CompanionAccountWalletSnapshot

    enum CodingKeys: String, CodingKey {
        case sweptCredits = "swept_credits"
        case sweptUSCDCents = "swept_usdc_cents"
        case account
    }
}

struct CompanionAccountTransferReceipt: Decodable {
    let asset: String
    let amount: Int64
}

private struct CompanionAccountLinkRequest: Encodable {
    let accountUserID: String
    let deviceName: String
    let platform: String
    let displayName: String?
    let phone: String?
    let email: String?
    let githubUsername: String?
}

private struct CompanionAccountSweepRequest: Encodable {
    let deviceID: String
}

private struct CompanionAccountSendRequest: Encodable {
    let asset: String
    let recipient: String
    let amount: Int
    let memo: String?
}

private func normalizedRecipientID(_ rawValue: String) throws -> String {
    let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
    if looksLikeFullDeviceWalletID(trimmed) {
        return "device:\(trimmed.lowercased())"
    }
    if looksLikeAccountWalletID(trimmed) {
        return "account:\(trimmed)"
    }
    throw GatewayAuthError.network(
        "Enter a full device wallet ID or full account wallet ID. Short IDs are not accepted."
    )
}

private func looksLikeFullDeviceWalletID(_ value: String) -> Bool {
    let pattern = #"^[0-9a-fA-F]{64}$"#
    return value.range(of: pattern, options: .regularExpression) != nil
}

private func looksLikeAccountWalletID(_ value: String) -> Bool {
    UUID(uuidString: value) != nil
}

private func gatewayErrorMessage(_ error: Error) -> String {
    if let gatewayError = error as? GatewayAuthError {
        return gatewayError.description
    }
    return error.localizedDescription
}
