import Foundation
import IOKit
import IOKit.pwr_mgt
import SharedTypes
import HardwareProfile
import InferenceEngine
import ModelManager
import MLXInference
import LocalAPI
import ClusterKit
import WANKit
import CreditKit
import AgentKit
import AuthKit
import WalletKit

// MARK: - App State

@MainActor
@Observable
public final class AppState {
    private static let stableNodeIDKey = "teale.stable_node_id"

    // Hardware
    public let hardware: HardwareCapability
    public let throttler: AdaptiveThrottler

    // Engine
    public let engine: InferenceEngineManager

    // Local inference provider
    private let localProvider: MLXProvider

    // Models
    public let modelManager: ModelManagerService

    // Cluster (LAN)
    public let clusterManager: ClusterManager
    public var clusterEnabled: Bool = false {
        didSet { toggleCluster() }
    }

    // WAN P2P
    public let wanManager: WANManager
    public var wanEnabled: Bool = false {
        didSet { toggleWAN() }
    }

    // Credits
    public var wallet: CreditWallet

    // Solana Wallet (USDC on-chain bridge)
    public var walletBridge: WalletBridge?
    public var solanaWalletEnabled: Bool = UserDefaults.standard.bool(forKey: "teale.solanaWalletEnabled") {
        didSet {
            UserDefaults.standard.set(solanaWalletEnabled, forKey: "teale.solanaWalletEnabled")
            Task { await toggleSolanaWallet() }
        }
    }
    public var solanaNetwork: String = UserDefaults.standard.string(forKey: "teale.solanaNetwork") ?? "devnet" {
        didSet { UserDefaults.standard.set(solanaNetwork, forKey: "teale.solanaNetwork") }
    }

    // Auth
    public let authManager: AuthManager?

    // Agent
    public let agentManager: AgentManager
    public var agentProfile: AgentProfile?

    // Server & API Keys
    public var serverPort: Int = 11435
    public var isServerRunning: Bool = false
    public var allowNetworkAccess: Bool = false
    public let apiKeyStore = APIKeyStore()

    // Chat
    public let conversationStore = ConversationStore()

    // UI State
    public var selectedModel: ModelDescriptor?
    public var engineStatus: EngineStatus = .idle
    public var downloadedModelIDs: Set<String> = []
    /// Models currently being downloaded (modelID -> progress 0..1)
    public var activeDownloads: [String: Double] = [:]
    /// Models that just finished downloading — prompt user to load
    public var justDownloadedModel: ModelDescriptor?
    public var currentView: AppView = .dashboard
    public var showSignIn: Bool = false
    public var loadingPhase: String = ""
    public var loadingProgress: Double?
    public var pendingWalletTransferPeerID: UUID?

    // Settings
    public var launchAtLogin: Bool = false
    public var maxStorageGB: Double = UserDefaults.standard.object(forKey: "teale.maxStorageGB") as? Double ?? 50.0 {
        didSet { UserDefaults.standard.set(maxStorageGB, forKey: "teale.maxStorageGB") }
    }
    public var wanRelayURL: String = "wss://relay.teale.network/ws"

    /// Prevent system sleep so the node stays online for the inference pool.
    /// Display can still turn off — only system/idle sleep is inhibited.
    public var keepAwake: Bool = UserDefaults.standard.bool(forKey: "teale.keepAwake") {
        didSet {
            UserDefaults.standard.set(keepAwake, forKey: "teale.keepAwake")
            updatePowerAssertion()
        }
    }
    private var powerAssertionID: IOPMAssertionID = 0

    private func updatePowerAssertion() {
        if keepAwake {
            if powerAssertionID == 0 {
                let reason = "Teale inference node staying online for the network" as CFString
                IOPMAssertionCreateWithName(
                    kIOPMAssertPreventUserIdleSystemSleep as CFString,
                    IOPMAssertionLevel(kIOPMAssertionLevelOn),
                    reason,
                    &powerAssertionID
                )
            }
        } else {
            if powerAssertionID != 0 {
                IOPMAssertionRelease(powerAssertionID)
                powerAssertionID = 0
            }
        }
    }

