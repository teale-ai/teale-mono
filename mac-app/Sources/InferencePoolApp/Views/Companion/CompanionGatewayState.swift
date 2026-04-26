import Foundation
import Observation
import AppCore
import GatewayKit

@MainActor
@Observable
final class CompanionGatewayState {
    var networkModels: [CompanionNetworkModelSummary] = []
    var networkStats: CompanionGatewayNetworkStats?
    var bearerToken: String = ""
    var accountSummary: CompanionGatewayAccountSummary?
    var pendingWalletRecipient: String?
    var isLoadingAccountDevices = false
    var lastModelRefreshError: String?
    var lastStatsRefreshError: String?
    var lastAccountRefreshError: String?

    private var authClient: GatewayAuthClient?
    private var accountClient: CompanionGatewayAccountClient?
    private var authBaseURL: URL?
    private var modelsFetchedAt: Date?
    private var statsFetchedAt: Date?
    private var accountFetchedAt: Date?
    private var accountLinkedAt: Date?
    private var linkedAccountUserID: String?

    func refresh(appState: AppState, force: Bool = false) async {
        let rootURL = companionGatewayRootURL(for: appState.gatewayFallbackURL)
        let apiBaseURL = companionGatewayAPIBaseURL(for: appState.gatewayFallbackURL)
        if authBaseURL != rootURL || authClient == nil {
            authBaseURL = rootURL
            authClient = GatewayAuthClient(baseURL: rootURL)
            accountClient = authClient.map { CompanionGatewayAccountClient(authClient: $0) }
            modelsFetchedAt = nil
            statsFetchedAt = nil
            accountFetchedAt = nil
            accountLinkedAt = nil
        }

        let token = await ensureBearer(appState: appState)
        let now = Date()

        await refreshAccount(appState: appState, now: now, force: force)

        if force || shouldRefresh(lastFetchedAt: modelsFetchedAt, now: now, interval: 10) {
            await refreshModels(baseURL: apiBaseURL, bearerToken: token)
            modelsFetchedAt = now
        }

        if force || shouldRefresh(lastFetchedAt: statsFetchedAt, now: now, interval: 15) {
            await refreshStats(baseURL: apiBaseURL)
            statsFetchedAt = now
        }
    }

