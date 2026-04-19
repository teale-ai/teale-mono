import Foundation
import SharedTypes
import LocalAPI
import LlamaCppKit
import TealeNetKit
import AgentKit

@MainActor
final class RemoteControlBridge: @unchecked Sendable, LocalAppControlling {
    private unowned let appState: AppState

    init(appState: AppState) {
        self.appState = appState
    }

    func remoteSnapshot() async -> RemoteAppSnapshot {
        await appState.refreshDownloadedModels()

        let loadedModel = await appState.engine.loadedModel
        let compatibleModels = appState.modelManager.compatibleModels
        let downloaded = appState.downloadedModelIDs
        let downloading = appState.modelManager.downloadingModels

        let models = compatibleModels.map { model in
            RemoteModelSnapshot(
                id: model.id,
                name: model.name,
                huggingFaceRepo: model.huggingFaceRepo,
                downloaded: downloaded.contains(model.id),
                loaded: loadedModel?.id == model.id,
                downloadingProgress: downloading[model.id]
            )
        }

        return RemoteAppSnapshot(
            appVersion: appVersion(),
            loadedModelID: loadedModel?.id,
            loadedModelRepo: loadedModel?.huggingFaceRepo,
            engineStatus: String(describing: appState.engineStatus),
            isServerRunning: appState.isServerRunning,
            settings: RemoteSettingsSnapshot(
                clusterEnabled: appState.clusterEnabled,
                wanEnabled: appState.wanEnabled,
                wanRelayURL: appState.wanRelayURL,
                wanBusy: appState.isWANBusy,
                wanLastError: appState.wanLastError,
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
                language: appState.language.rawValue
            ),
            models: models
        )
    }

    func remoteLoadModel(_ request: RemoteModelControlRequest) async throws -> RemoteAppSnapshot {
        // Check if this is a GGUF model request
        if let ggufModel = resolveGGUFModel(request.model) {
            await appState.loadGGUFModel(ggufModel)
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
        if let model = appState.modelManager.compatibleModels.first(where: { $0.id == value || $0.huggingFaceRepo == value }) {
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
        if case .ready = appState.engineStatus {
            await appState.engine.unloadModel()
        }

        appState.selectedModel = descriptor
        appState.engineStatus = .loadingModel(descriptor)
        appState.loadingPhase = "Preparing…"
        appState.loadingProgress = 0

        do {
            try await appState.engine.loadModel(descriptor) { [weak appState] progress in
                Task { @MainActor in
                    appState?.loadingPhase = progress.phase.rawValue
                    appState?.loadingProgress = progress.fractionCompleted
                }
            }

            appState.loadingPhase = ""
            appState.loadingProgress = nil
            appState.engineStatus = .ready(descriptor)
            if appState.wanEnabled {
                await appState.wanManager.updateLocalLoadedModels(descriptor.advertisedId.map { [$0] } ?? [])
            }
            await appState.refreshDownloadedModels()
        } catch {
            appState.loadingPhase = ""
            appState.loadingProgress = nil
            appState.engineStatus = .error(error.localizedDescription)
            throw error
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
        await appState.wallet.refreshBalance()
        return RemoteWalletSnapshot(
            balance: appState.wallet.balance.value,
            totalEarned: appState.wallet.totalEarned.value,
            totalSpent: appState.wallet.totalSpent.value
        )
    }

    func remoteWalletTransactions(limit: Int) async -> [RemoteTransactionSnapshot] {
        await appState.wallet.refreshBalance()
        return appState.wallet.recentTransactions.prefix(limit).map { tx in
            RemoteTransactionSnapshot(
                id: tx.id,
                type: tx.type.rawValue,
                amount: tx.amount.value,
                description: tx.description,
                peerNodeID: tx.peerNodeID,
                timestamp: tx.timestamp
            )
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

        let clusterPeers = await appState.clusterManager.topology.connectedPeers.map { peer in
            RemotePeerSnapshot(
                nodeID: peer.id.uuidString,
                displayName: peer.deviceInfo.name,
                loadedModels: peer.loadedModels,
                source: "cluster"
            )
        }

        return RemotePeersSnapshot(wanPeers: wanPeers, clusterPeers: clusterPeers)
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

    private func appVersion() -> String {
        BuildVersion.display
    }
}