    public var language: AppLanguage = AppLanguage(
        rawValue: UserDefaults.standard.string(forKey: "teale.language") ?? "en"
    ) ?? .english {
        didSet { UserDefaults.standard.set(language.rawValue, forKey: "teale.language") }
    }

    public func loc(_ key: String) -> String {
        L.string(key, language: language)
    }

    public var hasAvailableInferenceTarget: Bool {
        if case .ready = engineStatus {
            return true
        }

        guard clusterEnabled else {
            return false
        }

        return clusterManager.topology.connectedPeers.contains {
            !$0.isGenerating && $0.throttleLevel > 0 && !$0.loadedModels.isEmpty
        }
    }

    public init() {
        let detector = HardwareDetector()
        let hw = detector.detect()
        self.hardware = hw
        self.throttler = AdaptiveThrottler()

        let mlxProvider = MLXProvider()
        self.localProvider = mlxProvider
        self.engine = InferenceEngineManager(provider: mlxProvider, throttler: throttler)
        self.modelManager = ModelManagerService(hardware: hw, maxStorageGB: 50.0)

        let hostname = ProcessInfo.processInfo.hostName
        let deviceInfo = DeviceInfo(name: hostname, hardware: hw)
        self.clusterManager = ClusterManager(localDeviceInfo: deviceInfo)
        self.wanManager = WANManager()
        self.clusterManager.onInferenceRequest = { [clusterManager, mlxProvider] payload, peer in
            clusterManager.beginServingInference()
            defer { clusterManager.endServingInference() }

            do {
                let stream = mlxProvider.generate(request: payload.request)
                for try await chunk in stream {
                    let response = InferenceChunkPayload(requestID: payload.requestID, chunk: chunk)
                    try await peer.connection.send(.inferenceChunk(response))
                }

                let complete = InferenceCompletePayload(requestID: payload.requestID)
                try await peer.connection.send(.inferenceComplete(complete))
            } catch {
                let response = InferenceErrorPayload(
                    requestID: payload.requestID,
                    errorMessage: error.localizedDescription
                )
                try? await peer.connection.send(.inferenceError(response))
            }
        }
        if let config = SupabaseConfig.default {
            self.authManager = AuthManager(config: config)
        } else {
            self.authManager = nil
        }
        self.agentManager = AgentManager()

        // Wallet placeholder — replaced async on launch
        self.wallet = CreditWallet.placeholder()
    }

