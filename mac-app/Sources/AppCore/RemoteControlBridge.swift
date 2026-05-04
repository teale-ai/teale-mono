import Foundation
import SharedTypes
import LocalAPI
import LlamaCppKit
import ModelManager
import TealeNetKit
import AgentKit
import AuthKit
import GatewayKit
import PrivacyFilterKit

@MainActor
final class RemoteControlBridge: @unchecked Sendable, LocalAppControlling {
    private unowned let appState: AppState
    private var desktopGatewayWallet: GatewayWalletBalanceSnapshot?
    private var desktopWalletTransactions: [GatewayWalletTransactionSnapshot] = []
    private var desktopWalletSyncedAt: UInt64?
    private var desktopWalletSyncError: String?
    private var desktopLastWalletRefreshAt: Date?

    init(appState: AppState) {
        self.appState = appState
    }

    func remoteSnapshot() async -> RemoteAppSnapshot {
        await appState.refreshDownloadedModels()
        appState.scanLocalModels()

        let loadedModel = await appState.engine.loadedModel
        let privacyStatus = await DesktopPrivacyFilter.shared.status(for: appState.privacyFilterMode)
        let compatibleModels = appState.modelManager.compatibleModels
        let downloaded = appState.downloadedModelIDs
        let downloading = appState.modelManager.downloadingModels

        var models = compatibleModels.map { model in
            RemoteModelSnapshot(
                id: model.id,
                name: model.name,
                huggingFaceRepo: model.huggingFaceRepo,
                downloaded: downloaded.contains(model.id),
                loaded: loadedModel?.id == model.id,
                downloadingProgress: downloading[model.id]
            )
        }

        let seenModelIDs = Set(models.map(\.id))
        let localModels = appState.scannedLocalModels
            .filter { !seenModelIDs.contains($0.toDescriptor().id) }
            .map { localModel in
                let descriptor = localModel.toDescriptor()
                return RemoteModelSnapshot(
                    id: descriptor.id,
                    name: descriptor.name,
                    huggingFaceRepo: descriptor.huggingFaceRepo,
                    downloaded: true,
                    loaded: loadedModel?.id == descriptor.id,
                    downloadingProgress: nil
                )
            }
        models.append(contentsOf: localModels)

        return RemoteAppSnapshot(
            appVersion: appVersion(),
            loadedModelID: loadedModel?.id,
            loadedModelRepo: loadedModel?.huggingFaceRepo,
            engineStatus: String(describing: appState.engineStatus),
            isServerRunning: appState.isServerRunning,
            auth: authSnapshot(),
            demand: demandSnapshot(loadedModel: loadedModel),
            settings: RemoteSettingsSnapshot(
                clusterEnabled: appState.clusterEnabled,
                wanEnabled: appState.wanEnabled,
                wanRelayURL: appState.wanRelayURL,
                wanBusy: appState.isWANBusy,
                wanLastError: appState.wanLastError,
                wanRelayStatus: appState.wanManager.state.relayStatus.rawValue,
                wanDiscoveredPeerCount: appState.wanManager.state.discoveredPeerCount,
                maxStorageGB: appState.maxStorageGB,
                orgCapacityReservation: appState.clusterManager.orgCapacityReservation,
                clusterPasscodeSet: appState.clusterManager.passcode?.isEmpty == false,
                allowNetworkAccess: appState.allowNetworkAccess,
                electricityCostPerKWh: appState.electricityCostPerKWh,
                electricityCurrency: appState.electricityCurrency,
                electricityMarginMultiplier: appState.electricityMarginMultiplier,
                keepAwake: appState.keepAwake,
                autoManageModels: appState.autoManageModels,
                inferenceBackend: appState.inferenceBackend.rawValue,
                privacyFilterMode: appState.privacyFilterMode.rawValue,
                privacyFilterStatus: privacyStatus.state.rawValue,
                privacyFilterDetail: privacyStatus.detail,
                language: appState.language.rawValue
            ),
            models: models
        )
    }

    private func authSnapshot() -> RemoteAuthConfigSnapshot {
        let config = SupabaseConfig.default
        return RemoteAuthConfigSnapshot(
            configured: config != nil,
            supabaseURL: config?.url.absoluteString,
            supabaseAnonKey: config?.anonKey,
            redirectURL: config?.redirectURL?.absoluteString
        )
    }

    private func demandSnapshot(loadedModel: ModelDescriptor?) -> RemoteDemandSnapshot {
        RemoteDemandSnapshot(
            localBaseURL: "http://127.0.0.1:\(appState.serverPort)/v1",
            localModelID: loadedModel?.openrouterId ?? loadedModel?.huggingFaceRepo,
            networkBaseURL: gatewayBaseURL().absoluteString,
            networkBearerToken: appState.gatewayAPIKey.isEmpty ? nil : appState.gatewayAPIKey
        )
    }

