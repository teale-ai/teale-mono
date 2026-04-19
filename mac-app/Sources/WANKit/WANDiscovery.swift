import Foundation
import SharedTypes

// MARK: - WAN Peer Info

public struct WANPeerInfo: Codable, Sendable, Identifiable {
    public var id: String { nodeID }
    public var nodeID: String
    public var publicKey: String  // hex-encoded Ed25519 public key
    public var wgPublicKey: String?  // hex-encoded Curve25519 KeyAgreement public key for WireGuard
    public var displayName: String
    public var capabilities: NodeCapabilities
    public var lastSeen: Date
    public var natType: NATType
    public var endpoints: [PeerEndpoint]
    /// Organization/group ID for group-first routing (matches ClusterKit's organizationID)
    public var organizationID: String?

    public init(
        nodeID: String,
        publicKey: String,
        wgPublicKey: String? = nil,
        displayName: String,
        capabilities: NodeCapabilities,
        lastSeen: Date = Date(),
        natType: NATType = .unknown,
        endpoints: [PeerEndpoint] = [],
        organizationID: String? = nil
    ) {
        self.nodeID = nodeID
        self.publicKey = publicKey
        self.wgPublicKey = wgPublicKey
        self.displayName = displayName
        self.capabilities = capabilities
        self.lastSeen = lastSeen
        self.natType = natType
        self.endpoints = endpoints
        self.organizationID = organizationID
    }

    // Decode with defaults for fields the relay may not include (e.g. from cross-platform nodes)
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        nodeID = try container.decode(String.self, forKey: .nodeID)
        publicKey = try container.decode(String.self, forKey: .publicKey)
        wgPublicKey = try container.decodeIfPresent(String.self, forKey: .wgPublicKey)
        displayName = try container.decode(String.self, forKey: .displayName)
        capabilities = try container.decode(NodeCapabilities.self, forKey: .capabilities)
        lastSeen = try container.decodeIfPresent(Date.self, forKey: .lastSeen) ?? Date()
        natType = try container.decodeIfPresent(NATType.self, forKey: .natType) ?? .unknown
        endpoints = try container.decodeIfPresent([PeerEndpoint].self, forKey: .endpoints) ?? []
        organizationID = try container.decodeIfPresent(String.self, forKey: .organizationID)
    }

    /// Whether this peer has a specific model loaded
    public func hasModel(_ modelID: String) -> Bool {
        capabilities.loadedModels.contains(modelID)
    }

    /// Placeholder for peers discovered via offer before full discovery completes.
    public static func unknown(nodeID: String) -> WANPeerInfo {
        WANPeerInfo(
            nodeID: nodeID,
            publicKey: nodeID,
            displayName: "Unknown Peer",
            capabilities: NodeCapabilities(
                hardware: HardwareCapability(
                    chipFamily: .unknown,
                    chipName: "Unknown",
                    totalRAMGB: 0,
                    gpuCoreCount: 0,
                    memoryBandwidthGBs: 0,
                    tier: .tier4
                )
            )
        )
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
    private var discoveryPollTask: Task<Void, Never>?
    private var reregistrationTask: Task<Void, Never>?
    private var localCapabilities: NodeCapabilities?
    private var forceRediscoveryOnNextResponse: Bool = false

    /// Callback when a new peer is discovered
    public var onPeerDiscovered: ((WANPeerInfo) -> Void)?

    /// Callback when a peer leaves
    public var onPeerLeft: ((String) -> Void)?

    public init(relayClient: RelayClient, config: WANConfig) {
        self.relayClient = relayClient
        self.config = config
    }

    public func setCallbacks(
        onPeerDiscovered: ((WANPeerInfo) -> Void)?,
        onPeerLeft: ((String) -> Void)?
    ) {
        self.onPeerDiscovered = onPeerDiscovered
        self.onPeerLeft = onPeerLeft
    }

    // MARK: - Lifecycle

    /// Start discovery: register with relay and listen for peer events
    public func start(capabilities: NodeCapabilities) async throws {
        self.localCapabilities = capabilities

        // Register with the relay
        try await relayClient.register(capabilities: capabilities)

        // Re-register automatically after relay reconnects
        let caps = capabilities
        let relay = relayClient
        await relayClient.setOnReconnect { [weak self] in
            FileHandle.standardError.write(Data("[WAN] Re-registering with relay after reconnect...\n".utf8))
            try? await relay.register(capabilities: caps)
            await self?.setForceRediscovery(true)
            try? await relay.discover()
            FileHandle.standardError.write(Data("[WAN] Re-registration complete\n".utf8))
        }

        // Start listening for relay messages
        startMessageListener()

        // Periodic re-registration
        startReregistration(capabilities: capabilities)

        // Initial peer discovery
        try await relayClient.discover()

        // Periodic discovery polling (replaces broadcast-triggered discovery)
        startDiscoveryPolling()
    }

    public func setForceRediscovery(_ flag: Bool) {
        forceRediscoveryOnNextResponse = flag
    }

    /// Stop discovery
    public func stop() {
        discoveryTask?.cancel()
        discoveryTask = nil
        discoveryPollTask?.cancel()
        discoveryPollTask = nil
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

    public func setOnPeerDiscovered(_ handler: ((WANPeerInfo) -> Void)?) {
        onPeerDiscovered = handler
    }

    public func setOnPeerLeft(_ handler: ((String) -> Void)?) {
        onPeerLeft = handler
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
            let shouldForce = forceRediscoveryOnNextResponse
            forceRediscoveryOnNextResponse = false
            for peer in payload.peers {
                let isNew = knownPeers[peer.nodeID] == nil
                knownPeers[peer.nodeID] = peer
                if isNew || shouldForce {
                    onPeerDiscovered?(peer)
                }
            }

        case .peerJoined:
            // Deprecated: server no longer sends broadcasts.
            // Discovery is now poll-based (every 30s).
            break

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

    private func startDiscoveryPolling() {
        discoveryPollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard let self = self, !Task.isCancelled else { return }
                try? await self.relayClient.discover()
            }
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