    /// Call once at app launch to initialize async components (auth, credit ledger, agent)
    public func initializeAsync() async {
        // Restore power assertion if keep-awake was enabled
        if keepAwake { updatePowerAssertion() }

        // Scan which models are already downloaded
        await refreshDownloadedModels()
        let nodeID = Self.stableNodeID()

        // Check auth session (skip if Supabase not configured)
        if let authManager {
            authManager.deviceHardware = (chipName: hardware.chipName, ramGB: Int(hardware.totalRAMGB))
            authManager.wanNodeID = nodeID
            await authManager.checkSession()
            clusterManager.updateAuthenticatedUserID(authManager.currentUser?.id)
        }

        // Initialize credit wallet
        let ledger = await CreditLedger()
        await ledger.applyWelcomeBonusIfNeeded()
        let realWallet = CreditWallet(ledger: ledger)
        await realWallet.refreshBalance()
        self.wallet = realWallet

        // Initialize agent profile with a stable local node ID.
        // WANNodeIdentity is created lazily when WAN is actually enabled.
        let hostname = ProcessInfo.processInfo.hostName

        let profile = AgentProfile(
            nodeID: nodeID,
            agentType: .personal,
            displayName: hostname,
            bio: "Personal AI agent on \(hardware.chipName)",
            capabilities: [.generalChat, .inference, .taskExecution],
            preferences: AgentPreferences(
                tone: .casual,
                autoNegotiate: false,
                maxBudgetPerTransaction: 50.0,
                delegationRules: [
                    DelegationRule(capability: "inference", maxCreditSpend: 10.0),
                    DelegationRule(capability: "general-chat", maxCreditSpend: 5.0),
                ]
            )
        )
        self.agentProfile = profile
        await agentManager.setup(profile: profile, creditBalance: realWallet.balance.value)

        // Initialize Solana wallet bridge if enabled
        if solanaWalletEnabled {
            await initializeSolanaWallet(creditWallet: realWallet)
        }

        // Wire credit transfer handling
        clusterManager.onCreditTransferReceived = { [weak self] payload, peer in
            guard let self = self else { return }
            let amount = CreditAmount(payload.amount)
            let senderName = payload.senderDeviceName ?? peer.deviceInfo.name
            let modelID = payload.modelID
            let tokenCount = payload.tokenCount

            let description: String
            if let tokenCount, let modelName = self.resolveModelDescriptor(for: modelID)?.name {
                description = "Received \(String(format: "%.2f", payload.amount)) credits from \(senderName) for \(tokenCount) tokens of \(modelName)"
            } else if let memo = payload.memo {
                description = "Received \(String(format: "%.2f", payload.amount)) credits from \(senderName): \(memo)"
            } else {
                description = "Received \(String(format: "%.2f", payload.amount)) credits from \(senderName)"
            }

            await self.wallet.recordTransferCredit(
                amount: amount,
                fromPeer: payload.senderNodeID,
                description: description,
                modelID: modelID,
                tokenCount: tokenCount
            )

            if self.isInferenceSettlement(payload) && self.isSameOwner(peer: peer) {
                let refundDescription = "Refunded internal LAN inference receipt for \(senderName) (same account)"
                await self.wallet.recordAdjustmentDebit(
                    amount: amount,
                    description: refundDescription,
                    peerNodeID: payload.senderNodeID,
                    modelID: modelID,
                    tokenCount: tokenCount
                )
            }

            let confirm = CreditTransferConfirmPayload(
                transferID: payload.transferID,
                receiverNodeID: self.clusterManager.localDeviceInfo.id.uuidString
            )
            try? await peer.connection.send(.creditTransferConfirm(confirm))
        }
    }

    private static func stableNodeID() -> String {
        if let existing = UserDefaults.standard.string(forKey: stableNodeIDKey), !existing.isEmpty {
            return existing
        }

        let nodeID = UUID().uuidString
        UserDefaults.standard.set(nodeID, forKey: stableNodeIDKey)
        return nodeID
    }

    // MARK: - Solana Wallet

    private func initializeSolanaWallet(creditWallet: CreditWallet) async {
        do {
            let solanaIdentity = try SolanaIdentity.loadOrCreate()
            let config: WalletKitConfig = solanaNetwork == "mainnet" ? .mainnet : .devnet
            let bridge = WalletBridge(identity: solanaIdentity, creditWallet: creditWallet, config: config)
            await bridge.startMonitoring()
            self.walletBridge = bridge
        } catch {
            print("[WalletKit] Failed to initialize Solana wallet: \(error)")
        }
    }

    private func toggleSolanaWallet() async {
        if solanaWalletEnabled {
            await initializeSolanaWallet(creditWallet: wallet)
        } else {
            if let bridge = walletBridge {
                await bridge.stopMonitoring()
            }
            walletBridge = nil
        }
    }

    // MARK: - Actions

    /// Download model files only — does not load into memory.
    /// Multiple downloads can run concurrently.
    public func downloadModel(_ descriptor: ModelDescriptor) async {
        activeDownloads[descriptor.id] = 0.0
        do {
            try await modelManager.downloadModel(descriptor)
            activeDownloads.removeValue(forKey: descriptor.id)
            downloadedModelIDs.insert(descriptor.id)
            // Prompt user to load if another model is currently active
            if case .ready = engineStatus {
                justDownloadedModel = descriptor
            } else if case .idle = engineStatus {
                // No model loaded — auto-load
                await loadModel(descriptor)
            }
        } catch {
            activeDownloads.removeValue(forKey: descriptor.id)
        }
    }

