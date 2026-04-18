import Foundation
import SharedTypes
import Network
import Observation
import AuthKit
import HardwareProfile
import MLXInference
import ModelManager
import InferenceEngine
import WANKit
import ChatKit

// MARK: - Connection Status

enum ConnectionStatus: Sendable {
    case disconnected
    case connecting
    case connected(nodeName: String)
    case error(String)

    var isConnected: Bool {
        if case .connected = self { return true }
        return false
    }

    var displayText: String {
        switch self {
        case .disconnected: return "Disconnected"
        case .connecting: return "Connecting..."
        case .connected(let name): return "Connected to \(name)"
        case .error(let msg): return "Error: \(msg)"
        }
    }
}

// MARK: - Inference Mode

enum InferenceMode: String, CaseIterable {
    case local = "On-Device"
    case remote = "Remote"
}

// MARK: - Discovered Node

struct DiscoveredNode: Identifiable, Sendable {
    var id: String
    var name: String
    var host: String
    var port: UInt16
    var isLAN: Bool
    var chipName: String?
    var totalRAMGB: Double?
    var loadedModel: String?
    var connectionQuality: ConnectionQuality?
    var lastSeen: Date

    init(
        id: String = UUID().uuidString,
        name: String,
        host: String,
        port: UInt16 = 11435,
        isLAN: Bool = true,
        chipName: String? = nil,
        totalRAMGB: Double? = nil,
        loadedModel: String? = nil,
        connectionQuality: ConnectionQuality? = nil,
        lastSeen: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.host = host
        self.port = port
        self.isLAN = isLAN
        self.chipName = chipName
        self.totalRAMGB = totalRAMGB
        self.loadedModel = loadedModel
        self.connectionQuality = connectionQuality
        self.lastSeen = lastSeen
    }
}

// MARK: - Transaction

struct WalletTransaction: Identifiable {
    var id: UUID = UUID()
    var date: Date
    var amount: Double
    var description: String
    var isEarning: Bool
}

// MARK: - Companion App State

@Observable
final class CompanionAppState {
    // Auth (initialized lazily on MainActor in initialize())
    var authManager: AuthManager?

    // Hardware
    let hardware: HardwareCapability
    let modelManager: ModelManagerService

    // Local inference
    let localProvider = MLXProvider()
    var inferenceMode: InferenceMode = .local
    var localModel: ModelDescriptor?
    var isLoadingModel: Bool = false
    var loadingPhase: String = ""
    var loadingProgress: Double?
    var isGenerating: Bool = false
    var downloadedModelIDs: Set<String> = []
    var activeDownloads: [String: Double] = [:]

    // Remote connection
    var connectionStatus: ConnectionStatus = .disconnected
    var discoveredNodes: [DiscoveredNode] = []
    var connectedNode: DiscoveredNode?

    // Models
    var availableModels: [String] = []
    var selectedModel: String?

    // Chat (legacy single-user)
    var conversationStore = CompanionConversationStore()

    // Group Chat (ChatKit)
    var chatService: ChatService?
    var currentUserID: UUID = UUID()

    // Wallet
    var walletBalance: Double = 0.0
    var transactions: [WalletTransaction] = []

    // Settings
    var displayName: String = "My iPhone"
    var preferredNode: String? // nil = auto
    var wanRelayURL: String = "wss://relay.teale.com/ws"

    // WAN P2P
    let wanManager = WANManager()
    var wanEnabled: Bool = false {
        didSet {
            guard !isUpdatingWANToggle else { return }
            toggleWAN()
        }
    }
    var isWANBusy: Bool = false
    var wanLastError: String?
    private var isUpdatingWANToggle: Bool = false

    // Network discovery
    private var browser: NWBrowser?
    private var client = RemoteInferenceClient()

    @MainActor
    init() {
        let hw = HardwareDetector().detect()
        self.hardware = hw
        self.modelManager = ModelManagerService(hardware: hw, maxStorageGB: 20.0)

        // Migrate stale relay URLs from previous versions
        if wanRelayURL.contains("teale.network") || wanRelayURL.isEmpty {
            wanRelayURL = "wss://relay.teale.com/ws"
        }
    }

    /// Whether inference is available (local model loaded or remote connected)
    var canInfer: Bool {
        switch inferenceMode {
        case .local: return localModel != nil
        case .remote: return connectionStatus.isConnected
        }
    }

    // MARK: - Initialization

    @MainActor
    func initialize() async {
        if let config = SupabaseConfig.default {
            let manager = AuthManager(config: config)
            self.authManager = manager
            await manager.checkSession()

            // Initialize ChatKit after auth
            if let user = manager.currentUser {
                currentUserID = user.id
                let service = ChatService(currentUserID: user.id, localNodeID: UUID().uuidString)
                // Wire inference for AI agent responses
                service.aiParticipant.onInferenceRequest = { [weak self] request in
                    guard let self else {
                        return AsyncThrowingStream { $0.finish() }
                    }
                    return self.createInferenceStream(for: request)
                }
                self.chatService = service
            }
        }

        // Scan for already-downloaded models
        await refreshDownloadedModels()

        // Start network discovery in background
        await startDiscovery()
    }

