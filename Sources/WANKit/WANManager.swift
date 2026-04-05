import Foundation
import Network
import SharedTypes
import HardwareProfile
import ClusterKit

// MARK: - WAN State (for UI)

public struct WANState: Sendable {
    public var isEnabled: Bool
    public var connectedPeers: [WANPeerSummary]
    public var relayStatus: RelayStatus
    public var publicEndpoint: NATMapping?
    public var natType: NATType
    public var discoveredPeerCount: Int

    public init(
        isEnabled: Bool = false,
        connectedPeers: [WANPeerSummary] = [],
        relayStatus: RelayStatus = .disconnected,
        publicEndpoint: NATMapping? = nil,
        natType: NATType = .unknown,
        discoveredPeerCount: Int = 0
    ) {
        self.isEnabled = isEnabled
        self.connectedPeers = connectedPeers
        self.relayStatus = relayStatus
        self.publicEndpoint = publicEndpoint
        self.natType = natType
        self.discoveredPeerCount = discoveredPeerCount
    }
}

// MARK: - WAN Peer Summary (lightweight for UI)

public struct WANPeerSummary: Sendable, Identifiable {
    public var id: String  // nodeID
    public var displayName: String
    public var hardware: HardwareCapability
    public var connectionType: WANConnectionType
    public var loadedModels: [String]
    public var latencyMs: Double?
    public var lastSeen: Date

    public init(
        id: String,
        displayName: String,
        hardware: HardwareCapability,
        connectionType: WANConnectionType,
        loadedModels: [String] = [],
        latencyMs: Double? = nil,
        lastSeen: Date = Date()
    ) {
        self.id = id
        self.displayName = displayName
        self.hardware = hardware
        self.connectionType = connectionType
        self.loadedModels = loadedModels
        self.latencyMs = latencyMs
        self.lastSeen = lastSeen
    }
}

public enum WANConnectionType: String, Sendable {
    case direct     // Direct QUIC P2P connection
    case relayed    // Via relay server
}

// MARK: - Connected WAN Peer (internal)

struct ConnectedWANPeer: Sendable {
    var peerInfo: WANPeerInfo
    var connection: WANPeerConnection
    var connectionType: WANConnectionType
    var lastHeartbeat: Date
    var latencyMs: Double?
}

// MARK: - WAN Manager

@Observable
public final class WANManager: @unchecked Sendable {
    // Public state
    public private(set) var state: WANState = WANState()
    public private(set) var isEnabled: Bool = false

    // Configuration
    private var config: WANConfig?
    private var localDeviceInfo: DeviceInfo?

    // Components
    private var relayClient: RelayClient?
    private var stunClient: STUNClient?
    private var discoveryService: WANDiscoveryService?
    private var natTraversal: NATTraversal?
    private var listener: NWListener?

    // Connections
    private var connectedPeers: [String: ConnectedWANPeer] = [:]  // nodeID -> peer

    // Tasks
    private var heartbeatTask: Task<Void, Never>?
    private var healthCheckTask: Task<Void, Never>?
    private var relayListenerTask: Task<Void, Never>?
    private var listenerTask: Task<Void, Never>?

    // Callbacks
    public var onInferenceRequest: ((InferenceRequestPayload, WANPeerConnection) async -> Void)?

    public init() {}

    // MARK: - Enable / Disable

    public func enable(config: WANConfig, localDeviceInfo: DeviceInfo) async throws {
        guard !isEnabled else { return }

        self.config = config
        self.localDeviceInfo = localDeviceInfo

        // Create components
        let relay = RelayClient(config: config)
        let stun = STUNClient(stunServers: config.stunServerURLs)
        let discovery = WANDiscoveryService(relayClient: relay, config: config)
        let nat = NATTraversal(
            stunClient: stun,
            relayClient: relay,
            identity: config.identity,
            timeoutSeconds: config.connectionTimeoutSeconds
        )

        self.relayClient = relay
        self.stunClient = stun
        self.discoveryService = discovery
        self.natTraversal = nat

        // Connect to relay
        try await relay.connect()

        // Discover public endpoint
        let mapping: NATMapping?
        do {
            mapping = try await stun.discoverMapping()
        } catch {
            mapping = nil
        }

        // Detect NAT type
        let natType: NATType
        do {
            natType = try await stun.detectNATType()
        } catch {
            natType = .unknown
        }

        // Start QUIC listener for incoming P2P connections
        do {
            let quicListener = try QUICTransport.createListener(
                port: mapping.map { $0.publicPort } ?? 0,
                identity: config.identity
            )
            self.listener = quicListener
            startQUICListener(quicListener)
        } catch {
            // Non-fatal — we can still make outgoing connections
        }

        // Register and start discovery
        let capabilities = NodeCapabilities(
            hardware: localDeviceInfo.hardware,
            loadedModels: localDeviceInfo.loadedModels,
            maxModelSizeGB: localDeviceInfo.hardware.availableRAMForModelsGB,
            isAvailable: true
        )
        try await discovery.start(capabilities: capabilities)

        // Start relay message listener for offers/answers
        startRelayListener()

        // Start heartbeat and health check loops
        startHeartbeatLoop()
        startHealthCheckLoop()

        isEnabled = true
        updateState(mapping: mapping, natType: natType)
    }