    /// Load a model into GPU memory for inference.
    public func loadModel(_ descriptor: ModelDescriptor) async {
        do {
            // Unload any currently loaded model first
            if case .ready = engineStatus {
                await engine.unloadModel()
            }

            selectedModel = descriptor
            engineStatus = .loadingModel(descriptor)
            loadingPhase = "Preparing…"
            loadingProgress = 0

            try await engine.loadModel(descriptor) { [weak self] progress in
                // Avoid creating unstructured Task per progress update — the rapid fire-and-forget
                // Task { @MainActor } pattern can trigger swift_task_dealloc crashes when the
                // parent async context completes while orphaned tasks are still queued.
                DispatchQueue.main.async { [weak self] in
                    self?.loadingPhase = progress.phase.rawValue
                    self?.loadingProgress = progress.fractionCompleted
                }
            }

            loadingPhase = ""
            loadingProgress = nil
            engineStatus = .ready(descriptor)
            syncAdvertisedLoadedModels()
            await refreshDownloadedModels()
        } catch {
            loadingPhase = ""
            loadingProgress = nil
            engineStatus = .error(error.localizedDescription)
            syncAdvertisedLoadedModels()
        }
    }

    public func refreshDownloadedModels() async {
        var ids = Set<String>()
        for model in modelManager.compatibleModels {
            if await modelManager.isDownloaded(model) {
                ids.insert(model.id)
            }
        }
        downloadedModelIDs = ids
    }

    public func unloadModel() async {
        await engine.unloadModel()
        selectedModel = nil
        engineStatus = .idle
        syncAdvertisedLoadedModels()
    }

    public func startServer() async {
        guard !isServerRunning else { return }
        isServerRunning = true
        let server = LocalHTTPServer(
            engine: engine,
            port: serverPort,
            apiKeyStore: apiKeyStore,
            allowNetworkAccess: allowNetworkAccess
        )
        Task.detached {
            try? await server.start()
        }
    }

    public func refreshStatus() async {
        engineStatus = await engine.status
        syncAdvertisedLoadedModels()
    }

    /// Send credits to a connected peer
    public func sendCredits(amount: Double, to peerID: UUID, memo: String? = nil) async -> Bool {
        let peerNodeID = peerID.uuidString
        let success = await wallet.sendTransfer(amount: amount, toPeer: peerNodeID, memo: memo)
        guard success else { return false }

        let payload = CreditTransferPayload(
            senderNodeID: Self.stableNodeID(),
            senderDeviceName: ProcessInfo.processInfo.hostName,
            amount: amount,
            memo: memo
        )
        do {
            try await clusterManager.sendCreditTransfer(to: peerID, payload: payload)
            return true
        } catch {
            return false
        }
    }

    // MARK: - Cluster (LAN)

    private func toggleCluster() {
        if clusterEnabled {
            enableCluster()
        } else {
            disableCluster()
        }
    }

    private func enableCluster() {
        let clusterProvider = ClusterProvider(
            localProvider: localProvider,
            clusterManager: clusterManager,
            onRemoteGenerationCompleted: { [weak self] record in
                await self?.recordRemoteInferenceSettlement(record)
            }
        )
        Task {
            await engine.setProvider(clusterProvider)
        }
        modelManager.peerModelSource = clusterManager
        clusterManager.updateAuthenticatedUserID(authManager?.currentUser?.id)
        clusterManager.enable()
        syncAdvertisedLoadedModels()
        clusterManager.scanForPeers()
    }

    private func disableCluster() {
        clusterManager.disable()
        modelManager.peerModelSource = nil
        Task {
            await engine.setProvider(localProvider)
        }
    }

    private func syncAdvertisedLoadedModels() {
        let loadedModels: [String]
        switch engineStatus {
        case .ready(let descriptor):
            loadedModels = [descriptor.huggingFaceRepo]
        default:
            loadedModels = []
        }

        clusterManager.updateLocalLoadedModels(loadedModels)
    }