    private func gatewayRootURL() -> URL {
        let fallback = URL(string: "https://gateway.teale.com")!
        guard var components = URLComponents(string: appState.gatewayFallbackURL) else {
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

    private func gatewayBaseURL() -> URL {
        gatewayRootURL().appendingPathComponent("v1")
    }

    func remoteLoadModel(_ request: RemoteModelControlRequest) async throws -> RemoteAppSnapshot {
        // Check if this is a GGUF model request
        if let ggufModel = resolveGGUFModel(request.model) {
            await appState.loadGGUFModel(ggufModel)
            return await remoteSnapshot()
        }

        if let localModel = resolveLocalMLXModel(request.model) {
            await appState.loadLocalModel(localModel)
            return await remoteSnapshot()
        }

        let model = try resolveModel(request.model)
        let isDownloaded = await appState.modelManager.isDownloaded(model)

        if !isDownloaded {
            guard request.downloadIfNeeded == true else {
                throw RemoteControlError.modelNotDownloaded(request.model)
            }
            try await downloadModel(model)
        }

        try await loadModel(model)
        return await remoteSnapshot()
    }

    func remoteDownloadModel(_ request: RemoteModelControlRequest) async throws -> RemoteAppSnapshot {
        let model = try resolveModel(request.model)
        try await downloadModel(model)
        return await remoteSnapshot()
    }

    func remoteUnloadModel() async -> RemoteAppSnapshot {
        await appState.unloadModel()
        return await remoteSnapshot()
    }

    func remoteUpdateSettings(_ update: RemoteSettingsUpdate) async throws -> RemoteAppSnapshot {
        if let maxStorageGB = update.maxStorageGB {
            guard (5...200).contains(maxStorageGB) else {
                throw RemoteControlError.invalidSetting("max_storage_gb must be between 5 and 200")
            }
            appState.maxStorageGB = maxStorageGB
        }

        if let wanRelayURL = update.wanRelayURL {
            guard URL(string: wanRelayURL) != nil else {
                throw RemoteControlError.invalidSetting("wan_relay_url must be a valid URL")
            }
            appState.wanRelayURL = wanRelayURL
        }

        if let orgCapacityReservation = update.orgCapacityReservation {
            guard (0...1).contains(orgCapacityReservation) else {
                throw RemoteControlError.invalidSetting("org_capacity_reservation must be between 0 and 1")
            }
            appState.clusterManager.orgCapacityReservation = orgCapacityReservation
        }

        if let clusterPasscode = update.clusterPasscode {
            appState.clusterManager.passcode = clusterPasscode.isEmpty ? nil : clusterPasscode
        }

        if let clusterEnabled = update.clusterEnabled {
            appState.clusterEnabled = clusterEnabled
        }

        if let wanEnabled = update.wanEnabled {
            appState.wanEnabled = wanEnabled
        }

        if let allowNetworkAccess = update.allowNetworkAccess {
            appState.allowNetworkAccess = allowNetworkAccess
        }

        if let cost = update.electricityCostPerKWh {
            guard cost >= 0 else {
                throw RemoteControlError.invalidSetting("electricity_cost must be >= 0")
            }
            appState.electricityCostPerKWh = cost
        }

        if let currency = update.electricityCurrency {
            appState.electricityCurrency = currency
        }

        if let margin = update.electricityMarginMultiplier {
            guard margin >= 0 else {
                throw RemoteControlError.invalidSetting("electricity_margin must be >= 0")
            }
            appState.electricityMarginMultiplier = margin
        }

        if let keepAwake = update.keepAwake {
            appState.keepAwake = keepAwake
        }

        if let autoManage = update.autoManageModels {
            appState.autoManageModels = autoManage
        }

        if let backend = update.inferenceBackend {
            guard let value = InferenceBackend(rawValue: backend) else {
                let valid = InferenceBackend.allCases.map(\.rawValue).joined(separator: ", ")
                throw RemoteControlError.invalidSetting("inference_backend must be one of: \(valid)")
            }
            appState.inferenceBackend = value
        }

        if let alias = update.rapidMLXModelAlias {
            appState.rapidMLXModelAlias = alias
        }
        if let manage = update.rapidMLXManageSubprocess {
            appState.rapidMLXManageSubprocess = manage
        }
        if let binary = update.rapidMLXBinaryPath {
            appState.rapidMLXBinaryPath = binary
        }
        if let port = update.rapidMLXPort {
            appState.rapidMLXPort = port
        }

        if let privacyFilterMode = update.privacyFilterMode {
            guard let value = PrivacyFilterMode(rawValue: privacyFilterMode) else {
                let valid = PrivacyFilterMode.allCases.map(\.rawValue).joined(separator: ", ")
                throw RemoteControlError.invalidSetting("privacy_filter_mode must be one of: \(valid)")
            }
            appState.privacyFilterMode = value
        }

        if let lang = update.language {
            guard let value = AppLanguage(rawValue: lang) else {
                let valid = AppLanguage.allCases.map(\.rawValue).joined(separator: ", ")
                throw RemoteControlError.invalidSetting("language must be one of: \(valid)")
            }
            appState.language = value
        }

        return await remoteSnapshot()
    }

    private func resolveModel(_ value: String) throws -> ModelDescriptor {
        if let model = appState.modelManager.compatibleModels.first(where: {
            $0.matchesIdentifier(value)
        }) {
            return model
        }
        throw RemoteControlError.modelNotFound(value)
    }

    private func resolveGGUFModel(_ value: String) -> GGUFModelInfo? {
        appState.scanLocalModels()
        return appState.scannedGGUFModels.first(where: {
            $0.filename == value
            || "gguf-\($0.filename)" == value
            || $0.path.path == value
            || $0.path.lastPathComponent == value
        })
    }

    private func resolveLocalMLXModel(_ value: String) -> LocalModelInfo? {
        appState.scanLocalModels()
        return appState.scannedLocalModels.first(where: { localModel in
            let descriptor = localModel.toDescriptor()
            return descriptor.id == value
                || descriptor.huggingFaceRepo == value
                || localModel.path.path == value
                || localModel.path.lastPathComponent == value
                || localModel.name == value
        })
    }

    private func downloadModel(_ descriptor: ModelDescriptor) async throws {
        appState.activeDownloads[descriptor.id] = 0
        do {
            try await appState.modelManager.downloadModel(descriptor)
            appState.activeDownloads.removeValue(forKey: descriptor.id)
            appState.downloadedModelIDs.insert(descriptor.id)
        } catch {
            appState.activeDownloads.removeValue(forKey: descriptor.id)
            throw error
        }
    }

    private func loadModel(_ descriptor: ModelDescriptor) async throws {
        await appState.loadModel(descriptor)

        switch appState.engineStatus {
        case .ready(let loaded) where loaded.id == descriptor.id:
            return
        case .error(let message):
            throw RemoteControlError.invalidSetting(message)
        default:
            let loadedID = await appState.engine.loadedModel?.id
            if loadedID == descriptor.id { return }
            throw RemoteControlError.invalidSetting("Model '\(descriptor.id)' did not finish loading")
        }
    }

    // MARK: - PTN

    func remoteListPTNs() async -> [RemotePTNSnapshot] {
        appState.ptnManager.memberships.map { m in
            RemotePTNSnapshot(
                ptnID: m.ptnID,
                ptnName: m.ptnName,
                role: m.role.rawValue,
                isCreator: m.isCreator
            )
        }
    }

    func remoteCreatePTN(name: String) async throws -> RemotePTNSnapshot {
        let membership = try await appState.ptnManager.createPTN(name: name)
        return RemotePTNSnapshot(
            ptnID: membership.ptnID,
            ptnName: membership.ptnName,
            role: membership.role.rawValue,
            isCreator: membership.isCreator
        )
    }

    func remoteGeneratePTNInvite(ptnID: String) async throws -> String {
        try appState.ptnManager.generateInviteToken(ptnID: ptnID)
    }

    func remoteIssuePTNCert(ptnID: String, nodeID: String, role: String) async throws -> Data {
        let joinRequest = PTNJoinRequestPayload(
            inviteToken: PTNInviteToken(ptnID: ptnID, ptnName: "", inviterNodeID: "", validForSeconds: 3600),
            joinerNodeID: nodeID,
            joinerDisplayName: "remote"
        )
        // Override the invite token's ptnID to match
        var request = joinRequest
        request.inviteToken = PTNInviteToken(
            ptnID: ptnID,
            ptnName: appState.ptnManager.memberships.first(where: { $0.ptnID == ptnID })?.ptnName ?? "",
            inviterNodeID: appState.ptnManager.localNodeID,
            validForSeconds: 3600
        )
        let response = try await appState.ptnManager.handleJoinRequest(request)
        return try JSONEncoder().encode(response)
    }

    func remoteJoinPTNWithCert(certData: Data) async throws -> RemotePTNSnapshot {
        let response = try JSONDecoder().decode(PTNJoinResponsePayload.self, from: certData)
        let membership = try await appState.ptnManager.completeJoin(response: response)
        return RemotePTNSnapshot(
            ptnID: membership.ptnID,
            ptnName: membership.ptnName,
            role: membership.role.rawValue,
            isCreator: membership.isCreator
        )
    }

    func remoteLeavePTN(ptnID: String) async throws {
        try await appState.ptnManager.leavePTN(ptnID: ptnID)
    }

    func remotePromoteAdmin(ptnID: String, targetNodeID: String) async throws -> Data {
        let (certData, caKeyData) = try await appState.ptnManager.promoteToAdmin(ptnID: ptnID, targetNodeID: targetNodeID)
        // Return both the cert JSON and the CA key hex so the target can import both
        struct PromoteResponse: Encodable {
            var cert_json: String  // base64-encoded cert JSON
            var ca_key_hex: String
        }
        let response = PromoteResponse(
            cert_json: certData.base64EncodedString(),
            ca_key_hex: caKeyData.map { String(format: "%02x", $0) }.joined()
        )
        return try JSONEncoder().encode(response)
    }

    func remoteImportCAKey(ptnID: String, caKeyHex: String) async throws -> RemotePTNSnapshot {
        guard let keyData = Data(hexString: caKeyHex) else {
            throw RemoteControlError.invalidSetting("Invalid hex-encoded CA key")
        }
        try await appState.ptnManager.importCAKey(keyData, ptnID: ptnID)
        guard let membership = appState.ptnManager.memberships.first(where: { $0.ptnID == ptnID }) else {
            throw RemoteControlError.invalidSetting("PTN not found after import")
        }
        return RemotePTNSnapshot(
            ptnID: membership.ptnID,
            ptnName: membership.ptnName,
            role: membership.role.rawValue,
            isCreator: membership.isCreator
        )
    }

    func remoteRecoverPTN(oldPTNID: String) async throws -> RemotePTNSnapshot {
        let (newMembership, _) = try await appState.ptnManager.recoverPTN(oldPTNID: oldPTNID)
        return RemotePTNSnapshot(
            ptnID: newMembership.ptnID,
            ptnName: newMembership.ptnName,
            role: newMembership.role.rawValue,
            isCreator: newMembership.isCreator
        )
    }

    // MARK: - API Keys

    func remoteListAPIKeys() async -> [RemoteAPIKeySnapshot] {
        let keys = await appState.apiKeyStore.allKeys()
        return keys.map { k in
            RemoteAPIKeySnapshot(
                id: k.id,
                key: k.truncatedKey,
                name: k.name,
                createdAt: k.createdAt,
                lastUsedAt: k.lastUsedAt,
                isActive: k.isActive
            )
        }
    }

    func remoteGenerateAPIKey(name: String) async -> RemoteAPIKeySnapshot {
        let k = await appState.apiKeyStore.generateKey(name: name)
        return RemoteAPIKeySnapshot(
            id: k.id,
            key: k.key,
            name: k.name,
            createdAt: k.createdAt,
            lastUsedAt: k.lastUsedAt,
            isActive: k.isActive
        )
    }

    func remoteRevokeAPIKey(id: UUID) async {
        await appState.apiKeyStore.revokeKey(id: id)
    }

    // MARK: - Wallet

    func remoteWalletBalance() async -> RemoteWalletSnapshot {
        let deviceID = GatewayIdentity.shared.deviceID
        let wanNodeID = try? AppState.canonicalWANIdentity().nodeID
        let relayConnected = appState.wanEnabled && appState.wanManager.state.relayStatus == .connected
        let localServingReady = appState.engineStatus.isReady || appState.engineStatus.isGenerating
        let identityMismatch = wanNodeID != nil && wanNodeID != deviceID

        do {
            let balance = try await gatewayWalletBalance()
            return RemoteWalletSnapshot(
                deviceID: balance.deviceID,
                balance: creditsToUSDC(balance.balanceCredits),
                totalEarned: creditsToUSDC(balance.totalEarnedCredits),
                totalSpent: creditsToUSDC(balance.totalSpentCredits),
                wanNodeID: wanNodeID,
                relayConnected: relayConnected,
                localServingReady: localServingReady,
                identityMismatch: identityMismatch,
                earningEligible: relayConnected && localServingReady && !identityMismatch
            )
        } catch {
            return RemoteWalletSnapshot(
                deviceID: deviceID,
                balance: 0,
                totalEarned: 0,
                totalSpent: 0,
                wanNodeID: wanNodeID,
                relayConnected: relayConnected,
                localServingReady: localServingReady,
                identityMismatch: identityMismatch,
                earningEligible: false,
                error: error.localizedDescription
            )
        }
    }

    func remoteWalletTransactions(limit: Int) async -> [RemoteTransactionSnapshot] {
        do {
            return try await gatewayWalletTransactions(limit: limit).map { tx in
                RemoteTransactionSnapshot(
                    id: gatewayTransactionUUID(tx.id),
                    type: tx.type.lowercased(),
                    amount: creditsToUSDC(tx.amount),
                    description: gatewayTransactionDescription(tx),
                    timestamp: Date(timeIntervalSince1970: TimeInterval(tx.timestamp))
                )
            }
        } catch {
            return []
        }
    }

    func remoteWalletSend(amount: Double, toPeer peerNodeID: String, memo: String?) async throws -> Bool {
        guard let peerUUID = UUID(uuidString: peerNodeID) else {
            throw RemoteControlError.invalidSetting("Invalid peer UUID: \(peerNodeID)")
        }
        return await appState.sendCredits(amount: amount, to: peerUUID, memo: memo)
    }

    func remoteSolanaStatus() async -> RemoteSolanaSnapshot {
        guard let bridge = appState.walletBridge else {
            return RemoteSolanaSnapshot(enabled: appState.solanaWalletEnabled, network: appState.solanaNetwork)
        }
        return RemoteSolanaSnapshot(
            enabled: appState.solanaWalletEnabled,
            address: bridge.solanaAddress,
            usdcBalance: bridge.usdcBalanceFormatted,
            network: appState.solanaNetwork
        )
    }

    // MARK: - Peers

    func remoteListPeers() async -> RemotePeersSnapshot {
        let wanPeers = appState.wanManager.state.connectedPeers.map { peer in
            RemotePeerSnapshot(
                nodeID: peer.id,
                displayName: peer.displayName,
                loadedModels: peer.loadedModels,
                source: "wan"
            )
        }

        let wanDiscoveredPeers = appState.wanManager.state.discoveredPeers.map { peer in
            RemotePeerSnapshot(
                nodeID: peer.id,
                displayName: peer.displayName,
                loadedModels: peer.capabilities.loadedModels,
                source: "wan_discovered"
            )
        }

        let clusterPeers = await appState.clusterManager.topology.connectedPeers.map { peer in
            RemotePeerSnapshot(
                nodeID: peer.id.uuidString,
                displayName: peer.deviceInfo.name,
                loadedModels: peer.loadedModels,
                source: "cluster"
            )
        }

        return RemotePeersSnapshot(
            wanPeers: wanPeers,
            wanDiscoveredPeers: wanDiscoveredPeers,
            clusterPeers: clusterPeers
        )
    }

    // MARK: - Agent

    func remoteAgentProfile() async -> RemoteAgentProfileSnapshot? {
        guard let profile = appState.agentProfile else { return nil }
        return RemoteAgentProfileSnapshot(
            nodeID: profile.nodeID,
            displayName: profile.displayName,
            agentType: profile.agentType.rawValue,
            bio: profile.bio,
            capabilities: profile.capabilities.map(\.name)
        )
    }

    func remoteAgentDirectory() async -> [RemoteAgentDirectoryEntry] {
        let entries = await appState.agentManager.directory.allEntries()
        return entries.map { entry in
            RemoteAgentDirectoryEntry(
                nodeID: entry.profile.nodeID,
                displayName: entry.profile.displayName,
                agentType: entry.profile.agentType.rawValue,
                bio: entry.profile.bio,
                capabilities: entry.profile.capabilities.map(\.name),
                isOnline: entry.isOnline,
                rating: entry.rating
            )
        }
    }

    func remoteAgentConversations() async -> [RemoteAgentConversationSnapshot] {
        let conversations = await appState.agentManager.conversationStore.listConversations()
        return conversations.map { conv in
            let lastMsg: String? = conv.messages.last.map { msg in
                switch msg.type {
                case .intent(let p): return "intent: \(p.description)"
                case .offer(let p): return "offer: \(p.description)"
                case .counterOffer(let p): return "counter: \(p.description)"
                case .accept: return "accepted"
                case .reject(let p): return "rejected: \(p.reason)"
                case .complete(let p): return "complete: \(p.outcome)"
                case .review(let p): return "review: \(p.rating)/5"
                case .chat(let p): return p.content
                case .capability: return "capability exchange"
                case .status(let p): return "status: \(p.message ?? "")"
                }
            }
            return RemoteAgentConversationSnapshot(
                id: conv.id,
                participants: conv.participants,
                state: conv.state.rawValue,
                messageCount: conv.messages.count,
                lastMessage: lastMsg,
                updatedAt: conv.updatedAt
            )
        }
    }

    private func gatewayWalletBalance() async throws -> GatewayWalletBalanceSnapshot {
        let client = GatewayAuthClient(baseURL: gatewayRootURL())
        let token = try await client.bearer()
        return try await client.getJSON(path: "/v1/wallet/balance", bearerToken: token)
    }

    private func gatewayWalletTransactions(limit: Int) async throws -> [GatewayWalletTransactionSnapshot] {
        let client = GatewayAuthClient(baseURL: gatewayRootURL())
        let token = try await client.bearer()
        var components = URLComponents(
            url: gatewayRootURL().appendingPathComponent("/v1/wallet/transactions"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [
            URLQueryItem(name: "limit", value: String(max(1, min(limit, 500)))),
            URLQueryItem(name: "include_availability", value: "true"),
        ]
        guard let url = components?.url else {
            throw GatewayAuthError.network("invalid wallet transactions url")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await client.urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw GatewayAuthError.network("non-http response")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw GatewayAuthError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }

        return try JSONDecoder().decode(GatewayWalletTransactionsEnvelope.self, from: data).transactions
    }

    private func creditsToUSDC(_ credits: Int64) -> Double {
        Double(credits) / 1_000_000.0
    }

    private func gatewayTransactionUUID(_ id: Int64) -> UUID {
        let lowBits = UInt64(bitPattern: id) & 0xFFFFFFFFFFFF
        let suffix = String(format: "%012llx", lowBits)
        return UUID(uuidString: "00000000-0000-0000-0000-\(suffix)") ?? UUID()
    }

    private func gatewayTransactionDescription(_ tx: GatewayWalletTransactionSnapshot) -> String {
        let typeLabel = tx.type
            .lowercased()
            .split(separator: "_")
            .map { $0.capitalized }
            .joined(separator: " ")
        if let note = tx.note, !note.isEmpty {
            return "\(typeLabel): \(note)"
        }
        return typeLabel
    }

    private func appVersion() -> String {
        BuildVersion.display
    }
}

extension RemoteControlBridge: DesktopCompanionControlling {
    func desktop_snapshot() async throws -> DesktopCompanionAppSnapshot {
        await refreshDesktopWalletSnapshotIfNeeded(force: false)

        let loadedModel = await appState.engine.loadedModel
        let privacyStatus = await DesktopPrivacyFilter.shared.status(for: appState.privacyFilterMode)
        let compatibleModels = appState.modelManager.compatibleModels
        let downloaded = appState.downloadedModelIDs
        let downloading = appState.activeDownloads
        let recommendedID = desktopRecommendedModelID(from: compatibleModels)
        let currentModelID = loadedModel?.openrouterId ?? loadedModel?.id
        let serviceState = desktopServiceState(currentModelID: currentModelID, downloading: downloading)

        if appState.gatewayAPIKey.isEmpty {
            _ = try? await desktopGatewayBearer(forceRefresh: false)
        }

        let models = compatibleModels.map { model in
            DesktopCompanionModelSnapshot(
                id: model.openrouterId ?? model.id,
                display_name: model.name,
                required_ram_gb: model.requiredRAMGB,
                size_gb: model.estimatedSizeGB,
                demand_rank: UInt32(max(0, model.popularityRank)),
                recommended: (model.openrouterId ?? model.id) == recommendedID,
                downloaded: downloaded.contains(model.id),
                loaded: loadedModel?.id == model.id,
                download_progress: downloading[model.id],
                last_error: nil
            )
        }

        return DesktopCompanionAppSnapshot(
            app_version: appVersion(),
            service_state: serviceState,
            state_reason: desktopStateReason(for: serviceState, currentModelID: currentModelID),
            device: DesktopCompanionDeviceSnapshot(
                display_name: ProcessInfo.processInfo.hostName,
                hardware: appState.hardware,
                gpu_backend: appState.hardware.gpuBackend?.rawValue,
                on_ac: appState.throttler.powerMonitor.powerState.isOnACPower
            ),
            auth: authSnapshot(),
            demand: demandSnapshot(loadedModel: loadedModel),
            privacy_filter: DesktopCompanionPrivacyFilterSnapshot(
                mode: appState.privacyFilterMode.rawValue,
                helper_status: privacyStatus.state.rawValue,
                helper_detail: privacyStatus.detail
            ),
            wallet: desktopWalletSnapshot(service_state: serviceState),
            wallet_transactions: desktopWalletTransactions.map { tx in
                DesktopCompanionWalletTransactionSnapshot(
                    id: tx.id,
                    device_id: desktopGatewayWallet?.deviceID ?? GatewayIdentity.shared.deviceID,
                    type: tx.type,
                    amount: tx.amount,
                    timestamp: tx.timestamp,
                    refRequestID: nil,
                    note: tx.note
                )
            },
            loaded_model_id: loadedModel?.openrouterId ?? loadedModel?.id,
            models: models,
            active_transfer: desktopActiveTransferSnapshot()
        )
    }

    func desktop_set_privacy_filter_mode(_ mode: PrivacyFilterMode) async throws -> DesktopCompanionAppSnapshot {
        appState.privacyFilterMode = mode
        return try await desktop_snapshot()
    }

    func desktop_auth_session(access_token: String) async throws -> DesktopCompanionAuthSessionSnapshot {
        guard let config = SupabaseConfig.default else {
            throw GatewayAuthError.network("supabase auth is not configured")
        }

        let user = try await desktopSupabaseUserLookup(
            config: config,
            accessToken: access_token
        )
        let devices = try await desktopSupabaseDevicesLookup(
            config: config,
            accessToken: access_token,
            userID: user.id
        )

        return DesktopCompanionAuthSessionSnapshot(
            user: DesktopCompanionAuthUserSnapshot(
                id: user.id,
                phone: user.phone,
                email: user.email,
                app_metadata: nil,
                user_metadata: nil,
                identities: user.identities.map {
                    DesktopCompanionAuthIdentitySnapshot(
                        id: $0.id,
                        provider: $0.provider,
                        identity_data: $0.identity_data,
                        email: $0.email
                    )
                }
            ),
            identities: user.identities.map {
                DesktopCompanionAuthIdentitySnapshot(
                    id: $0.id,
                    provider: $0.provider,
                    identity_data: $0.identity_data,
                    email: $0.email
                )
            },
            devices: devices
        )
    }

    func desktop_network_models() async throws -> [DesktopCompanionNetworkModelSnapshot] {
        let response: DesktopGatewayModelsResponse = try await desktopGatewayJSON(
            method: "GET",
            path: "/v1/models",
            requiresAuth: false
        )
        return response.data.map { model in
            DesktopCompanionNetworkModelSnapshot(
                id: model.id,
                context_length: model.context_length,
                device_count: model.loaded_device_count ?? 0,
                ttft_ms_p50: model.metrics?.ttft_ms_p50,
                tps_p50: model.metrics?.tps_p50,
                pricing_prompt: model.pricing?.prompt,
                pricing_completion: model.pricing?.completion
            )
        }
    }

    func desktop_network_stats() async throws -> DesktopCompanionNetworkStatsSnapshot {
        try await desktopGatewayJSON(
            method: "GET",
            path: "/v1/network/stats",
            requiresAuth: false
        )
    }

    func desktop_account_summary() async throws -> DesktopCompanionAccountSnapshot {
        try await desktopGatewayJSON(method: "GET", path: "/v1/account/summary")
    }

    func desktop_account_api_keys() async throws -> DesktopCompanionAccountAPIKeysResponse {
        try await desktopGatewayJSON(method: "GET", path: "/v1/account/api-keys")
    }

    func desktop_link_account(_ request: DesktopCompanionAccountLinkRequest) async throws -> DesktopCompanionAccountSnapshot {
        try await desktopGatewayJSON(method: "POST", path: "/v1/account/link", body: request)
    }

    func desktop_create_account_api_key(label: String?) async throws -> DesktopCompanionAccountAPIKeyMintedResponse {
        struct Payload: Encodable { let label: String? }
        return try await desktopGatewayJSON(
            method: "POST",
            path: "/v1/account/api-keys",
            body: Payload(label: label?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty)
        )
    }

    func desktop_revoke_account_api_key(key_id: String) async throws -> DesktopCompanionAccountAPIKeyRevokeResponse {
        try await desktopGatewayJSON(
            method: "DELETE",
            path: "/v1/account/api-keys/\(key_id)"
        )
    }

    func desktop_sweep_account_device(device_id: String) async throws -> DesktopCompanionAccountSweepResponse {
        struct Payload: Encodable { let deviceID: String }
        let response: DesktopCompanionAccountSweepResponse = try await desktopGatewayJSON(
            method: "POST",
            path: "/v1/account/sweep",
            body: Payload(deviceID: device_id)
        )
        await refreshDesktopWalletSnapshotIfNeeded(force: true)
        return response
    }

    func desktop_remove_account_device(device_id: String) async throws -> DesktopCompanionAccountSnapshot {
        struct Payload: Encodable { let deviceID: String }
        return try await desktopGatewayJSON(
            method: "POST",
            path: "/v1/account/devices/remove",
            body: Payload(deviceID: device_id)
        )
    }

    func desktop_send_account_wallet(_ request: DesktopCompanionWalletSendRequest) async throws -> DesktopCompanionAccountSnapshot {
        let _: EmptyGatewayResponse = try await desktopGatewayJSON(
            method: "POST",
            path: "/v1/account/send",
            body: request
        )
        await refreshDesktopWalletSnapshotIfNeeded(force: true)
        return try await desktop_account_summary()
    }

    func desktop_refresh_wallet() async throws -> DesktopCompanionAppSnapshot {
        await refreshDesktopWalletSnapshotIfNeeded(force: true)
        return try await desktop_snapshot()
    }

    func desktop_send_device_wallet(_ request: DesktopCompanionWalletSendRequest) async throws -> DesktopCompanionAppSnapshot {
        let _: EmptyGatewayResponse = try await desktopGatewayJSON(
            method: "POST",
            path: "/v1/wallet/send",
            body: request
        )
        await refreshDesktopWalletSnapshotIfNeeded(force: true)
        return try await desktop_snapshot()
    }

    private func desktopServiceState(
        currentModelID: String?,
        downloading: [String: Double]
    ) -> String {
        if case .error = appState.engineStatus {
            return "error"
        }
        if !appState.isServerRunning {
            return "starting"
        }
        if !appState.contributeCompute {
            return "paused_user"
        }
        if !downloading.isEmpty {
            return "downloading"
        }
        if case .loadingModel = appState.engineStatus {
            return "loading"
        }
        if currentModelID != nil {
            return "serving"
        }
        return "needs_model"
    }

    private func desktopStateReason(for serviceState: String, currentModelID: String?) -> String? {
        switch serviceState {
        case "starting":
            return "Starting the local Teale service."
        case "paused_user":
            return "Supply is paused for this Mac."
        case "downloading":
            return "Downloading the selected model."
        case "loading":
            return "Loading the selected model."
        case "needs_model":
            return currentModelID == nil ? "Choose a model to start serving." : nil
        case "error":
            if case .error(let message) = appState.engineStatus {
                return message
            }
            return "The local runtime reported an error."
        default:
            return "Teale is ready locally."
        }
    }

    private func desktopRecommendedModelID(from models: [ModelDescriptor]) -> String? {
        models
            .sorted {
                if $0.requiredRAMGB == $1.requiredRAMGB {
                    return $0.popularityRank < $1.popularityRank
                }
                return $0.requiredRAMGB > $1.requiredRAMGB
            }
            .first?.openrouterId ?? models.first?.id
    }

    private func desktopWalletSnapshot(service_state: String) -> DesktopCompanionWalletSnapshot {
        let balance = desktopGatewayWallet
        let availabilityCreditsPerTick: Int64 = service_state == "serving" ? 250 : 0
        return DesktopCompanionWalletSnapshot(
            current_device_id: balance?.deviceID ?? GatewayIdentity.shared.deviceID,
            estimated_session_credits: Int64(appState.totalTokensGenerated),
            credits_today: 0,
            completed_requests: UInt64(appState.totalRequestsServed),
            availability_credits_per_tick: availabilityCreditsPerTick,
            availability_tick_seconds: 10,
            availability_rate_credits_per_minute: availabilityCreditsPerTick > 0 ? availabilityCreditsPerTick * 6 : 0,
            supplying_since: nil,
            gateway_balance_credits: balance?.balanceCredits,
            gateway_total_earned_credits: balance?.totalEarnedCredits,
            gateway_total_spent_credits: balance?.totalSpentCredits,
            gateway_usdc_cents: balance?.usdcCents,
            gateway_synced_at: desktopWalletSyncedAt,
            gateway_sync_error: desktopWalletSyncError
        )
    }

    private func desktopActiveTransferSnapshot() -> DesktopCompanionTransferSnapshot? {
        guard let (modelID, progress) = appState.activeDownloads.first else { return nil }
        let model = appState.modelManager.compatibleModels.first(where: { $0.id == modelID })
        let totalBytes = model.map { UInt64(max(0, $0.estimatedSizeGB) * 1024 * 1024 * 1024) }
        let downloadedBytes = totalBytes.map { UInt64(Double($0) * min(max(progress, 0), 1)) } ?? 0
        return DesktopCompanionTransferSnapshot(
            model_id: model?.openrouterId ?? modelID,
            phase: "downloading",
            bytes_downloaded: downloadedBytes,
            bytes_total: totalBytes,
            bytes_per_sec: nil,
            eta_seconds: nil
        )
    }

    private func refreshDesktopWalletSnapshotIfNeeded(force: Bool) async {
        if !force,
           let lastRefresh = desktopLastWalletRefreshAt,
           Date().timeIntervalSince(lastRefresh) < 15 {
            return
        }

        desktopLastWalletRefreshAt = Date()
        do {
            let balance = try await gatewayWalletBalance()
            let transactions = try await gatewayWalletTransactions(limit: 25)
            desktopGatewayWallet = balance
            desktopWalletTransactions = transactions
            desktopWalletSyncedAt = UInt64(Date().timeIntervalSince1970)
            desktopWalletSyncError = nil
        } catch {
            desktopWalletSyncError = error.localizedDescription
            if desktopGatewayWallet == nil {
                desktopWalletTransactions = []
            }
        }
    }

    private func desktopGatewayBearer(forceRefresh: Bool) async throws -> String {
        let client = GatewayAuthClient(baseURL: gatewayRootURL())
        if !forceRefresh, !appState.gatewayAPIKey.isEmpty {
            return appState.gatewayAPIKey
        }
        let token = forceRefresh ? try await client.exchange() : try await client.bearer()
        appState.gatewayAPIKey = token
        return token
    }

    private func desktopGatewayJSON<Response: Decodable>(
        method: String,
        path: String,
        requiresAuth: Bool = true
    ) async throws -> Response {
        try await desktopGatewayJSON(
            method: method,
            path: path,
            requiresAuth: requiresAuth,
            bodyData: nil
        )
    }

    private func desktopGatewayJSON<Request: Encodable, Response: Decodable>(
        method: String,
        path: String,
        body: Request
    ) async throws -> Response {
        try await desktopGatewayJSON(
            method: method,
            path: path,
            requiresAuth: true,
            bodyData: try JSONEncoder().encode(body)
        )
    }

    private func desktopGatewayJSON<Response: Decodable>(
        method: String,
        path: String,
        requiresAuth: Bool,
        bodyData: Data?
    ) async throws -> Response {
        let client = GatewayAuthClient(baseURL: gatewayRootURL())

        func perform(with token: String?) async throws -> Response {
            var request = URLRequest(url: gatewayRootURL().appending(path: path))
            request.httpMethod = method
            if let token {
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            }
            if let bodyData {
                request.httpBody = bodyData
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            }
            let (data, response) = try await client.urlSession.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw GatewayAuthError.network("non-http response")
            }
            guard (200..<300).contains(http.statusCode) else {
                throw GatewayAuthError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
            }
            if Response.self == EmptyGatewayResponse.self {
                return EmptyGatewayResponse() as! Response
            }
            return try JSONDecoder().decode(Response.self, from: data)
        }

        let token = requiresAuth ? try await desktopGatewayBearer(forceRefresh: false) : nil
        do {
            return try await perform(with: token)
        } catch let GatewayAuthError.http(code, _) where requiresAuth && code == 401 {
            let refreshed = try await desktopGatewayBearer(forceRefresh: true)
            return try await perform(with: refreshed)
        }
    }

    private func desktopSupabaseUserLookup(
        config: SupabaseConfig,
        accessToken: String
    ) async throws -> DesktopSupabaseUserLookupResponse {
        var request = URLRequest(url: config.url.appending(path: "auth/v1/user"))
        request.httpMethod = "GET"
        request.setValue(config.anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw GatewayAuthError.network("non-http supabase response")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw GatewayAuthError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        return try JSONDecoder().decode(DesktopSupabaseUserLookupResponse.self, from: data)
    }

    private func desktopSupabaseDevicesLookup(
        config: SupabaseConfig,
        accessToken: String,
        userID: String
    ) async throws -> [DesktopCompanionSupabaseDeviceSnapshot] {
        var components = URLComponents(url: config.url.appending(path: "rest/v1/devices"), resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(
                name: "select",
                value: "id,user_id,device_name,platform,chip_name,ram_gb,wan_node_id,registered_at,last_seen,is_active"
            ),
            URLQueryItem(name: "user_id", value: "eq.\(userID)"),
            URLQueryItem(name: "order", value: "last_seen.desc"),
        ]
        guard let url = components?.url else {
            throw GatewayAuthError.network("invalid supabase devices url")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(config.anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw GatewayAuthError.network("non-http supabase devices response")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw GatewayAuthError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        return try JSONDecoder().decode([DesktopCompanionSupabaseDeviceSnapshot].self, from: data)
    }
}

private struct EmptyGatewayResponse: Decodable {}

private struct DesktopGatewayModelsResponse: Decodable {
    let data: [DesktopGatewayModelEntry]
}

private struct DesktopGatewayModelEntry: Decodable {
    let id: String
    let context_length: UInt32?
    let loaded_device_count: UInt32?
    let pricing: DesktopGatewayPricing?
    let metrics: DesktopGatewayMetrics?
}

private struct DesktopGatewayPricing: Decodable {
    let prompt: String
    let completion: String
}

private struct DesktopGatewayMetrics: Decodable {
    let ttft_ms_p50: UInt32?
    let tps_p50: Float?
}

private struct DesktopSupabaseUserLookupResponse: Decodable {
    let id: String
    let phone: String?
    let email: String?
    let identities: [DesktopSupabaseIdentity]
}

private struct DesktopSupabaseIdentity: Decodable {
    let id: String?
    let provider: String
    let identity_data: [String: String]?
    let email: String?
}

private extension String {
    var nilIfEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

private struct GatewayWalletBalanceSnapshot: Decodable {
    let deviceID: String
    let balanceCredits: Int64
    let totalEarnedCredits: Int64
    let totalSpentCredits: Int64
    let usdcCents: Int64

    enum CodingKeys: String, CodingKey {
        case deviceID
        case balanceCredits = "balance_credits"
        case totalEarnedCredits = "total_earned_credits"
        case totalSpentCredits = "total_spent_credits"
        case usdcCents = "usdc_cents"
    }
}

private struct GatewayWalletTransactionsEnvelope: Decodable {
    let transactions: [GatewayWalletTransactionSnapshot]
}

private struct GatewayWalletTransactionSnapshot: Decodable {
    let id: Int64
    let type: String
    let amount: Int64
    let timestamp: Int64
    let note: String?
}