    public func disable() async {
        guard isEnabled else { return }
        isEnabled = false

        // Cancel all tasks
        heartbeatTask?.cancel()
        healthCheckTask?.cancel()
        relayListenerTask?.cancel()
        listenerTask?.cancel()

        // Disconnect all peers
        for (_, peer) in connectedPeers {
            await peer.connection.cancel()
        }
        connectedPeers.removeAll()

        // Stop components
        await discoveryService?.stop()
        await relayClient?.disconnect()
        listener?.cancel()

        // Clear references
        relayClient = nil
        stunClient = nil
        discoveryService = nil
        natTraversal = nil
        listener = nil

        updateState(mapping: nil, natType: .unknown)
    }

    // MARK: - Peer Connection

    /// Connect to a discovered WAN peer
    public func connectToPeer(_ peerInfo: WANPeerInfo) async throws {
        guard let nat = natTraversal, let config = config else {
            throw WANError.peerConnectionFailed("WAN not enabled")
        }

        // Check if already connected
        guard connectedPeers[peerInfo.nodeID] == nil else { return }

        // Check peer limit
        guard connectedPeers.count < config.maxWANPeers else {
            throw WANError.peerConnectionFailed("Maximum WAN peer limit reached")
        }

        let sessionID = UUID().uuidString
        let result = try await nat.connectToPeer(peerInfo: peerInfo, sessionID: sessionID)

        switch result {
        case .direct(let connection):
            let connected = ConnectedWANPeer(
                peerInfo: peerInfo,
                connection: connection,
                connectionType: .direct,
                lastHeartbeat: Date()
            )
            connectedPeers[peerInfo.nodeID] = connected
            startListening(to: connected)

        case .relayed(let connection):
            let connected = ConnectedWANPeer(
                peerInfo: peerInfo,
                connection: connection,
                connectionType: .relayed,
                lastHeartbeat: Date()
            )
            connectedPeers[peerInfo.nodeID] = connected
            startListening(to: connected)

        case .failed(let error):
            throw error
        }

        updateState(mapping: state.publicEndpoint, natType: state.natType)
    }

    /// Disconnect from a WAN peer
    public func disconnectPeer(_ nodeID: String) async {
        if let peer = connectedPeers.removeValue(forKey: nodeID) {
            await peer.connection.cancel()
        }
        updateState(mapping: state.publicEndpoint, natType: state.natType)
    }

    /// Get all connected peers
    public var connectedPeerSummaries: [WANPeerSummary] {
        connectedPeers.values.map { peer in
            WANPeerSummary(
                id: peer.peerInfo.nodeID,
                displayName: peer.peerInfo.displayName,
                hardware: peer.peerInfo.capabilities.hardware,
                connectionType: peer.connectionType,
                loadedModels: peer.peerInfo.capabilities.loadedModels,
                latencyMs: peer.latencyMs,
                lastSeen: peer.lastHeartbeat
            )
        }
    }

    /// Get all discovered peers (including not-yet-connected)
    public func discoveredPeers() async -> [WANPeerInfo] {
        await discoveryService?.peers ?? []
    }

    /// Find connected peer with a specific model loaded
    func connectedPeer(withModel modelID: String) -> ConnectedWANPeer? {
        connectedPeers.values.first { $0.peerInfo.hasModel(modelID) }
    }

    /// Check if any connected peer has a given model
    public func hasConnectedPeer(withModel modelID: String) -> Bool {
        connectedPeers.values.contains { $0.peerInfo.hasModel(modelID) }
    }

    /// Get the WANPeerConnection for a connected peer with the given model
    public func connectionForPeer(withModel modelID: String) -> WANPeerConnection? {
        connectedPeers.values.first { $0.peerInfo.hasModel(modelID) }?.connection
    }

    // MARK: - Message Handling

    private func startListening(to peer: ConnectedWANPeer) {
        Task {
            let messages = await peer.connection.incomingMessages
            for await message in messages {
                await handleMessage(message, from: peer)
            }
            // Connection ended
            connectedPeers.removeValue(forKey: peer.peerInfo.nodeID)
            updateState(mapping: state.publicEndpoint, natType: state.natType)
        }
    }

    private func handleMessage(_ message: ClusterMessage, from peer: ConnectedWANPeer) async {
        switch message {
        case .heartbeat(let payload):
            connectedPeers[peer.peerInfo.nodeID]?.lastHeartbeat = Date()
            connectedPeers[peer.peerInfo.nodeID]?.peerInfo.capabilities.loadedModels = payload.loadedModels

            // Send ack
            let ack = HeartbeatPayload(
                deviceID: localDeviceInfo?.id ?? UUID(),
                timestamp: Date()
            )
            try? await peer.connection.send(.heartbeatAck(ack))

        case .heartbeatAck:
            connectedPeers[peer.peerInfo.nodeID]?.lastHeartbeat = Date()

        case .inferenceRequest(let payload):
            await onInferenceRequest?(payload, peer.connection)

        case .inferenceChunk, .inferenceComplete, .inferenceError:
            // Handled by WANProvider
            break

        default:
            break
        }
    }