    private func recordRemoteInferenceSettlement(_ record: ClusterProvider.RemoteGenerationRecord) async {
        guard let model = resolveModelDescriptor(for: record.modelID) else {
            return
        }

        let amount = CreditPricing.cost(tokenCount: record.tokenCount, model: model)
        let peerNodeID = record.peer.id.uuidString
        let sameOwner = isSameOwner(peer: record.peer)
        let requesterNodeID = Self.stableNodeID()
        let requesterName = ProcessInfo.processInfo.hostName
        let memo = "LAN inference settlement for \(record.tokenCount) tokens of \(model.name)"
        let payload = CreditTransferPayload(
            senderNodeID: requesterNodeID,
            senderDeviceName: requesterName,
            amount: amount.value,
            memo: memo,
            modelID: model.id,
            tokenCount: record.tokenCount
        )

        do {
            try await clusterManager.sendCreditTransfer(to: record.peer.id, payload: payload)
        } catch {
            return
        }

        let transferDescription = "Sent \(String(format: "%.2f", amount.value)) credits to \(record.peer.deviceInfo.name) for \(record.tokenCount) tokens of \(model.name)"
        await wallet.recordTransferDebit(
            amount: amount,
            toPeer: peerNodeID,
            description: transferDescription,
            modelID: model.id,
            tokenCount: record.tokenCount
        )

        if sameOwner {
            let refundDescription = "Refunded internal LAN inference settlement with \(record.peer.deviceInfo.name) (same account)"
            await wallet.recordAdjustmentCredit(
                amount: amount,
                description: refundDescription,
                peerNodeID: peerNodeID,
                modelID: model.id,
                tokenCount: record.tokenCount
            )
        }
    }

    private func resolveModelDescriptor(for modelID: String?) -> ModelDescriptor? {
        guard let modelID, !modelID.isEmpty else {
            return nil
        }

        return ModelCatalog.allModels.first {
            $0.id == modelID || $0.huggingFaceRepo == modelID || $0.name == modelID
        }
    }

    private func isInferenceSettlement(_ payload: CreditTransferPayload) -> Bool {
        payload.modelID != nil || payload.tokenCount != nil
    }

    private func isSameOwner(peer: PeerInfo) -> Bool {
        guard let authManager, let currentUser = authManager.currentUser else {
            return false
        }

        if let ownerUserID = peer.ownerUserID {
            return ownerUserID == currentUser.id
        }

        return authManager.devices.contains { device in
            guard device.userID == currentUser.id else { return false }
            guard device.deviceName == peer.deviceInfo.name else { return false }

            if let chipName = device.chipName,
               chipName != peer.deviceInfo.hardware.chipName {
                return false
            }

            if let ramGB = device.ramGB,
               ramGB != Int(peer.deviceInfo.hardware.totalRAMGB) {
                return false
            }

            return true
        }
    }

    // MARK: - WAN P2P

    private func toggleWAN() {
        if wanEnabled {
            enableWAN()
        } else {
            disableWAN()
        }
    }

    private func enableWAN() {
        Task {
            do {
                let identity = try WANNodeIdentity.loadOrCreate()
                let config = WANConfig(
                    relayServerURLs: [URL(string: wanRelayURL)!],
                    identity: identity,
                    displayName: ProcessInfo.processInfo.hostName
                )
                let deviceInfo = DeviceInfo(name: ProcessInfo.processInfo.hostName, hardware: hardware)
                try await wanManager.enable(config: config, localDeviceInfo: deviceInfo)

                // Set up WAN provider
                let wanProvider = WANProvider(localProvider: localProvider, wanManager: wanManager)
                await engine.setProvider(wanProvider)
            } catch {
                print("[WAN] Failed to enable: \(error.localizedDescription)")
                wanEnabled = false
            }
        }
    }

    private func disableWAN() {
        Task {
            await wanManager.disable()
            await engine.setProvider(localProvider)
        }
    }
}

// MARK: - App View

public enum AppView: Hashable {
    case dashboard
    case chat
    case models
    case cluster
    case wan
    case wallet
    case agents
    case devices
    case settings
}