    /// Create an inference stream routing to local MLX or remote Mac node
    private func createInferenceStream(for request: ChatCompletionRequest) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            Task { @MainActor [weak self] in
                guard let self else {
                    continuation.finish()
                    return
                }
                do {
                    switch self.inferenceMode {
                    case .local:
                        guard self.localModel != nil else {
                            continuation.finish(throwing: NSError(domain: "ChatKit", code: 0, userInfo: [NSLocalizedDescriptionKey: "No local model loaded"]))
                            return
                        }
                        let stream = self.localProvider.generate(request: request)
                        for try await chunk in stream {
                            if let content = chunk.choices.first?.delta.content {
                                continuation.yield(content)
                            }
                        }
                        continuation.finish()
                    case .remote:
                        guard self.connectionStatus.isConnected else {
                            continuation.finish(throwing: NSError(domain: "ChatKit", code: 0, userInfo: [NSLocalizedDescriptionKey: "Not connected to a Mac node"]))
                            return
                        }
                        for try await token in self.client.streamCompletion(request: request) {
                            continuation.yield(token)
                        }
                        continuation.finish()
                    }
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    // MARK: - Local Model Management

    @MainActor
    func downloadModel(_ descriptor: ModelDescriptor) async {
        activeDownloads[descriptor.id] = 0.0
        do {
            try await modelManager.downloadModel(descriptor)
            activeDownloads.removeValue(forKey: descriptor.id)
            await refreshDownloadedModels()
        } catch {
            activeDownloads.removeValue(forKey: descriptor.id)
        }
    }

    @MainActor
    func loadLocalModel(_ descriptor: ModelDescriptor) async {
        isLoadingModel = true
        loadingPhase = "Preparing..."
        loadingProgress = 0

        do {
            try await localProvider.loadModel(descriptor) { [weak self] progress in
                Task { @MainActor in
                    self?.loadingPhase = progress.phase.rawValue
                    self?.loadingProgress = progress.fractionCompleted
                }
            }

            localModel = descriptor
            selectedModel = descriptor.name
            inferenceMode = .local
            isLoadingModel = false
            loadingPhase = ""
            loadingProgress = nil
        } catch {
            isLoadingModel = false
            loadingPhase = ""
            loadingProgress = nil
        }
    }

    @MainActor
    func unloadLocalModel() async {
        await localProvider.unloadModel()
        localModel = nil
        if inferenceMode == .local {
            selectedModel = nil
        }
    }

    @MainActor
    func refreshDownloadedModels() async {
        var ids = Set<String>()
        for model in modelManager.compatibleModels {
            if await modelManager.isDownloaded(model) {
                ids.insert(model.id)
            }
        }
        downloadedModelIDs = ids
    }

    // MARK: - Discovery

    func startDiscovery() async {
        let browser = NWBrowser(for: .bonjour(type: "_teale._tcp", domain: "local."), using: .tcp)

        browser.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                break
            case .failed(let error):
                Task { @MainActor in
                    self?.connectionStatus = .error("Discovery failed: \(error.localizedDescription)")
                }
            default:
                break
            }
        }

        browser.browseResultsChangedHandler = { [weak self] results, _ in
            Task { @MainActor in
                self?.handleBrowseResults(results)
            }
        }

        self.browser = browser
        browser.start(queue: .main)
    }

    func stopDiscovery() {
        browser?.cancel()
        browser = nil
    }

    @MainActor
    private func handleBrowseResults(_ results: Set<NWBrowser.Result>) {
        var nodes: [DiscoveredNode] = []
        for result in results {
            switch result.endpoint {
            case .service(let name, let type, let domain, _):
                let node = DiscoveredNode(
                    id: "\(name).\(type).\(domain)",
                    name: name,
                    host: name,
                    port: 11435,
                    isLAN: true,
                    lastSeen: Date()
                )
                nodes.append(node)
            default:
                break
            }
        }
        self.discoveredNodes = nodes
    }

    // MARK: - Remote Connection

    @MainActor
    func connect(to node: DiscoveredNode) async {
        connectionStatus = .connecting
        client.configure(host: node.host, port: node.port)

        do {
            let models = try await client.fetchModels()
            availableModels = models
            if selectedModel == nil, let first = models.first {
                selectedModel = first
            }
            connectedNode = node
            connectionStatus = .connected(nodeName: node.name)
        } catch {
            connectionStatus = .error(error.localizedDescription)
        }
    }

    @MainActor
    func disconnect() {
        client.disconnect()
        connectedNode = nil
        connectionStatus = .disconnected
        availableModels = []
    }

    @MainActor
    func refreshModels() async {
        guard connectionStatus.isConnected else { return }
        do {
            let models = try await client.fetchModels()
            availableModels = models
        } catch {
            // Keep existing models on refresh failure
        }
    }

    // MARK: - Chat (dual-mode: local or remote)

