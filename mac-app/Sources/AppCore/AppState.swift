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
import LlamaCppKit
import TealeNetKit
import CompilerKit
import ChatKit

// MARK: - App State

@MainActor
@Observable
public final class AppState {
    private enum Preferences {
        static let maxStorageGB = "teale.maxStorageGB"
        static let wanRelayURL = "teale.wanRelayURL"
        static let installNodeID = "teale.installNodeID"
        static let lastLoadedModelID = "teale.lastLoadedModelID"
    }

    private static let stableNodeIDKey = "teale.stable_node_id"
    private static let inferenceBackendKey = "teale.inference_backend"
    private static let exoBaseURLKey = "teale.exo_base_url"
    private static let exoPreferredModelIDKey = "teale.exo_preferred_model_id"
    private static let wanRelayURLKey = "teale.wan_relay_url"
    private static let llamaCppBinaryPathKey = "teale.llamacpp_binary_path"
    // Local-first gateway fallback: when the local :11435 receives a chat-
    // completion request for a model this node can't serve, the route proxies
    // it to the configured gateway. Leave `gatewayAPIKey` empty to disable.
    private static let gatewayFallbackURLKey = "teale.gateway_fallback_url"
    private static let gatewayAPIKeyKey = "teale.gateway_api_key"

    // Hardware
    public let hardware: HardwareCapability
    public let throttler: AdaptiveThrottler

    // Engine
    public let engine: InferenceEngineManager
    public let requestScheduler: RequestScheduler

    // Local inference providers
    private let localProvider: MLXProvider
    private let exoProvider: ExoProvider
    private let llamaCppProvider: LlamaCppProvider

    // Compiler (Mixture of Models)
    private var compiler: Compiler?

    // Models
    public let modelManager: ModelManagerService
    public let demandTracker: ModelDemandTracker

    // Cluster (LAN)
    public let clusterManager: ClusterManager
    public var clusterEnabled: Bool = false {
        didSet {
            UserDefaults.standard.set(clusterEnabled, forKey: "teale.clusterEnabled")
            toggleCluster()
        }
    }

    // PTN (Private TealeNet)
    public let ptnManager: PTNManager