    var selectedNetworkModelID: String {
        networkModels.first?.id ?? "teale/auto"
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

    private func ensureBearer(appState: AppState) async -> String? {
        if !appState.gatewayAPIKey.isEmpty {
            bearerToken = appState.gatewayAPIKey
        }

        guard let authClient else {
            return bearerToken.isEmpty ? nil : bearerToken
        }

        do {
            let token = try await authClient.bearer()
            bearerToken = token
            appState.gatewayAPIKey = token
            return token
        } catch {
            if !appState.gatewayAPIKey.isEmpty {
                bearerToken = appState.gatewayAPIKey
                return appState.gatewayAPIKey
            }
            return nil
        }
    }

    private func refreshModels(baseURL: URL, bearerToken: String?) async {
        do {
            let envelope: GatewayModelsEnvelope = try await getJSON(
                url: baseURL.appending(path: "models")
            )

            var deviceCounts: [String: Int] = [:]
            if let bearerToken, !bearerToken.isEmpty {
                let network: GatewayNetworkEnvelope = try await getJSON(
                    url: baseURL.appending(path: "network"),
                    bearerToken: bearerToken
                )

                for device in network.devices where device.isAvailable && !device.heartbeatStale {
                    for modelID in device.loadedModels {
                        deviceCounts[modelID, default: 0] += 1
                    }
                }
            }

            networkModels = envelope.data
                .map { model in
                    let effectiveDeviceCount = max(
                        model.loadedDeviceCount ?? 0,
                        deviceCounts[model.id, default: 0]
                    )
                    return CompanionNetworkModelSummary(
                        id: model.id,
                        deviceCount: effectiveDeviceCount,
                        promptUSDPerToken: Double(model.pricing?.prompt ?? ""),
                        completionUSDPerToken: Double(model.pricing?.completion ?? "")
                    )
                }
                .filter { $0.deviceCount > 0 && !$0.id.hasPrefix("teale/") }
                .sorted { left, right in
                    if left.deviceCount != right.deviceCount {
                        return left.deviceCount > right.deviceCount
                    }
                    let leftCompletion = left.completionUSDPerToken ?? .greatestFiniteMagnitude
                    let rightCompletion = right.completionUSDPerToken ?? .greatestFiniteMagnitude
                    if leftCompletion != rightCompletion {
                        return leftCompletion < rightCompletion
                    }
                    return left.id < right.id
                }

            lastModelRefreshError = nil
        } catch {
            lastModelRefreshError = error.localizedDescription
        }
    }

    private func refreshStats(baseURL: URL) async {
        do {
            networkStats = try await getJSON(
                url: baseURL.appending(path: "network/stats")
            )
            lastStatsRefreshError = nil
        } catch {
            lastStatsRefreshError = error.localizedDescription
        }
    }

    private func shouldRefresh(lastFetchedAt: Date?, now: Date, interval: TimeInterval) -> Bool {
        guard let lastFetchedAt else { return true }
        return now.timeIntervalSince(lastFetchedAt) >= interval
    }

    private func refreshAccount(appState: AppState, now: Date, force: Bool) async {
        guard let authManager = appState.authManager,
              let user = authManager.currentUser,
              authManager.authState.isAuthenticated else {
            clearAccountState()
            return
        }

        guard let accountClient else { return }

        let accountUserID = user.id.uuidString
        let shouldLink = force
            || linkedAccountUserID != accountUserID
            || shouldRefresh(lastFetchedAt: accountLinkedAt, now: now, interval: 60)
        let shouldFetch = force
            || shouldRefresh(lastFetchedAt: accountFetchedAt, now: now, interval: 12)

        guard shouldLink || shouldFetch else { return }

        isLoadingAccountDevices = true
        defer { isLoadingAccountDevices = false }

        do {
            if shouldLink {
                let summary = try await accountClient.linkAccount(
                    CompanionGatewayAccountLinkRequest(
                        accountUserID: accountUserID,
                        deviceName: appState.companionDeviceName,
                        platform: "macos",
                        displayName: user.displayName,
                        phone: user.phone,
                        email: user.email,
                        githubUsername: nil
                    )
                )
                accountSummary = summary
                linkedAccountUserID = accountUserID
                accountLinkedAt = now
                accountFetchedAt = now
            }

            if shouldFetch && !shouldLink {
                accountSummary = try await accountClient.fetchAccountSummary()
                accountFetchedAt = now
            }

            lastAccountRefreshError = nil
        } catch {
            lastAccountRefreshError = error.localizedDescription
        }
    }

    private func clearAccountState() {
        accountSummary = nil
        lastAccountRefreshError = nil
        isLoadingAccountDevices = false
        accountFetchedAt = nil
        accountLinkedAt = nil
        linkedAccountUserID = nil
    }

    private func getJSON<T: Decodable>(url: URL, bearerToken: String? = nil) async throws -> T {
        var request = URLRequest(url: url)
        if let bearerToken, !bearerToken.isEmpty {
            request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw GatewayAuthError.network("non-http response")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw GatewayAuthError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(T.self, from: data)
    }
}

struct CompanionGatewayNetworkStats: Decodable {
    let totalDevices: Int
    let totalRamGB: Double
    let totalModels: Int
    let avgTtftMs: Double?
    let avgTps: Double?
    let totalCreditsEarned: Int64
    let totalCreditsSpent: Int64
    let totalUsdcDistributedCents: Int64
}

private struct GatewayModelsEnvelope: Decodable {
    let data: [GatewayModelEntry]
}

private struct GatewayModelEntry: Decodable {
    let id: String
    let pricing: GatewayPricing?
    let loadedDeviceCount: Int?
}

private struct GatewayPricing: Decodable {
    let prompt: String
    let completion: String
}

private struct GatewayNetworkEnvelope: Decodable {
    let devices: [GatewayNetworkDevice]
}

private struct GatewayNetworkDevice: Decodable {
    let loadedModels: [String]
    let isAvailable: Bool
    let heartbeatStale: Bool

    enum CodingKeys: String, CodingKey {
        case loadedModels
        case isAvailable
        case heartbeatStale
    }
}

func companionGatewayRootURL(for fallbackURL: String) -> URL {
    let fallback = URL(string: "https://gateway.teale.com")!
    guard var components = URLComponents(string: fallbackURL) else {
        return fallback
    }

    if components.scheme == "wss" {
        components.scheme = "https"
    } else if components.scheme == "ws" {
        components.scheme = "http"
    }

    if let host = components.host, host.hasPrefix("relay.") {
        components.host = host.replacingOccurrences(of: "relay.", with: "gateway.", options: .anchored)
    }

    components.path = ""
    components.query = nil
    components.fragment = nil
    return components.url ?? fallback
}

func companionGatewayAPIBaseURL(for fallbackURL: String) -> URL {
    companionGatewayRootURL(for: fallbackURL).appending(path: "v1")
}