    // MARK: - Relay Listener (handles incoming offers)

    private func startRelayListener() {
        relayListenerTask = Task { [weak self] in
            guard let self = self, let relay = self.relayClient else { return }
            let messages = await relay.incomingMessages

            for await message in messages {
                guard !Task.isCancelled else { break }

                switch message {
                case .offer(let offer):
                    await self.handleIncomingOffer(offer)
                default:
                    break
                }
            }
        }
    }

    private func handleIncomingOffer(_ offer: RelayMessage.OfferPayload) async {
        guard let nat = natTraversal, let config = config else { return }

        // Check peer limit
        guard connectedPeers.count < config.maxWANPeers else { return }

        // Don't accept if already connected
        guard connectedPeers[offer.fromNodeID] == nil else { return }

        do {
            let connection = try await nat.handleIncomingOffer(offer: offer)

            // Look up peer info from discovery
            let peerInfo = await discoveryService?.peer(byNodeID: offer.fromNodeID) ?? WANPeerInfo(
                nodeID: offer.fromNodeID,
                publicKey: offer.fromNodeID,
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

            let connected = ConnectedWANPeer(
                peerInfo: peerInfo,
                connection: connection,
                connectionType: .direct,
                lastHeartbeat: Date()
            )
            connectedPeers[offer.fromNodeID] = connected
            startListening(to: connected)
            updateState(mapping: state.publicEndpoint, natType: state.natType)
        } catch {
            // Failed to accept incoming connection
        }
    }

    // MARK: - QUIC Listener

    private func startQUICListener(_ listener: NWListener) {
        listenerTask = Task { [weak self] in
            listener.newConnectionHandler = { [weak self] connection in
                Task { await self?.handleIncomingQUICConnection(connection) }
            }
            listener.start(queue: .global(qos: .userInitiated))
        }
    }

    private func handleIncomingQUICConnection(_ nwConnection: NWConnection) async {
        guard let config = config else { return }
        guard connectedPeers.count < config.maxWANPeers else {
            nwConnection.cancel()
            return
        }

        let peerConn = WANPeerConnection(connection: nwConnection, remoteNodeID: "pending")
        await peerConn.start()

        let isReady = await peerConn.isReady
        guard isReady else {
            await peerConn.cancel()
            return
        }

        // The first message should identify the peer
        // For now, accept and wait for identification via heartbeat
    }

    // MARK: - Heartbeat Loop

    private func startHeartbeatLoop() {
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                let interval = self?.config?.heartbeatIntervalSeconds ?? 15
                try? await Task.sleep(for: .seconds(interval))
                guard let self = self else { return }

                let heartbeat = HeartbeatPayload(
                    deviceID: self.localDeviceInfo?.id ?? UUID(),
                    timestamp: Date(),
                    loadedModels: self.localDeviceInfo?.loadedModels ?? [],
                    isGenerating: false
                )

                for (_, peer) in self.connectedPeers {
                    try? await peer.connection.send(.heartbeat(heartbeat))
                }
            }
        }
    }

    // MARK: - Health Check Loop

    private func startHealthCheckLoop() {
        healthCheckTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard let self = self else { return }

                let now = Date()
                var disconnected: [String] = []

                for (nodeID, peer) in self.connectedPeers {
                    let secondsSinceHeartbeat = now.timeIntervalSince(peer.lastHeartbeat)
                    if secondsSinceHeartbeat > 90 {
                        // Peer is dead
                        await peer.connection.cancel()
                        disconnected.append(nodeID)
                    }
                }

                for nodeID in disconnected {
                    self.connectedPeers.removeValue(forKey: nodeID)
                }

                if !disconnected.isEmpty {
                    self.updateState(mapping: self.state.publicEndpoint, natType: self.state.natType)
                }

                // Prune stale discovered peers
                await self.discoveryService?.pruneStale()
            }
        }
    }

    // MARK: - State Updates

    private func updateState(mapping: NATMapping?, natType: NATType) {
        let summaries = connectedPeerSummaries

        state = WANState(
            isEnabled: isEnabled,
            connectedPeers: summaries,
            relayStatus: .disconnected,  // Updated async below
            publicEndpoint: mapping,
            natType: natType,
            discoveredPeerCount: 0  // Updated async below
        )

        // Update relay status and discovered count asynchronously
        Task { @MainActor [weak self] in
            guard let self = self else { return }
            let relayStatus = await self.relayClient?.relayStatus ?? .disconnected
            let peerCount = await self.discoveryService?.peers.count ?? 0
            self.state.relayStatus = relayStatus
            self.state.discoveredPeerCount = peerCount
        }
    }
}
