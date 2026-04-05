import Foundation
import SharedTypes

// MARK: - WAN Peer Info

public struct WANPeerInfo: Codable, Sendable, Identifiable {
    public var id: String { nodeID }
    public var nodeID: String
    public var publicKey: String  // hex-encoded Ed25519 public key
    public var displayName: String
    public var capabilities: NodeCapabilities
    public var lastSeen: Date
    public var natType: NATType
    public var endpoints: [PeerEndpoint]

    public init(
        nodeID: String,
        publicKey: String,
        displayName: String,
        capabilities: NodeCapabilities,
        lastSeen: Date = Date(),
        natType: NATType = .unknown,
        endpoints: [PeerEndpoint] = []
    ) {
        self.nodeID = nodeID
        self.publicKey = publicKey
        self.displayName = displayName
        self.capabilities = capabilities
        self.lastSeen = lastSeen
        self.natType = natType
        self.endpoints = endpoints
    }

    /// Whether this peer has a specific model loaded
    public func hasModel(_ modelID: String) -> Bool {
        capabilities.loadedModels.contains(modelID)
    }
}

// MARK: - Peer Endpoint

public struct PeerEndpoint: Codable, Sendable {
    public var ip: String
    public var port: UInt16
    public var type: EndpointType

    public enum EndpointType: String, Codable, Sendable {
        case publicIPv4
        case publicIPv6
        case localIPv4
        case relay
    }

    public init(ip: String, port: UInt16, type: EndpointType) {
        self.ip = ip
        self.port = port
        self.type = type
    }
}

// MARK: - WAN Discovery Service

public actor WANDiscoveryService {
    private let relayClient: RelayClient
    private let config: WANConfig
    private var knownPeers: [String: WANPeerInfo] = [:]  // nodeID -> info
    private var discoveryTask: Task<Void, Never>?
    private var reregistrationTask: Task<Void, Never>?
    private var localCapabilities: NodeCapabilities?

    /// Callback when a new peer is discovered
    public var onPeerDiscovered: ((WANPeerInfo) -> Void)?

    /// Callback when a peer leaves
    public var onPeerLeft: ((String) -> Void)?

    public init(relayClient: RelayClient, config: WANConfig) {
        self.relayClient = relayClient
        self.config = config
    }

    // MARK: - Lifecycle

    /// Start discovery: register with relay and listen for peer events
    public func start(capabilities: NodeCapabilities) async throws {
        self.localCapabilities = capabilities

        // Register with the relay
        try await relayClient.register(capabilities: capabilities)

        // Start listening for relay messages
        startMessageListener()

        // Periodic re-registration
        startReregistration(capabilities: capabilities)

        // Initial peer discovery
        try await relayClient.discover()
    }

    /// Stop discovery
    public func stop() {
        discoveryTask?.cancel()
        discoveryTask = nil
        reregistrationTask?.cancel()
        reregistrationTask = nil
        knownPeers.removeAll()
    }

    // MARK: - Peer Access

    /// All currently known WAN peers
    public var peers: [WANPeerInfo] {
        Array(knownPeers.values)
    }

    /// Find a peer by node ID
    public func peer(byNodeID nodeID: String) -> WANPeerInfo? {
        knownPeers[nodeID]
    }

    /// Filter peers by model availability
    public func peers(withModel modelID: String) -> [WANPeerInfo] {
        knownPeers.values.filter { $0.hasModel(modelID) }
    }

    /// Filter peers by minimum hardware capability
    public func peers(minRAMGB: Double) -> [WANPeerInfo] {
        knownPeers.values.filter { $0.capabilities.hardware.totalRAMGB >= minRAMGB }
    }

    /// Filter peers by availability and capability
    public func availablePeers(forModel modelID: String? = nil, minRAMGB: Double? = nil) -> [WANPeerInfo] {
        knownPeers.values.filter { peer in
            guard peer.capabilities.isAvailable else { return false }
            if let modelID = modelID, !peer.hasModel(modelID) { return false }
            if let minRAM = minRAMGB, peer.capabilities.hardware.totalRAMGB < minRAM { return false }
            return true
        }
    }

    /// Refresh peer list from relay
    public func refresh(filter: PeerFilter? = nil) async throws {
        try await relayClient.discover(filter: filter)
    }

    // MARK: - Private

    private func startMessageListener() {
        discoveryTask = Task { [weak self] in
            guard let self = self else { return }
            let messages = await self.relayClient.incomingMessages

            for await message in messages {
                guard !Task.isCancelled else { break }
                await self.handleRelayMessage(message)
            }
        }
    }

    private func handleRelayMessage(_ message: RelayMessage) {
        switch message {
        case .discoverResponse(let payload):
            for peer in payload.peers {
                let isNew = knownPeers[peer.nodeID] == nil
                knownPeers[peer.nodeID] = peer
                if isNew {
                    onPeerDiscovered?(peer)
                }
            }

        case .peerJoined(let payload):
            // A new peer registered — we may not have full info yet,
            // trigger a discovery refresh
            Task {
                try? await relayClient.discover()
            }
            _ = payload  // suppress unused warning

        case .peerLeft(let payload):
            knownPeers.removeValue(forKey: payload.nodeID)
            onPeerLeft?(payload.nodeID)

        case .registerAck:
            // Registration confirmed
            break

        default:
            break
        }
    }

    private func startReregistration(capabilities: NodeCapabilities) {
        reregistrationTask = Task { [weak self] in
            while !Task.isCancelled {
                // Re-register every 4 minutes (before 5-minute TTL expires)
                try? await Task.sleep(for: .seconds(240))
                guard let self = self, !Task.isCancelled else { return }
                let caps = await self.localCapabilities ?? capabilities
                try? await self.relayClient.register(capabilities: caps)
            }
        }
    }

    /// Update local capabilities (e.g., when a model is loaded/unloaded)
    public func updateCapabilities(_ capabilities: NodeCapabilities) async throws {
        self.localCapabilities = capabilities
        try await relayClient.register(capabilities: capabilities)
    }

    /// Remove stale peers that haven't been seen recently
    public func pruneStale(olderThan interval: TimeInterval = 600) {
        let cutoff = Date().addingTimeInterval(-interval)
        let staleIDs = knownPeers.filter { $0.value.lastSeen < cutoff }.map { $0.key }
        for id in staleIDs {
            knownPeers.removeValue(forKey: id)
            onPeerLeft?(id)
        }
    }
}
