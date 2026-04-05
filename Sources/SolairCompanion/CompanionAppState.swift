import Foundation
import SharedTypes
import Network
import Observation

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
    // Connection
    var connectionStatus: ConnectionStatus = .disconnected
    var discoveredNodes: [DiscoveredNode] = []
    var connectedNode: DiscoveredNode?

    // Models
    var availableModels: [String] = []
    var selectedModel: String?

    // Chat
    var conversationStore = CompanionConversationStore()

    // Wallet
    var walletBalance: Double = 0.0
    var transactions: [WalletTransaction] = []

    // Settings
    var displayName: String = "My iPhone"
    var preferredNode: String? // nil = auto
    var wanRelayURL: String = ""

    // Network discovery
    private var browser: NWBrowser?
    private var client = RemoteInferenceClient()

    // MARK: - Discovery

    func startDiscovery() async {
        let browser = NWBrowser(for: .bonjour(type: "_inferencepool._tcp", domain: "local."), using: .tcp)

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

    // MARK: - Connection

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

    // MARK: - Chat

    @MainActor
    func sendMessage(_ content: String) async {
        guard connectionStatus.isConnected else { return }

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

        do {
            for try await token in client.streamCompletion(request: request) {
                conversationStore.appendToMessage(assistantMessage.id, in: conversation.id, content: token)
            }
        } catch {
            conversationStore.appendToMessage(
                assistantMessage.id,
                in: conversation.id,
                content: "\n\n[Error: \(error.localizedDescription)]"
            )
        }
    }
}
