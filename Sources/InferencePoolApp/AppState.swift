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
        didSet { toggleWAN() }
    }

    // Credits
    public var wallet: CreditWallet

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

    // Settings
    public var launchAtLogin: Bool = false
    public var maxStorageGB: Double = 50.0
    public var wanRelayURL: String = "wss://relay.teale.network/ws"
    public var autoManageModels: Bool = false {
        didSet { demandTracker.autoManageEnabled = autoManageModels }
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
        let nodeID = UUID().uuidString

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
            await refreshDownloadedModels()
        } catch {
            loadingPhase = ""
            loadingProgress = nil
            engineStatus = .error(error.localizedDescription)
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