    @MainActor
    func sendMessage(_ content: String) async {
        let conversation = conversationStore.activeConversation
        ?? conversationStore.createConversation(title: String(content.prefix(40)))
        conversationStore.activeConversation = conversation

        let userMessage = CompanionMessage(role: .user, content: content)
        conversationStore.addMessage(userMessage, to: conversation.id)

        let assistantMessage = CompanionMessage(role: .assistant, content: "")
        conversationStore.addMessage(assistantMessage, to: conversation.id)

        // Build API messages from conversation history
        let messages = conversationStore.messages(for: conversation.id).compactMap { msg -> APIMessage? in
            guard msg.id != assistantMessage.id else { return nil }
            return APIMessage(role: msg.role.rawValue, content: msg.content)
        }

        let request = ChatCompletionRequest(
            model: selectedModel,
            messages: messages,
            stream: true
        )

        switch inferenceMode {
        case .local:
            await sendLocalMessage(request: request, assistantMessage: assistantMessage, conversationID: conversation.id)
        case .remote:
            await sendRemoteMessage(request: request, assistantMessage: assistantMessage, conversationID: conversation.id)
        }
    }

    // MARK: - Local Generation

    @MainActor
    private func sendLocalMessage(request: ChatCompletionRequest, assistantMessage: CompanionMessage, conversationID: UUID) async {
        guard localModel != nil else { return }
        isGenerating = true

        do {
            let stream = localProvider.generate(request: request)
            for try await chunk in stream {
                if let content = chunk.choices.first?.delta.content {
                    conversationStore.appendToMessage(assistantMessage.id, in: conversationID, content: content)
                }
            }
        } catch {
            conversationStore.appendToMessage(
                assistantMessage.id,
                in: conversationID,
                content: "\n\n[Error: \(error.localizedDescription)]"
            )
        }

        isGenerating = false
    }

    // MARK: - Remote Generation

    @MainActor
    private func sendRemoteMessage(request: ChatCompletionRequest, assistantMessage: CompanionMessage, conversationID: UUID) async {
        guard connectionStatus.isConnected else { return }

        do {
            for try await token in client.streamCompletion(request: request) {
                conversationStore.appendToMessage(assistantMessage.id, in: conversationID, content: token)
            }
        } catch {
            conversationStore.appendToMessage(
                assistantMessage.id,
                in: conversationID,
                content: "\n\n[Error: \(error.localizedDescription)]"
            )
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

        let hw = hardware
        let name = displayName
        let loadedModels = localModel.map { [$0.huggingFaceRepo] } ?? []

        Task.detached { [weak self] in
            do {
                let identity = try WANNodeIdentity.loadOrCreate()
                let config = WANConfig(
                    relayServerURLs: [relayURL],
                    identity: identity,
                    displayName: name
                )
                let deviceInfo = DeviceInfo(
                    name: name,
                    hardware: hw,
                    loadedModels: loadedModels
                )

                guard let self else { return }
                try await self.wanManager.enable(config: config, localDeviceInfo: deviceInfo)

                // Check relay status and sync loaded models
                let relayStatus = self.wanManager.state.relayStatus
                let diagnostics = self.wanManager.enableDiagnostics

                await MainActor.run {
                    self.isWANBusy = false
                    if relayStatus == .connected {
                        self.wanLastError = nil
                    } else {
                        let failedSteps = diagnostics.filter { $0.contains("FAILED") }
                        self.wanLastError = failedSteps.isEmpty
                            ? "Relay not connected (\(relayStatus.rawValue))"
                            : failedSteps.joined(separator: "; ")
                    }
                    self.syncWANPeers()
                }

                // Sync loaded models to WAN (model may have loaded before WAN was enabled)
                let currentModels: [String] = await MainActor.run {
                    self.localModel.map { [$0.huggingFaceRepo] } ?? []
                }
                await self.wanManager.updateLocalLoadedModels(currentModels)

                // Periodically sync WAN peers into discoveredNodes
                while !Task.isCancelled {
                    try await Task.sleep(for: .seconds(5))
                    await MainActor.run { [weak self] in
                        self?.syncWANPeers()
                    }
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
            }
        }
    }

    private func disableWAN(clearError: Bool = true) {
        isWANBusy = false
        if clearError {
            wanLastError = nil
        }
        discoveredNodes.removeAll { !$0.isLAN }
        Task {
            await wanManager.disable()
        }
    }

    @MainActor
    private func syncWANPeers() {
        let wanState = wanManager.state
        discoveredNodes.removeAll { !$0.isLAN }
        for peer in wanState.connectedPeers {
            let node = DiscoveredNode(
                id: peer.id,
                name: peer.displayName,
                host: peer.id,
                port: 0,
                isLAN: false,
                chipName: peer.hardware.chipName,
                totalRAMGB: peer.hardware.totalRAMGB,
                loadedModel: peer.loadedModels.first,
                lastSeen: peer.lastSeen
            )
            discoveredNodes.append(node)
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
}