    // WAN P2P
    public let wanManager: WANManager
    public var wanEnabled: Bool = false {
        didSet {
            UserDefaults.standard.set(wanEnabled, forKey: "teale.wanEnabled")
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
    public var solanaNetwork: String = AppState.resolvedSolanaNetwork() {
        didSet {
            UserDefaults.standard.set(solanaNetwork, forKey: "teale.solanaNetwork")
            if solanaWalletEnabled {
                Task { await toggleSolanaWallet() }
            }
        }
    }

    /// One-time migration from devnet default to mainnet.
    /// Users who actively used devnet (wallet enabled) keep their choice.
    private static func resolvedSolanaNetwork() -> String {
        let defaults = UserDefaults.standard
        let migrationKey = "teale.solanaNetworkMigratedToMainnet"

        if defaults.bool(forKey: migrationKey) {
            return defaults.string(forKey: "teale.solanaNetwork") ?? "mainnet"
        }

        defaults.set(true, forKey: migrationKey)

        guard defaults.object(forKey: "teale.solanaNetwork") != nil else {
            defaults.set("mainnet", forKey: "teale.solanaNetwork")
            return "mainnet"
        }

        let saved = defaults.string(forKey: "teale.solanaNetwork") ?? "devnet"
        if saved == "devnet" && !defaults.bool(forKey: "teale.solanaWalletEnabled") {
            defaults.set("mainnet", forKey: "teale.solanaNetwork")
            return "mainnet"
        }

        return saved
    }

    // Auth
    public let authManager: AuthManager?

    // Agent
    public let agentManager: AgentManager
    public var agentProfile: AgentProfile?

    // Local model discovery
    public let localModelScanner = LocalModelScanner()
    public var scannedLocalModels: [LocalModelInfo] = []
    public let ggufScanner = GGUFScanner()
    public var scannedGGUFModels: [GGUFModelInfo] = []

    // Stats (all network tiers)
    public var totalRequestsServed: Int = 0
    public var totalTokensGenerated: Int = 0

    // Server & API Keys
    public var serverPort: Int = 11435
    public var isServerRunning: Bool = false
    public var allowNetworkAccess: Bool = UserDefaults.standard.bool(forKey: "teale.allowNetworkAccess") {
        didSet { UserDefaults.standard.set(allowNetworkAccess, forKey: "teale.allowNetworkAccess") }
    }
    /// Master opt-out for serving inference to other nodes. When false, this Mac acts purely as a chat client
    /// and will not respond to incoming LAN/WAN inference requests. Default true so existing nodes keep contributing.
    public var contributeCompute: Bool = UserDefaults.standard.object(forKey: "teale.contributeCompute") as? Bool ?? true {
        didSet { UserDefaults.standard.set(contributeCompute, forKey: "teale.contributeCompute") }
    }
    public let apiKeyStore = APIKeyStore()

    // Chat (ChatKit — unified 1:1 + group storage with E2E P2P crypto)
    public let chatService: ChatService
    public let currentUserID: UUID
    public let toolRegistry = ToolRegistry()
    public private(set) var heartbeatScheduler: HeartbeatScheduler?
    public private(set) var autoTopUpScheduler: AutoTopUpScheduler?

    // UI State
    public var selectedModel: ModelDescriptor?
    public var engineStatus: EngineStatus = .idle
    public var downloadedModelIDs: Set<String> = []
    /// Models currently being downloaded (modelID -> progress 0..1)
    public var activeDownloads: [String: Double] = [:]
    /// Models that just finished downloading — prompt user to load
    public var justDownloadedModel: ModelDescriptor?
    public var currentView: AppView = .chat
    public var showSignIn: Bool = false
    public var loadingPhase: String = ""
    public var loadingProgress: Double?
    public var pendingWalletTransferPeerID: UUID?

    // Auto-updater
    public let updateChecker = UpdateChecker()

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
    public var llamaCppBinaryPath: String = UserDefaults.standard.string(forKey: llamaCppBinaryPathKey) ?? "llama-server" {
        didSet {
            UserDefaults.standard.set(llamaCppBinaryPath, forKey: Self.llamaCppBinaryPathKey)
            Task { await applyInferenceBackendSelection() }
        }
    }
    /// Where the local :11435 route forwards requests whose model this node
    /// can't serve locally. Default is the production Teale gateway.
    public var gatewayFallbackURL: String = UserDefaults.standard.string(forKey: gatewayFallbackURLKey) ?? "https://gateway.teale.com" {
        didSet { UserDefaults.standard.set(gatewayFallbackURL, forKey: Self.gatewayFallbackURLKey) }
    }
    /// Bearer token sent on gateway-fallback requests. Empty disables the
    /// fallback — the local route will error out as before for unservable
    /// models. Stored in UserDefaults; for production deployments consider
    /// migrating to the Keychain.
    public var gatewayAPIKey: String = UserDefaults.standard.string(forKey: gatewayAPIKeyKey) ?? "" {
        didSet { UserDefaults.standard.set(gatewayAPIKey, forKey: Self.gatewayAPIKeyKey) }
    }
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
        didSet {
            UserDefaults.standard.set(autoManageModels, forKey: "teale.autoManageModels")
            demandTracker.autoManageEnabled = autoManageModels
        }
    }
    public var electricityCostPerKWh: Double = UserDefaults.standard.object(forKey: "teale.electricityCostPerKWh") as? Double ?? 0.12 {
        didSet { UserDefaults.standard.set(electricityCostPerKWh, forKey: "teale.electricityCostPerKWh") }
    }
    public var electricityCurrency: String = UserDefaults.standard.string(forKey: "teale.electricityCurrency") ?? "USD" {
        didSet { UserDefaults.standard.set(electricityCurrency, forKey: "teale.electricityCurrency") }
    }
    /// Margin multiplier over electricity cost. 1.0 = break even, 1.3 = 30% profit, <1.0 = willing to subsidize.
    public var electricityMarginMultiplier: Double = UserDefaults.standard.object(forKey: "teale.electricityMarginMultiplier") as? Double ?? 1.2 {
        didSet { UserDefaults.standard.set(electricityMarginMultiplier, forKey: "teale.electricityMarginMultiplier") }
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

    /// User-chosen UI appearance: follow system, force light, or force dark.
    public var appearance: AppAppearance = AppAppearance(
        rawValue: UserDefaults.standard.string(forKey: "teale.appearance") ?? "system"
    ) ?? .system {
        didSet { UserDefaults.standard.set(appearance.rawValue, forKey: "teale.appearance") }
    }

    public func loc(_ key: String) -> String {
        L.string(key, language: language)
    }

    public var inferenceEngineName: String {
        switch inferenceBackend {
        case .localMLX:
            return "MLX"
        case .llamaCpp:
            return "llama.cpp"
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
        let defaultProfile = DeviceModelProfileResolver.resolve(
            hardware: hw,
            userOverrides: UserProfileOverrides.load()
        )
        let llamaCppProvider = LlamaCppProvider(
            binaryPath: UserDefaults.standard.string(forKey: Self.llamaCppBinaryPathKey) ?? "llama-server",
            gpuLayers: defaultProfile.gpuLayers ?? 999,
            contextSize: defaultProfile.contextSize ?? 32768,
            parallelSlots: defaultProfile.parallelSlots ?? 1,
            batchSize: defaultProfile.batchSize ?? 4096,
            kvCacheType: defaultProfile.kvCacheType ?? "q8_0",
            flashAttn: defaultProfile.flashAttn ?? false,
            mmap: defaultProfile.mmap ?? false,
            host: "0.0.0.0"
        )
        self.llamaCppProvider = llamaCppProvider
        let initialProvider: any InferenceProvider
        switch initialBackend {
        case .exo:
            initialProvider = exoProvider
        case .llamaCpp:
            initialProvider = llamaCppProvider
        case .localMLX:
            initialProvider = mlxProvider
        }
        self.engine = InferenceEngineManager(provider: initialProvider, throttler: throttler)
        self.requestScheduler = RequestScheduler()
        self.modelManager = ModelManagerService(hardware: hw, maxStorageGB: persistedMaxStorage)
        self.demandTracker = ModelDemandTracker(catalog: modelManager.catalog, hardware: hw)

        let hostname = ProcessInfo.processInfo.hostName
        let deviceInfo = DeviceInfo(name: hostname, hardware: hw)
        self.clusterManager = ClusterManager(localDeviceInfo: deviceInfo)
        self.ptnManager = PTNManager(
            localNodeID: Self.stableNodeID(),
            localDisplayName: hostname
        )
        self.wanManager = WANManager()
        if let config = SupabaseConfig.default {
            self.authManager = AuthManager(config: config)
        } else {
            self.authManager = nil
        }
        self.agentManager = AgentManager()

        // Chat — stable local user ID for ChatKit messaging.
        // Upgraded to the authenticated user ID once Supabase auth resolves.
        let chatUserID: UUID
        if let raw = UserDefaults.standard.string(forKey: "teale.chatUserID"),
           let uuid = UUID(uuidString: raw) {
            chatUserID = uuid
        } else {
            chatUserID = UUID()
            UserDefaults.standard.set(chatUserID.uuidString, forKey: "teale.chatUserID")
        }
        self.currentUserID = chatUserID
        self.chatService = ChatService(currentUserID: chatUserID, localNodeID: Self.stableNodeID())

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

            // Honor the master "Contribute compute" opt-out.
            if !self.contributeCompute {
                let response = InferenceErrorPayload(
                    requestID: payload.requestID,
                    errorMessage: "This node is not contributing compute."
                )
                try? await peer.connection.send(.inferenceError(response))
                return
            }

            clusterManager.beginServingInference()
            defer { clusterManager.endServingInference() }

            var tokenCount = 0
            do {
                let provider = self.currentServingProvider()
                let stream = provider.generate(request: payload.request)
                for try await chunk in stream {
                    tokenCount += 1
                    let response = InferenceChunkPayload(requestID: payload.requestID, chunk: chunk)
                    try await peer.connection.send(.inferenceChunk(response))
                }

                let complete = InferenceCompletePayload(requestID: payload.requestID)
                try await peer.connection.send(.inferenceComplete(complete))

                await MainActor.run {
                    self.totalRequestsServed += 1
                    self.totalTokensGenerated += tokenCount
                }
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

            // Honor the master "Contribute compute" opt-out.
            if !self.contributeCompute {
                let response = InferenceErrorPayload(
                    requestID: payload.requestID,
                    errorMessage: "This node is not contributing compute."
                )
                try? await connection.send(.inferenceError(response))
                return
            }

            // Determine request source for WFQ scheduling
            let source: RequestScheduler.RequestSource
            if let groupID = payload.request.groupID,
               self.ptnManager.isMember(of: groupID) {
                source = .ptn(groupID)
            } else {
                source = .wwtn
            }

            var tokenCount = 0
            do {
                // Queue the request — suspends until the scheduler grants a slot
                try await self.requestScheduler.enqueue(
                    request: payload.request,
                    source: source,
                    bidAmount: nil  // TODO: extract bid from request metadata
                )

                let provider = self.currentServingProvider()
                let stream = provider.generate(request: payload.request)
                for try await chunk in stream {
                    tokenCount += 1
                    let response = InferenceChunkPayload(requestID: payload.requestID, chunk: chunk)
                    try await connection.send(.inferenceChunk(response))
                }

                let complete = InferenceCompletePayload(requestID: payload.requestID)
                try await connection.send(.inferenceComplete(complete))

                // Release the scheduler slot
                await self.requestScheduler.complete()

                await MainActor.run {
                    self.totalRequestsServed += 1
                    self.totalTokensGenerated += tokenCount
                }
            } catch {
                await self.requestScheduler.complete()
                let response = InferenceErrorPayload(
                    requestID: payload.requestID,
                    errorMessage: error.localizedDescription
                )
                try? await connection.send(.inferenceError(response))
            }
        }

        // Handle PTN join requests from remote peers
        self.wanManager.onPTNJoinRequest = { [weak self] payload, connection in
            guard let self else { return }
            do {
                let joinRequest = try JSONDecoder().decode(PTNJoinRequestPayload.self, from: payload.data)
                let response = try await self.ptnManager.handleJoinRequest(joinRequest)
                let responseData = try JSONEncoder().encode(response)
                try await connection.send(.ptnJoinResponse(PTNJoinResponseTransportPayload(data: responseData)))
            } catch {
                FileHandle.standardError.write(Data("[PTN] Join request handling failed: \(error.localizedDescription)\n".utf8))
            }
        }

        // Route AI agent inference through the shared engine (local + LAN + WAN).
        let inferenceStream: @Sendable (ChatCompletionRequest) -> AsyncThrowingStream<String, Error> = { [weak self] request in
            AsyncThrowingStream { continuation in
                Task { @MainActor [weak self] in
                    guard let self else {
                        continuation.finish()
                        return
                    }
                    do {
                        let stream = self.engine.generate(request: request)
                        for try await chunk in stream {
                            if let content = chunk.choices.first?.delta.content {
                                continuation.yield(content)
                            }
                        }
                        continuation.finish()
                    } catch {
                        continuation.finish(throwing: error)
                    }
                }
            }
        }

        // Register orchestrator tools.
        self.toolRegistry.register(CalendarToolHandler())
        self.toolRegistry.register(SubAgentDispatchHandler(inferenceStream: inferenceStream))
        self.toolRegistry.register(RememberTool(memoryStore: self.chatService.memoryStore, context: self.chatService))
        self.toolRegistry.register(RecallTool(memoryStore: self.chatService.memoryStore, context: self.chatService))
        self.toolRegistry.register(SearchHistoryTool(context: self.chatService))
        self.toolRegistry.register(SetPreferenceTool(preferenceStore: self.chatService.preferenceStore))
        self.toolRegistry.register(GetPreferencesTool(preferenceStore: self.chatService.preferenceStore))
        self.chatService.aiParticipant.toolRegistry = self.toolRegistry
        self.chatService.aiParticipant.memoryStore = self.chatService.memoryStore
        self.chatService.aiParticipant.preferenceStore = self.chatService.preferenceStore
        self.chatService.aiParticipant.onInferenceRequest = inferenceStream

        // Wire personal-wallet → group-wallet debits.
        self.chatService.onPersonalWalletDebit = { [weak self] amount, _, memo in
            guard let self else { return false }
            // Peer ID is the "group wallet" — we tag with the conversation-scoped memo.
            await self.wallet.recordTransferDebit(
                amount: USDCAmount(amount),
                toPeer: "group-wallet",
                description: memo
            )
            return true
        }

        // Start proactive heartbeat scheduler.
        let scheduler = HeartbeatScheduler(chatService: self.chatService)
        self.heartbeatScheduler = scheduler
        scheduler.start()

        // Start auto-top-up scheduler.
        let topUp = AutoTopUpScheduler(chatService: self.chatService)
        self.autoTopUpScheduler = topUp
        topUp.start()
    }

    /// Call once at app launch to initialize async components (auth, credit ledger, agent)
    public func initializeAsync() async {
        // Load PTN memberships
        await ptnManager.loadMemberships()

        // Load saved chat conversations; ensure a default DM with the AI exists
        // so the user always has a conversation to open.
        await chatService.loadConversations()
        if chatService.conversations.isEmpty {
            _ = await chatService.createDM(
                with: UUID(),
                title: "Teale",
                agentConfig: AgentConfig(
                    autoRespond: true,
                    mentionOnly: false,
                    persona: "assistant"
                )
            )
        }

        // Seed the X-ready agent-to-agent reservation demo if it doesn't exist.
        _ = await DemoReservationDriver.ensureConversationExists(
            chatService: chatService,
            currentUserID: currentUserID
        )

        // Restore power assertion if keep-awake was enabled
        if keepAwake { updatePowerAssertion() }

        // Scan which models are already downloaded
        await refreshDownloadedModels()

        // Reload the last loaded model (skip on first-ever launch)
        if let lastModelID = UserDefaults.standard.string(forKey: Preferences.lastLoadedModelID) {
            if inferenceBackend == .llamaCpp,
               lastModelID.hasPrefix("gguf-") {
                // Scan for GGUF models and try to auto-load the last one
                scanLocalModels()
                if let ggufModel = scannedGGUFModels.first(where: { "gguf-\($0.filename)" == lastModelID }) {
                    // Load directly on the provider (before engine wrapping)
                    let descriptor = ggufModel.toDescriptor()
                    selectedModel = descriptor
                    engineStatus = .loadingModel(descriptor)
                    loadingPhase = "Starting llama-server..."
                    do {
                        try await llamaCppProvider.loadModel(descriptor)
                        engineStatus = .ready(descriptor)
                        loadingPhase = ""
                        // Advertise to cluster + WAN so the gateway sees this
                        // auto-loaded model in its registry; otherwise the
                        // device looks idle until the user picks a model
                        // manually.
                        syncAdvertisedLoadedModels()
                    } catch {
                        let msg = "[GGUF] Auto-load failed: \(error.localizedDescription)"
                        FileHandle.standardError.write(Data((msg + "\n").utf8))
                        engineStatus = .error(error.localizedDescription)
                        loadingPhase = ""
                    }
                }
            } else if let descriptor = ModelCatalog.allModels.first(where: { $0.id == lastModelID }),
                      downloadedModelIDs.contains(lastModelID) {
                await loadModel(descriptor)
            }
        }

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

        // Restore persisted toggle states
        autoManageModels = UserDefaults.standard.bool(forKey: "teale.autoManageModels")
        if UserDefaults.standard.bool(forKey: "teale.clusterEnabled") {
            clusterEnabled = true
        }
        if UserDefaults.standard.bool(forKey: "teale.wanEnabled") {
            wanEnabled = true
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
            UserDefaults.standard.set(descriptor.id, forKey: Preferences.lastLoadedModelID)
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
            UserDefaults.standard.set(descriptor.id, forKey: Preferences.lastLoadedModelID)
            if wanEnabled {
                await wanManager.updateLocalLoadedModels(descriptor.advertisedId.map { [$0] } ?? [])
            }
        } catch {
            loadingPhase = ""
            loadingProgress = nil
            engineStatus = .error(error.localizedDescription)
        }
    }

    /// Load a GGUF model via llama.cpp backend.
    public func loadGGUFModel(_ ggufModel: GGUFModelInfo) async {
        let descriptor = ggufModel.toDescriptor()

        // Switch backend without triggering the didSet's async applyInferenceBackendSelection
        // by checking first. If already llamaCpp, no didSet fires.
        if inferenceBackend != .llamaCpp {
            // Temporarily set the raw UserDefaults value to avoid double-apply
            UserDefaults.standard.set(InferenceBackend.llamaCpp.rawValue, forKey: Self.inferenceBackendKey)
            inferenceBackend = .llamaCpp
        }

        do {
            if case .ready = engineStatus {
                await engine.unloadModel()
            }

            selectedModel = descriptor
            engineStatus = .loadingModel(descriptor)
            loadingPhase = "Starting llama-server..."
            loadingProgress = nil

            // Apply model-specific profile before loading
            let profile = DeviceModelProfileResolver.resolve(
                hardware: hardware, model: descriptor,
                userOverrides: UserProfileOverrides.load()
            )
            await llamaCppProvider.updateConfiguration(
                gpuLayers: profile.gpuLayers,
                contextSize: profile.contextSize,
                parallelSlots: profile.parallelSlots,
                batchSize: profile.batchSize,
                reasoningOff: profile.reasoningOff,
                kvCacheType: profile.kvCacheType,
                threads: profile.threads,
                flashAttn: profile.flashAttn,
                mmap: profile.mmap
            )

            // Load directly on the llama.cpp provider, then update the engine's provider chain
            try await llamaCppProvider.loadModel(descriptor)
            let provider = buildActiveInferenceProvider()
            await engine.setProvider(provider)

            loadingPhase = ""
            loadingProgress = nil
            engineStatus = .ready(descriptor)
            UserDefaults.standard.set(descriptor.id, forKey: Preferences.lastLoadedModelID)
            syncAdvertisedLoadedModels()
            if wanEnabled {
                await wanManager.updateLocalLoadedModels(descriptor.advertisedId.map { [$0] } ?? [])
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
        scannedGGUFModels = ggufScanner.scanAll()
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
        UserDefaults.standard.removeObject(forKey: Preferences.lastLoadedModelID)
        syncAdvertisedLoadedModels()
    }

    public func startServer() async {
        guard !isServerRunning else { return }
        isServerRunning = true
        let wanMgr = self.wanManager
        let clusterMgr = self.clusterManager
        let server = LocalHTTPServer(
            engine: engine,
            port: serverPort,
            apiKeyStore: apiKeyStore,
            allowNetworkAccess: allowNetworkAccess,
            controller: RemoteControlBridge(appState: self),
            peerModelProvider: {
                var models: [(id: String, ownedBy: String)] = []
                for peer in wanMgr.state.connectedPeers {
                    for model in peer.loadedModels {
                        models.append((id: model, ownedBy: "wan:\(peer.displayName)"))
                    }
                }
                for peer in await clusterMgr.topology.connectedPeers {
                    for model in peer.loadedModels {
                        models.append((id: model, ownedBy: "lan:\(peer.deviceInfo.name)"))
                    }
                }
                return models
            },
            onRequestCompleted: { [weak self] tokenCount in
                await MainActor.run {
                    self?.totalRequestsServed += 1
                    self?.totalTokensGenerated += tokenCount
                }
            }
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
            // Advertise the canonical OpenRouter slug when we have one so
            // the gateway's catalog + per-model fleet floor match this
            // device correctly. Skip advertisement for unrecognized
            // models rather than leaking a filesystem path or a
            // non-canonical HF repo id that no OpenRouter client will
            // match.
            if let advertised = descriptor.advertisedId {
                loadedModels = [advertised]
            } else {
                Self.wanLog("syncAdvertised: descriptor \(descriptor.id) has no openrouterId; skipping advertisement")
                loadedModels = []
            }
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

        // Refresh compiler's available models whenever local/peer models change
        Task { await refreshCompilerModels() }
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
        let lanIDs = Set(clusterManager.peerIDs().map(\.uuidString))
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
                        // Only surface relay failures — STUN failures are non-fatal (relay fallback works)
                        let relayFailures = diagnostics.filter { $0.contains("FAILED") && $0.contains("Relay") }
                        if !relayFailures.isEmpty {
                            self.wanLastError = relayFailures.joined(separator: "; ")
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
                if case .ready(let descriptor) = await MainActor.run(body: { self.engineStatus }),
                   let advertised = descriptor.advertisedId {
                    loadedModels = [advertised]
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
        case .llamaCpp:
            return llamaCppProvider
        }
    }

    private func buildActiveInferenceProvider() -> any InferenceProvider {
        var provider: any InferenceProvider = currentBaseProvider

        var clusterProvider: ClusterProvider?
        if clusterEnabled {
            let cp = ClusterProvider(
                localProvider: provider,
                clusterManager: clusterManager,
                onRemoteGenerationCompleted: { [weak self] record in
                    await self?.recordRemoteInferenceSettlement(record)
                }
            )
            clusterProvider = cp
            provider = cp
        }

        var wanProvider: WANProvider?
        if wanEnabled {
            let wp = WANProvider(localProvider: provider, wanManager: wanManager)
            wanProvider = wp
            provider = wp
        }

        // Wrap in Compiler for model-agnostic inference
        let localBase = currentBaseProvider
        let capturedClusterProvider = clusterProvider
        let capturedWANProvider = wanProvider
        let capturedWANManager = wanManager

        let dispatchFn: TargetedDispatchFn = { request, model in
            if model.deviceID == nil {
                // Local device
                return try await localBase.generateFull(request: request)
            }

            // Try LAN peer
            if let cp = capturedClusterProvider,
               let peer = await cp.peer(byID: model.deviceID!) {
                return try await cp.generateFull(onPeer: peer, request: request)
            }

            // Try WAN peer
            if let wp = capturedWANProvider {
                let nodeID = model.deviceID!.uuidString.lowercased()
                if capturedWANManager.connectedPeers(byNodeID: nodeID) != nil {
                    return try await wp.generateFull(onPeerNodeID: nodeID, request: request)
                }
            }

            // Peer not found — let the chain handle it
            throw CompilationError.subTaskFailed(subTaskID: UUID(), error: "Device \(model.deviceID?.uuidString ?? "unknown") not reachable")
        }

        let comp = Compiler(
            compilerProvider: localBase,
            fallbackProvider: provider,
            synthesisProvider: provider,
            dispatchFn: dispatchFn,
            onCompilationCompleted: { [weak self] contributions in
                await self?.recordCompilationContributions(contributions)
            }
        )
        self.compiler = comp
        provider = comp

        // Refresh available models for the compiler
        Task { [weak self] in
            await self?.refreshCompilerModels()
        }

        return provider
    }

    // MARK: - Compiler Model Refresh

    private func refreshCompilerModels() async {
        guard let compiler else { return }

        let localModel = await engine.loadedModel
        let lanPeers = Array(clusterManager.topology.connectedPeers)
        let wanPeers = wanManager.state.connectedPeers

        let models = NetworkModelCollector.collect(
            localModel: localModel,
            localHardware: hardware,
            lanPeers: lanPeers,
            wanPeers: wanPeers
        )

        await compiler.updateAvailableModels(models)
    }

    private func recordCompilationContributions(_ contributions: [ContributionRecord]) {
        // Log compilation contributions for future credit settlement
        for contribution in contributions {
            totalTokensGenerated += contribution.tokenCount
        }
    }

    private func applyInferenceBackendSelection() async {
        await exoProvider.updateConfiguration(
            baseURLString: exoBaseURL,
            preferredModelID: normalizedExoPreferredModelID
        )
        await llamaCppProvider.updateConfiguration(
            binaryPath: llamaCppBinaryPath
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

public enum AppAppearance: String, CaseIterable, Hashable, Identifiable, Sendable {
    case system
    case light
    case dark

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }
}

public enum InferenceBackend: String, CaseIterable, Hashable, Identifiable {
    case localMLX = "local_mlx"
    case llamaCpp = "llama_cpp"
    case exo = "exo"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .localMLX:
            return "Local MLX"
        case .llamaCpp:
            return "llama.cpp"
        case .exo:
            return "Exo Gateway"
        }
    }
}
