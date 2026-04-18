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
    private enum Preferences {
        static let maxStorageGB = "teale.maxStorageGB"
        static let wanRelayURL = "teale.wanRelayURL"
        static let installNodeID = "teale.installNodeID"
    }

    private static let stableNodeIDKey = "teale.stable_node_id"
    private static let inferenceBackendKey = "teale.inference_backend"
    private static let exoBaseURLKey = "teale.exo_base_url"
    private static let exoPreferredModelIDKey = "teale.exo_preferred_model_id"
    private static let wanRelayURLKey = "teale.wan_relay_url"

    // Hardware
    public let hardware: HardwareCapability
    public let throttler: AdaptiveThrottler

    // Engine
    public let engine: InferenceEngineManager

    // Local inference provider
    private let localProvider: MLXProvider
    private let exoProvider: ExoProvider

    // Models
    public let modelManager: ModelManagerService
    public let demandTracker: ModelDemandTracker

    // Cluster (LAN)
    public let clusterManager: ClusterManager
    public var clusterEnabled: Bool = false {
        didSet { toggleCluster() }
    }

    // WAN P2P
    public let wanManager: WANManager
    public var wanEnabled: Bool = false {
        didSet {
            guard !isUpdatingWANToggle else { return }
            toggleWAN()
        }
    }
    public var isWANBusy: Bool = false
    public var wanLastError: String?

    // Credits
    public var wallet: USDCWallet

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

    // Local model discovery
    public let localModelScanner = LocalModelScanner()
    public var scannedLocalModels: [LocalModelInfo] = []

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
    public var inferenceBackend: InferenceBackend = InferenceBackend(
        rawValue: UserDefaults.standard.string(forKey: inferenceBackendKey) ?? InferenceBackend.localMLX.rawValue
    ) ?? .localMLX {
        didSet {
            UserDefaults.standard.set(inferenceBackend.rawValue, forKey: Self.inferenceBackendKey)
            Task { await applyInferenceBackendSelection() }
        }
    }
    public var exoBaseURL: String = UserDefaults.standard.string(forKey: exoBaseURLKey) ?? "http://localhost:52415" {
        didSet {
            UserDefaults.standard.set(exoBaseURL, forKey: Self.exoBaseURLKey)
            Task { await applyInferenceBackendSelection() }
        }
    }
    public var exoPreferredModelID: String = UserDefaults.standard.string(forKey: exoPreferredModelIDKey) ?? "" {
        didSet {
            UserDefaults.standard.set(exoPreferredModelID, forKey: Self.exoPreferredModelIDKey)
            Task { await applyInferenceBackendSelection() }
        }
    }
    public var exoAvailableModels: [String] = []
    public var exoRunningModels: [String] = []
    public var exoStatusMessage: String = "Exo not configured"
    public var maxStorageGB: Double = UserDefaults.standard.object(forKey: Preferences.maxStorageGB) as? Double ?? 50.0 {
        didSet {
            UserDefaults.standard.set(maxStorageGB, forKey: Preferences.maxStorageGB)
            Task { await modelManager.cache.setMaxStorage(maxStorageGB) }
        }
    }
    public var wanRelayURL: String = UserDefaults.standard.string(forKey: "teale.wan_relay_url") ?? "wss://relay.teale.com/ws" {
        didSet { UserDefaults.standard.set(wanRelayURL, forKey: "teale.wan_relay_url") }
    }
    public var autoManageModels: Bool = false {
        didSet { demandTracker.autoManageEnabled = autoManageModels }
    }

    private var isUpdatingWANToggle: Bool = false

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

    public var inferenceEngineName: String {
        switch inferenceBackend {
        case .localMLX:
            return "MLX"
        case .exo:
            return "Exo"
        }
    }

    public var hasAvailableInferenceTarget: Bool {
        if case .ready = engineStatus {
            return true
        }

        if clusterEnabled,
           clusterManager.topology.connectedPeers.contains(where: {
               !$0.isGenerating && $0.throttleLevel > 0 && !$0.loadedModels.isEmpty
           }) {
            return true
        }

        if wanEnabled {
            return wanManager.state.connectedPeers.contains { !$0.loadedModels.isEmpty }
        }

        return false
    }

    public init(autoStart: Bool = true) {
        let detector = HardwareDetector()
        let hw = detector.detect()
        let initialBackend = InferenceBackend(
            rawValue: UserDefaults.standard.string(forKey: Self.inferenceBackendKey) ?? InferenceBackend.localMLX.rawValue
        ) ?? .localMLX
        self.hardware = hw
        self.throttler = AdaptiveThrottler()

        let mlxProvider = MLXProvider()
        self.localProvider = mlxProvider
        let persistedMaxStorage = UserDefaults.standard.object(forKey: Preferences.maxStorageGB) as? Double ?? 50.0
        let exoProvider = ExoProvider(
            baseURLString: UserDefaults.standard.string(forKey: Self.exoBaseURLKey) ?? "http://localhost:52415",
            preferredModelID: UserDefaults.standard.string(forKey: Self.exoPreferredModelIDKey)
        )
        self.exoProvider = exoProvider
        let initialProvider: any InferenceProvider
        if initialBackend == .exo {
            initialProvider = exoProvider
        } else {
            initialProvider = mlxProvider
        }
        self.engine = InferenceEngineManager(provider: initialProvider, throttler: throttler)
        self.modelManager = ModelManagerService(hardware: hw, maxStorageGB: persistedMaxStorage)
        self.demandTracker = ModelDemandTracker(catalog: modelManager.catalog, hardware: hw)

        let hostname = ProcessInfo.processInfo.hostName
        let deviceInfo = DeviceInfo(name: hostname, hardware: hw)
        self.clusterManager = ClusterManager(localDeviceInfo: deviceInfo)
        self.wanManager = WANManager()
        if let config = SupabaseConfig.default {
            self.authManager = AuthManager(config: config)
        } else {
            self.authManager = nil
        }
        self.agentManager = AgentManager()

        // Wallet placeholder — replaced async on launch
        self.wallet = USDCWallet.placeholder()
        self.maxStorageGB = persistedMaxStorage
        self.wanRelayURL = UserDefaults.standard.string(forKey: Self.wanRelayURLKey) ?? "wss://relay.teale.com/ws"
        // Start server eagerly so it's available even if the MenuBarExtra is never clicked.
        // CLI callers pass autoStart: false and call startServer()/initializeAsync() manually.
        if autoStart {
            let appState = self
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 1) {
                Task { @MainActor in
                    await appState.startServer()
                    await appState.initializeAsync()
                }
            }
        }

        self.clusterManager.onInferenceRequest = { [weak self, clusterManager] payload, peer in
            guard let self else { return }

            clusterManager.beginServingInference()
            defer { clusterManager.endServingInference() }

            do {
                let provider = self.currentServingProvider()
                let stream = provider.generate(request: payload.request)
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

        self.wanManager.onInferenceRequest = { [weak self] payload, connection in
            guard let self else { return }

            do {
                let provider = self.currentServingProvider()
                let stream = provider.generate(request: payload.request)
                for try await chunk in stream {
                    let response = InferenceChunkPayload(requestID: payload.requestID, chunk: chunk)
                    try await connection.send(.inferenceChunk(response))
                }

                let complete = InferenceCompletePayload(requestID: payload.requestID)
                try await connection.send(.inferenceComplete(complete))
            } catch {
                let response = InferenceErrorPayload(
                    requestID: payload.requestID,
                    errorMessage: error.localizedDescription
                )
                try? await connection.send(.inferenceError(response))
            }
        }
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

        await applyInferenceBackendSelection()

        // Initialize credit wallet
        let ledger = await USDCLedger()
        await ledger.applyWelcomeBonusIfNeeded()
        let realWallet = USDCWallet(ledger: ledger)
        await realWallet.refreshBalance()
        self.wallet = realWallet

        // Initialize agent profile with a stable local node ID.
        // WANNodeIdentity is created lazily when WAN is actually enabled.
        let hostname = ProcessInfo.processInfo.hostName
        // Link WAN identity to auth device record
        if let authManager {
            if authManager.authState.isAuthenticated {
                await authManager.fetchDevices()
            }
        }

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
                    DelegationRule(capability: "inference", maxSpend: 10.0),
                    DelegationRule(capability: "general-chat", maxSpend: 5.0),
                ]
            )
        )
        self.agentProfile = profile
        await agentManager.setup(profile: profile, creditBalance: realWallet.balance.value)

        // Wire auto model management — download in-demand models when enabled
        demandTracker.onAutoDownloadRequested = { [weak self] model in
            guard let self else { return }
            // Only auto-download if not already downloaded or downloading
            guard !self.downloadedModelIDs.contains(model.id),
                  self.activeDownloads[model.id] == nil else { return }
            Task { @MainActor in
                await self.downloadModel(model)
            }
        }

        // Initialize Solana wallet bridge if enabled
        if solanaWalletEnabled {
            await initializeSolanaWallet(usdcWallet: realWallet)
        }

        // Wire credit transfer handling
        clusterManager.onCreditTransferReceived = { [weak self] payload, peer in
            guard let self = self else { return }
            let amount = USDCAmount(payload.amount)
            let senderName = payload.senderDeviceName ?? peer.deviceInfo.name
            let modelID = payload.modelID
            let tokenCount = payload.tokenCount

            let description: String
            if let tokenCount, let modelName = self.resolveModelDescriptor(for: modelID)?.name {
                description = "Received \(amount.description) from \(senderName) for \(tokenCount) tokens of \(modelName)"
            } else if let memo = payload.memo {
                description = "Received \(amount.description) from \(senderName): \(memo)"
            } else {
                description = "Received \(amount.description) from \(senderName)"
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

            let confirm = USDCTransferConfirmPayload(
                transferID: payload.transferID,
                receiverNodeID: self.clusterManager.localDeviceInfo.id.uuidString
            )
            try? await peer.connection.send(.usdcTransferConfirm(confirm))
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

    private func initializeSolanaWallet(usdcWallet: USDCWallet) async {
        do {
            let solanaIdentity = try SolanaIdentity.loadOrCreate()
            let config: WalletKitConfig = solanaNetwork == "mainnet" ? .mainnet : .devnet
            let bridge = WalletBridge(identity: solanaIdentity, creditWallet: usdcWallet, config: config)
            await bridge.startMonitoring()
            self.walletBridge = bridge
        } catch {
            print("[WalletKit] Failed to initialize Solana wallet: \(error)")
        }
    }

    private func toggleSolanaWallet() async {
        if solanaWalletEnabled {
            await initializeSolanaWallet(usdcWallet: wallet)
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

        // Sync progress from modelManager → activeDownloads so the UI updates
        let progressTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                if let progress = self?.modelManager.downloadingModels[descriptor.id] {
                    self?.activeDownloads[descriptor.id] = progress
                }
                try await Task.sleep(for: .milliseconds(200))
            }
        }

        do {
            try await modelManager.downloadModel(descriptor)
            progressTask.cancel()
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
            progressTask.cancel()
            activeDownloads.removeValue(forKey: descriptor.id)
        }
    }

    /// Load a model into GPU memory for inference.
    public func loadModel(_ descriptor: ModelDescriptor) async {
        if inferenceBackend == .exo {
            exoPreferredModelID = descriptor.huggingFaceRepo
            return
        }

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
            Self.wanLog("Model loaded successfully: \(descriptor.huggingFaceRepo), calling syncAdvertised...")
            syncAdvertisedLoadedModels()
            await refreshDownloadedModels()
        } catch {
            loadingPhase = ""
            loadingProgress = nil
            engineStatus = .error(error.localizedDescription)
            syncAdvertisedLoadedModels()
        }
    }

    /// Load a model from a local directory (no download needed).
    public func loadLocalModel(_ localModel: LocalModelInfo) async {
        let descriptor = localModel.toDescriptor()
        do {
            if case .ready = engineStatus {
                await engine.unloadModel()
            }

            selectedModel = descriptor
            engineStatus = .loadingModel(descriptor)
            loadingPhase = "Loading weights into memory…"
            loadingProgress = 0

            try await localProvider.loadLocalModel(from: localModel.path, descriptor: descriptor) { [weak self] progress in
                Task { @MainActor in
                    self?.loadingPhase = progress.phase.rawValue
                    self?.loadingProgress = progress.fractionCompleted
                }
            }

            loadingPhase = ""
            loadingProgress = nil
            engineStatus = .ready(descriptor)
            if wanEnabled {
                await wanManager.updateLocalLoadedModels([descriptor.huggingFaceRepo])
            }
        } catch {
            loadingPhase = ""
            loadingProgress = nil
            engineStatus = .error(error.localizedDescription)
        }
    }

    /// Scan for MLX-compatible models in known local directories.
    public func scanLocalModels() {
        scannedLocalModels = localModelScanner.scanAll()
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
        if inferenceBackend == .exo {
            exoPreferredModelID = ""
            return
        }

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
            allowNetworkAccess: allowNetworkAccess,
            controller: RemoteControlBridge(appState: self)
        )
        Task.detached {
            try? await server.start()
        }
    }

    public func refreshStatus() async {
        if inferenceBackend == .exo {
            try? await exoProvider.refreshSelection()
        }

        engineStatus = await engine.status
        selectedModel = await engine.loadedModel

        if inferenceBackend == .exo {
            exoAvailableModels = await exoProvider.availableModelIDs
            exoRunningModels = await exoProvider.runningModelIDs
            exoStatusMessage = await exoProvider.connectionSummary
        } else {
            exoAvailableModels = []
            exoRunningModels = []
            exoStatusMessage = "Exo not in use"
        }

        syncAdvertisedLoadedModels()
    }

    /// Send credits to a connected peer
    public func sendCredits(amount: Double, to peerID: UUID, memo: String? = nil) async -> Bool {
        let peerNodeID = peerID.uuidString
        let success = await wallet.sendTransfer(amount: amount, toPeer: peerNodeID, memo: memo)
        guard success else { return false }

        let payload = USDCTransferPayload(
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
        modelManager.peerModelSource = clusterManager
        clusterManager.updateAuthenticatedUserID(authManager?.currentUser?.id)
        clusterManager.enable()
        syncLANPeersToWAN()
        Task { await applyInferenceBackendSelection() }
        clusterManager.scanForPeers()
    }

    private func disableCluster() {
        clusterManager.disable()
        modelManager.peerModelSource = nil
        wanManager.lanPeerNodeIDs = []
        Task { await applyInferenceBackendSelection() }
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
        if wanEnabled {
            let models = loadedModels
            Task {
                Self.wanLog("syncAdvertised: updating WAN loaded models to \(models)")
                await wanManager.updateLocalLoadedModels(models)
            }
        } else {
            Self.wanLog("syncAdvertised: WAN not enabled, skipping (models=\(loadedModels))")
        }
    }

    private func recordRemoteInferenceSettlement(_ record: ClusterProvider.RemoteGenerationRecord) async {
        guard let model = resolveModelDescriptor(for: record.modelID) else {
            return
        }

        let amount = InferencePricing.cost(tokenCount: record.tokenCount, model: model)
        let peerNodeID = record.peer.id.uuidString
        let sameOwner = isSameOwner(peer: record.peer)
        let requesterNodeID = Self.stableNodeID()
        let requesterName = ProcessInfo.processInfo.hostName
        let memo = "LAN inference settlement for \(record.tokenCount) tokens of \(model.name)"
        let payload = USDCTransferPayload(
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

        let transferDescription = "Sent \(amount.description) to \(record.peer.deviceInfo.name) for \(record.tokenCount) tokens of \(model.name)"
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

        return modelDescriptorForExternalID(modelID)
    }

    private func isInferenceSettlement(_ payload: USDCTransferPayload) -> Bool {
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

    /// Tell WANManager which peers are reachable on LAN so it skips them for WAN auto-connect.
    private func syncLANPeersToWAN() {
        let lanIDs = Set(clusterManager.peers.keys.map(\.uuidString))
        wanManager.lanPeerNodeIDs = lanIDs
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
        let relayURLString = wanRelayURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let relayURL = validatedWANRelayURL(from: relayURLString) else {
            wanLastError = "Enter a valid relay WebSocket URL before enabling WAN."
            setWANEnabled(false)
            return
        }

        wanLastError = nil
        isWANBusy = true

        // Capture values needed off the main actor to avoid blocking it during network ops.
        let hw = hardware
        let hostName = ProcessInfo.processInfo.hostName
        let loadedModels = selectedModel.map { [$0.huggingFaceRepo] } ?? []

        // Run network-heavy work off the main actor so API endpoints remain responsive.
        Task.detached { [weak self] in
            do {
                let identity = try WANNodeIdentity.loadOrCreate()
                let config = WANConfig(
                    relayServerURLs: [relayURL],
                    identity: identity,
                    displayName: hostName
                )
                let deviceInfo = DeviceInfo(
                    name: hostName,
                    hardware: hw,
                    loadedModels: loadedModels
                )

                guard let self else { return }
                try await self.wanManager.enable(config: config, localDeviceInfo: deviceInfo)

                // Check if relay actually connected — enable() doesn't throw on relay failure
                let relayStatus = self.wanManager.state.relayStatus
                let diagnostics = self.wanManager.enableDiagnostics

                await MainActor.run {
                    self.isWANBusy = false
                    if relayStatus == .connected {
                        self.wanLastError = nil
                    } else {
                        // Surface the actual problem instead of silently pretending it worked
                        let failedSteps = diagnostics.filter { $0.contains("FAILED") }
                        if !failedSteps.isEmpty {
                            self.wanLastError = failedSteps.joined(separator: "; ")
                        } else {
                            self.wanLastError = "Relay not connected (\(relayStatus.rawValue))"
                        }
                    }
                }
                await self.applyInferenceBackendSelection()

                // Sync loaded models to WAN now that it's enabled
                // (model may have loaded before WAN was turned on)
                let currentEngineStatus = await MainActor.run(body: { String(describing: self.engineStatus) })
                let loadedModels: [String]
                if case .ready(let descriptor) = await MainActor.run(body: { self.engineStatus }) {
                    loadedModels = [descriptor.huggingFaceRepo]
                } else {
                    loadedModels = []
                }
                AppState.wanLog("Syncing loaded models after WAN enable: engineStatus=\(currentEngineStatus) loadedModels=\(loadedModels)")
                await self.wanManager.updateLocalLoadedModels(loadedModels)
            } catch {
                let msg = error.localizedDescription
                guard let self else { return }
                await MainActor.run {
                    self.wanLastError = msg
                    self.isWANBusy = false
                    self.setWANEnabled(false)
                }
                await self.wanManager.disable()
                await self.applyInferenceBackendSelection()
            }
        }
    }

    private func disableWAN(clearError: Bool = true) {
        isWANBusy = false
        if clearError {
            wanLastError = nil
        }
        Task {
            await wanManager.disable()
            await applyInferenceBackendSelection()
        }
    }

    private func validatedWANRelayURL(from string: String) -> URL? {
        guard let url = URL(string: string),
              let scheme = url.scheme?.lowercased(),
              ["ws", "wss"].contains(scheme),
              url.host != nil
        else {
            return nil
        }
        return url
    }

    private func setWANEnabled(_ enabled: Bool) {
        isUpdatingWANToggle = true
        wanEnabled = enabled
        isUpdatingWANToggle = false
    }

    /// Unbuffered stderr log for WAN diagnostics (visible even when stdout is redirected to a file).
    nonisolated static func wanLog(_ message: String) {
        let line = "[WAN] \(message)\n"
        FileHandle.standardError.write(Data(line.utf8))
    }

    private func stableInstallNodeID() -> String {
        if let existing = UserDefaults.standard.string(forKey: Preferences.installNodeID) {
            return existing
        }

        let generated = UUID().uuidString
        UserDefaults.standard.set(generated, forKey: Preferences.installNodeID)
        return generated
    }

    private func currentServingProvider() -> any InferenceProvider {
        currentBaseProvider
    }

    private var normalizedExoPreferredModelID: String? {
        let trimmed = exoPreferredModelID.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private var currentBaseProvider: any InferenceProvider {
        switch inferenceBackend {
        case .localMLX:
            return localProvider
        case .exo:
            return exoProvider
        }
    }

    private func buildActiveInferenceProvider() -> any InferenceProvider {
        var provider: any InferenceProvider = currentBaseProvider

        if clusterEnabled {
            provider = ClusterProvider(
                localProvider: provider,
                clusterManager: clusterManager,
                onRemoteGenerationCompleted: { [weak self] record in
                    await self?.recordRemoteInferenceSettlement(record)
                }
            )
        }

        if wanEnabled {
            provider = WANProvider(localProvider: provider, wanManager: wanManager)
        }

        return provider
    }

    private func applyInferenceBackendSelection() async {
        await exoProvider.updateConfiguration(
            baseURLString: exoBaseURL,
            preferredModelID: normalizedExoPreferredModelID
        )
        let provider = buildActiveInferenceProvider()
        await engine.setProvider(provider)
        await refreshStatus()
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

public enum InferenceBackend: String, CaseIterable, Hashable, Identifiable {
    case localMLX = "local_mlx"
    case exo = "exo"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .localMLX:
            return "Local MLX"
        case .exo:
            return "Exo Gateway"
        }
    }
}
