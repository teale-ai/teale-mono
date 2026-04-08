import Foundation
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

// MARK: - App State

@MainActor
@Observable
public final class AppState {
    private enum Preferences {
        static let maxStorageGB = "teale.maxStorageGB"
        static let wanRelayURL = "teale.wanRelayURL"
        static let installNodeID = "teale.installNodeID"
    }

    // Hardware
    public let hardware: HardwareCapability
    public let throttler: AdaptiveThrottler

    // Engine
    public let engine: InferenceEngineManager

    // Local inference provider
    private let localProvider: MLXProvider

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
    public var wallet: CreditWallet

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

    // Settings
    public var launchAtLogin: Bool = false
    public var maxStorageGB: Double = 50.0 {
        didSet {
            UserDefaults.standard.set(maxStorageGB, forKey: Preferences.maxStorageGB)
            Task { await modelManager.cache.setMaxStorage(maxStorageGB) }
        }
    }
    public var wanRelayURL: String = "wss://relay.teale.com/ws" {
        didSet {
            UserDefaults.standard.set(wanRelayURL, forKey: Preferences.wanRelayURL)
        }
    }
    public var autoManageModels: Bool = false {
        didSet { demandTracker.autoManageEnabled = autoManageModels }
    }

    private var isUpdatingWANToggle: Bool = false

    public init() {
        let detector = HardwareDetector()
        let hw = detector.detect()
        self.hardware = hw
        self.throttler = AdaptiveThrottler()

        let mlxProvider = MLXProvider()
        self.localProvider = mlxProvider
        let persistedMaxStorage = UserDefaults.standard.object(forKey: Preferences.maxStorageGB) as? Double ?? 50.0
        self.engine = InferenceEngineManager(provider: mlxProvider, throttler: throttler)
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
        self.wallet = CreditWallet.placeholder()
        self.maxStorageGB = persistedMaxStorage
        self.wanRelayURL = UserDefaults.standard.string(forKey: Preferences.wanRelayURL) ?? "wss://relay.teale.com/ws"
        // Start server eagerly so it's available even if the MenuBarExtra is never clicked.
        // DispatchQueue.global dispatches to a background thread, then Task hops to @MainActor.
        let appState = self
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 1) {
            Task { @MainActor in
                await appState.startServer()
                await appState.initializeAsync()
            }
        }

        self.clusterManager.onInferenceRequest = { [weak self] payload, connection in
            await self?.handleIncomingInferenceRequest(
                payload,
                sendMessage: { message in
                    try await connection.send(message)
                }
            )
        }
        self.wanManager.onInferenceRequest = { [weak self] payload, connection in
            await self?.handleIncomingInferenceRequest(
                payload,
                sendMessage: { message in
                    try await connection.send(message)
                }
            )
        }
    }

    /// Call once at app launch to initialize async components (auth, credit ledger, agent)
    public func initializeAsync() async {
        // Scan which models are already downloaded
        await refreshDownloadedModels()

        // Check auth session (skip if Supabase not configured)
        if let authManager {
            await authManager.checkSession()
            authManager.deviceHardware = (chipName: hardware.chipName, ramGB: Int(hardware.totalRAMGB))
        }

        // Initialize credit wallet
        let ledger = await CreditLedger()
        await ledger.applyWelcomeBonusIfNeeded()
        let realWallet = CreditWallet(ledger: ledger)
        await realWallet.refreshBalance()
        self.wallet = realWallet

        // Initialize agent profile — use a random node ID to avoid Keychain prompt on launch.
        // WANNodeIdentity is created lazily when WAN is actually enabled.
        let hostname = ProcessInfo.processInfo.hostName
        let nodeID = stableInstallNodeID()

        // Link WAN identity to auth device record
        if let authManager {
            authManager.wanNodeID = nodeID
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
                    DelegationRule(capability: "inference", maxCreditSpend: 10.0),
                    DelegationRule(capability: "general-chat", maxCreditSpend: 5.0),
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

        // Wire credit transfer handling
        clusterManager.onCreditTransferReceived = { [weak self] payload, connection in
            guard let self = self else { return }
            await self.wallet.receiveTransfer(amount: payload.amount, fromPeer: payload.senderNodeID, memo: payload.memo)
            let confirm = CreditTransferConfirmPayload(
                transferID: payload.transferID,
                receiverNodeID: self.clusterManager.localDeviceInfo.id.uuidString
            )
            try? await connection.send(.creditTransferConfirm(confirm))
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
            await refreshDownloadedModels()
        } catch {
            loadingPhase = ""
            loadingProgress = nil
            engineStatus = .error(error.localizedDescription)
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
        await engine.unloadModel()
        selectedModel = nil
        engineStatus = .idle
        if wanEnabled {
            await wanManager.updateLocalLoadedModels([])
        }
    }

    private func handleIncomingInferenceRequest(
        _ payload: InferenceRequestPayload,
        sendMessage: @escaping @Sendable (ClusterMessage) async throws -> Void
    ) async {
        let localModelID = selectedModel?.huggingFaceRepo
        let requestedModelID = payload.request.model ?? localModelID

        guard let requestedModelID else {
            try? await sendMessage(.inferenceError(InferenceErrorPayload(
                requestID: payload.requestID,
                errorMessage: "No model specified for remote inference request"
            )))
            return
        }

        guard localModelID == requestedModelID else {
            try? await sendMessage(.inferenceError(InferenceErrorPayload(
                requestID: payload.requestID,
                errorMessage: "Model \(requestedModelID) is not loaded on this device"
            )))
            return
        }

        var request = payload.request
        request.model = requestedModelID

        do {
            let stream = localProvider.generate(request: request)
            for try await chunk in stream {
                try await sendMessage(.inferenceChunk(InferenceChunkPayload(
                    requestID: payload.requestID,
                    chunk: chunk
                )))
            }

            try await sendMessage(.inferenceComplete(InferenceCompletePayload(
                requestID: payload.requestID
            )))
        } catch {
            try? await sendMessage(.inferenceError(InferenceErrorPayload(
                requestID: payload.requestID,
                errorMessage: error.localizedDescription
            )))
        }
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
        engineStatus = await engine.status
    }

    /// Send credits to a connected peer
    public func sendCredits(amount: Double, to peerID: UUID, memo: String? = nil) async -> Bool {
        let peerNodeID = peerID.uuidString
        let success = await wallet.sendTransfer(amount: amount, toPeer: peerNodeID, memo: memo)
        guard success else { return false }

        let payload = CreditTransferPayload(
            senderNodeID: clusterManager.localDeviceInfo.id.uuidString,
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
        let clusterProvider = ClusterProvider(localProvider: localProvider, clusterManager: clusterManager)
        Task {
            await engine.setProvider(clusterProvider)
        }
        modelManager.peerModelSource = clusterManager
        clusterManager.enable()
    }

    private func disableCluster() {
        clusterManager.disable()
        modelManager.peerModelSource = nil
        Task {
            await engine.setProvider(localProvider)
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

                // Hop back to main actor for UI/engine updates.
                await MainActor.run {
                    let wanProvider = WANProvider(localProvider: self.localProvider, wanManager: self.wanManager)
                    Task { await self.engine.setProvider(wanProvider) }
                    self.wanLastError = nil
                    self.isWANBusy = false
                }
            } catch {
                let msg = error.localizedDescription
                guard let self else { return }
                await MainActor.run {
                    self.wanLastError = msg
                    self.isWANBusy = false
                    self.setWANEnabled(false)
                }
                await self.wanManager.disable()
                await self.engine.setProvider(self.localProvider)
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
            await engine.setProvider(localProvider)
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
