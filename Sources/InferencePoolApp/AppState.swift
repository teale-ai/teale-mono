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

    // Agent
    public let agentManager: AgentManager
    public var agentProfile: AgentProfile?

    // Server
    public var serverPort: Int = 11435
    public var isServerRunning: Bool = false

    // UI State
    public var selectedModel: ModelDescriptor?
    public var engineStatus: EngineStatus = .idle
    public var currentView: AppView = .dashboard

    // Settings
    public var launchAtLogin: Bool = false
    public var maxStorageGB: Double = 50.0
    public var wanRelayURL: String = "wss://relay.solair.network/ws"

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
        self.agentManager = AgentManager()

        // Wallet placeholder — replaced async on launch
        self.wallet = CreditWallet.placeholder()
    }

    /// Call once at app launch to initialize async components (credit ledger, agent)
    public func initializeAsync() async {
        // Initialize credit wallet
        let ledger = await CreditLedger()
        await ledger.applyWelcomeBonusIfNeeded()
        let realWallet = CreditWallet(ledger: ledger)
        await realWallet.refreshBalance()
        self.wallet = realWallet

        // Initialize agent profile
        let hostname = ProcessInfo.processInfo.hostName
        let nodeID: String
        if let identity = try? WANNodeIdentity.loadOrCreate() {
            nodeID = identity.nodeID
        } else {
            nodeID = UUID().uuidString
        }

        let profile = AgentProfile(
            nodeID: nodeID,
            agentType: .personal,
            displayName: hostname,
            bio: "Personal AI agent on \(hardware.chipName)",
            capabilities: [.generalChat, .inference, .taskExecution],
            preferences: AgentPreferences(
                tone: .casual,
                autoNegotiate: true,
                maxBudgetPerTransaction: 50.0,
                delegationRules: [
                    DelegationRule(capability: "inference", maxCreditSpend: 10.0),
                    DelegationRule(capability: "general-chat", maxCreditSpend: 5.0),
                ]
            )
        )
        self.agentProfile = profile
        await agentManager.setup(profile: profile, creditBalance: realWallet.balance.value)
    }

    // MARK: - Actions

    public func loadModel(_ descriptor: ModelDescriptor) async {
        do {
            selectedModel = descriptor
            engineStatus = .loadingModel(descriptor)
            try await engine.loadModel(descriptor)
            engineStatus = .ready(descriptor)
        } catch {
            engineStatus = .error(error.localizedDescription)
        }
    }

    public func unloadModel() async {
        await engine.unloadModel()
        selectedModel = nil
        engineStatus = .idle
    }

    public func startServer() async {
        guard !isServerRunning else { return }
        isServerRunning = true
        let server = LocalHTTPServer(engine: engine, port: serverPort)
        Task.detached {
            try? await server.start()
        }
    }

    public func refreshStatus() async {
        engineStatus = await engine.status
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
        clusterManager.enable()
    }

    private func disableCluster() {
        clusterManager.disable()
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
    case settings
}
