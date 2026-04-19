import Foundation
import Network
import SharedTypes
import HardwareProfile
import ClusterKit

// MARK: - WAN State (for UI)

public struct WANState: Sendable {
    public var isEnabled: Bool
    public var connectedPeers: [WANPeerSummary]
    public var discoveredPeers: [WANPeerInfo]
    public var relayStatus: RelayStatus
    public var publicEndpoint: NATMapping?
    public var natType: NATType
    public var discoveredPeerCount: Int
    /// Diagnostic log of the last enable() attempt — each step's result.
    public var diagnostics: [String]

    public init(
        isEnabled: Bool = false,
        connectedPeers: [WANPeerSummary] = [],
        discoveredPeers: [WANPeerInfo] = [],
        relayStatus: RelayStatus = .disconnected,
        publicEndpoint: NATMapping? = nil,
        natType: NATType = .unknown,
        discoveredPeerCount: Int = 0,
        diagnostics: [String] = []
    ) {
        self.isEnabled = isEnabled
        self.connectedPeers = connectedPeers
        self.discoveredPeers = discoveredPeers
        self.relayStatus = relayStatus
        self.publicEndpoint = publicEndpoint
        self.natType = natType
        self.discoveredPeerCount = discoveredPeerCount
        self.diagnostics = diagnostics
    }

    /// Human-readable summary of connection health.
    public var statusSummary: String {
        if !isEnabled { return "Disabled" }
        switch relayStatus {
        case .connected:
            if connectedPeers.isEmpty {
                return discoveredPeerCount > 0
                    ? "Relay connected, \(discoveredPeerCount) peers discovered (connecting...)"
                    : "Relay connected, waiting for peers"
            }
            return "Connected to \(connectedPeers.count) peer(s)"
        case .connecting:
            return "Connecting to relay..."
        case .reconnecting:
            return "Reconnecting to relay..."
        case .disconnected:
            return "Relay disconnected — peers cannot discover this node"
        }
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
    case direct     // Direct WireGuard P2P connection
    case relayed    // Via relay server
}

// MARK: - Connected WAN Peer (internal)

struct ConnectedWANPeer: Sendable {
    var peerInfo: WANPeerInfo
    var connection: WANTransportConnection
    var connectionType: WANConnectionType
    var lastHeartbeat: Date
    var latencyMs: Double?
    var consecutiveHeartbeatFailures: Int = 0

    /// Quality score (0-100) for routing decisions. Higher is better.
    var qualityScore: Double {
        var score: Double = 50

        // Latency: lower is better (0-30 points)
        if let latency = latencyMs {
            if latency < 50 { score += 30 }
            else if latency < 150 { score += 20 }
            else if latency < 500 { score += 10 }
        }

        // Connection type: direct is better (0-20 points)
        if connectionType == .direct { score += 20 }

        // RAM: more is better (0-20 points)
        let ram = peerInfo.capabilities.hardware.totalRAMGB
        if ram >= 64 { score += 20 }
        else if ram >= 32 { score += 15 }
        else if ram >= 16 { score += 10 }
        else if ram >= 8 { score += 5 }

        // Has models loaded (0-10 points)
        if !peerInfo.capabilities.loadedModels.isEmpty { score += 10 }

        // Freshness penalty
        let staleness = Date().timeIntervalSince(lastHeartbeat)
        if staleness > 60 { score -= 20 }
        else if staleness > 30 { score -= 10 }

        return max(0, min(100, score))
    }
}

// MARK: - WAN Manager

@Observable
public final class WANManager: @unchecked Sendable {
    // Public state
    public private(set) var state: WANState = WANState()
    public private(set) var isEnabled: Bool = false
    /// Diagnostic log from the last enable() call
    public private(set) var enableDiagnostics: [String] = []

    // Configuration
    private var config: WANConfig?
    private var localDeviceInfo: DeviceInfo?
    /// PTN memberships for this node, broadcast via discovery capabilities.
    public var localPTNIDs: [PTNIdentifier] = []

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
    public var onInferenceRequest: ((InferenceRequestPayload, WANTransportConnection) async -> Void)?
    public var onPTNJoinRequest: ((PTNJoinRequestTransportPayload, WANTransportConnection) async -> Void)?

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

        await discovery.setCallbacks(
            onPeerDiscovered: { [weak self] peer in
                Task {
                    await self?.handleDiscoveredPeer(peer)
                    await self?.refreshStateSnapshot()
                }
            },
            onPeerLeft: { [weak self] _ in
                Task { await self?.refreshStateSnapshot() }
            }
        )

        // Mark as enabled early so the UI updates
        isEnabled = true
        var diag: [String] = []

        wanLog("Node ID: \(config.identity.nodeID)")
        wanLog("WG Public Key: \(config.identity.wgPublicKeyHex)")

        // Step 1: Connect to relay
        do {
            wanLog("Connecting to relay \(config.relayServerURLs.first?.absoluteString ?? "?")...")
            try await relay.connect()
            let msg = "Relay: connected"
            wanLog(msg)
            diag.append(msg)
        } catch {
            let msg = "Relay: FAILED — \(error.localizedDescription)"
            wanLog(msg)
            diag.append(msg)
        }

        // Step 2: STUN — discover public endpoint
        let mapping: NATMapping?
        do {
            wanLog("STUN: discovering public endpoint...")
            mapping = try await stun.discoverMapping()
            let msg = "STUN: \(mapping!.publicIP):\(mapping!.publicPort)"
            wanLog(msg)
            diag.append(msg)
        } catch {
            mapping = nil
            let msg = "STUN: FAILED — \(error.localizedDescription)"
            wanLog(msg)
            diag.append(msg)
        }

        // Step 3: NAT type detection
        let natType: NATType
        do {
            natType = try await stun.detectNATType()
            let msg = "NAT type: \(natType.rawValue)"
            wanLog(msg)
            diag.append(msg)
        } catch {
            natType = .unknown
            let msg = "NAT type: detection failed — \(error.localizedDescription)"
            wanLog(msg)
            diag.append(msg)
        }

        // Step 4: UDP listener for incoming WireGuard connections
        do {
            let udpListener = try WireGuardTransport.createListener(
                port: mapping.map { $0.publicPort } ?? 0,
                identity: config.identity
            )
            self.listener = udpListener
            startUDPListener(udpListener)
            let msg = "UDP listener: ready on port \(mapping?.publicPort ?? 0)"
            wanLog(msg)
            diag.append(msg)
        } catch {
            let msg = "UDP listener: FAILED — \(error.localizedDescription)"
            wanLog(msg)
            diag.append(msg)
        }

        // Step 5: Register with relay and start discovery
        let capabilities = currentCapabilities()
        do {
            try await discovery.start(capabilities: capabilities)
            let msg = "Discovery: registered with relay"
            wanLog(msg)
            diag.append(msg)
        } catch {
            let msg = "Discovery: registration FAILED — \(error.localizedDescription)"
            wanLog(msg)
            diag.append(msg)
        }

        // Check relay health endpoint for peer count
        await logRelayHealth(diag: &diag)

        // Start relay message listener for offers/answers
        startRelayListener()

        // Start heartbeat and health check loops
        startHeartbeatLoop()
        startHealthCheckLoop()

        self.enableDiagnostics = diag
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

    /// Connect to a discovered peer by node ID.
    public func connectToPeer(nodeID: String) async throws {
        guard let peerInfo = await discoveryService?.peer(byNodeID: nodeID) else {
            throw WANError.peerConnectionFailed("Peer \(nodeID) is no longer discoverable")
        }
        try await connectToPeer(peerInfo)
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

    func connectedPeerForInference(preferredModel modelID: String?, groupID: String? = nil, ptnID: String? = nil) -> ConnectedWANPeer? {
        let peerSummary = connectedPeers.values.map { "\($0.peerInfo.displayName): models=\($0.peerInfo.capabilities.loadedModels)" }
        FileHandle.standardError.write(Data("[WAN] connectedPeerForInference: \(connectedPeers.count) peers, preferredModel=\(modelID ?? "nil") ptnID=\(ptnID ?? "nil") peers=[\(peerSummary.joined(separator: ", "))]\n".utf8))

        // PTN-first routing: prefer peers that share a PTN membership
        let effectivePTNID = ptnID ?? groupID
        if let ptnID = effectivePTNID {
            let ptnPeers = connectedPeers.values.filter { peer in
                // Check ptnIDs array first, fall back to organizationID for backward compat
                if let peerPTNs = peer.peerInfo.capabilities.ptnIDs {
                    return peerPTNs.contains { $0.ptnID == ptnID }
                }
                return peer.peerInfo.organizationID == ptnID
            }
            let ptnMatch: ConnectedWANPeer?
            if let modelID {
                ptnMatch = ptnPeers.first { $0.peerInfo.hasModel(modelID) }
            } else {
                ptnMatch = ptnPeers
                    .filter { !$0.peerInfo.capabilities.loadedModels.isEmpty }
                    .sorted { lhs, rhs in
                        if lhs.latencyMs != rhs.latencyMs {
                            return (lhs.latencyMs ?? .infinity) < (rhs.latencyMs ?? .infinity)
                        }
                        return lhs.peerInfo.capabilities.hardware.totalRAMGB > rhs.peerInfo.capabilities.hardware.totalRAMGB
                    }
                    .first
            }
            if let peer = ptnMatch { return peer }
        }

        // Fall back to any peer
        if let modelID {
            return connectedPeer(withModel: modelID)
        }

        return connectedPeers.values
            .filter { !$0.peerInfo.capabilities.loadedModels.isEmpty }
            .sorted { lhs, rhs in
                if lhs.latencyMs != rhs.latencyMs {
                    return (lhs.latencyMs ?? .infinity) < (rhs.latencyMs ?? .infinity)
                }
                return lhs.peerInfo.capabilities.hardware.totalRAMGB > rhs.peerInfo.capabilities.hardware.totalRAMGB
            }
            .first
    }

    /// Check if any connected peer has a given model
    public func hasConnectedPeer(withModel modelID: String) -> Bool {
        connectedPeers.values.contains { $0.peerInfo.hasModel(modelID) }
    }

    /// Get a connected peer's transport connection by node ID.
    public func connectedPeers(byNodeID nodeID: String) -> WANTransportConnection? {
        connectedPeers[nodeID]?.connection
    }

    /// Get the best transport connection for a connected peer with the given model
    public func connectionForPeer(withModel modelID: String) -> WANTransportConnection? {
        connectedPeers.values
            .filter { $0.peerInfo.hasModel(modelID) }
            .sorted { $0.qualityScore > $1.qualityScore }
            .first?.connection
    }

    /// Get any available connected peer's connection (best quality first)
    public func anyAvailableConnection() -> WANTransportConnection? {
        connectedPeers.values
            .filter { $0.peerInfo.capabilities.isAvailable }
            .sorted { $0.qualityScore > $1.qualityScore }
            .first?.connection
    }

    /// Get all available connections for failover (ordered by quality score, best first)
    public func allAvailableConnections() -> [WANTransportConnection] {
        connectedPeers.values
            .filter { $0.peerInfo.capabilities.isAvailable }
            .sorted { $0.qualityScore > $1.qualityScore }
            .map(\.connection)
    }

    /// Force a relay re-registration and peer discovery refresh.
    public func refreshDiscovery() async throws {
        guard isEnabled else { return }
        let capabilities = currentCapabilities()
        try await discoveryService?.updateCapabilities(capabilities)
        try await discoveryService?.refresh()
        updateState(mapping: state.publicEndpoint, natType: state.natType)
    }

    /// Update the relay/discovery view of which models this node currently has loaded.
    public func updateLocalLoadedModels(_ loadedModels: [String]) async {
        guard isEnabled else { return }

        localDeviceInfo?.loadedModels = loadedModels

        do {
            try await discoveryService?.updateCapabilities(currentCapabilities())
        } catch {
            // Keep operating with the last advertised capabilities if the relay refresh fails.
        }
    }

    // MARK: - Message Handling

    private func startListening(to peer: ConnectedWANPeer) {
        Task { [weak self] in
            let messages = await peer.connection.incomingMessages
            for await message in messages {
                guard let self else { return }
                await self.handleMessage(message, from: peer)
            }
            // Connection ended — attempt reconnect after a delay
            guard let self else { return }
            let nodeID = peer.peerInfo.nodeID
            self.connectedPeers.removeValue(forKey: nodeID)
            self.updateState(mapping: self.state.publicEndpoint, natType: self.state.natType)

            // Try to reconnect if WAN is still enabled
            guard self.isEnabled else { return }
            self.attemptReconnect(nodeID: nodeID)
        }
    }

    /// Tracks which peers are being reconnected to prevent duplicate attempts.
    private var reconnectingNodeIDs: Set<String> = []

    private func attemptReconnect(nodeID: String, maxAttempts: Int = 20) {
        // Prevent duplicate reconnect tasks for the same peer
        guard !reconnectingNodeIDs.contains(nodeID) else { return }
        reconnectingNodeIDs.insert(nodeID)

        Task { [weak self] in
            defer { self?.reconnectingNodeIDs.remove(nodeID) }

            var delay: TimeInterval = 3
            for attempt in 1...maxAttempts {
                guard let self else { return }
                guard self.isEnabled, self.connectedPeers[nodeID] == nil else { return }

                self.wanLog("Reconnect attempt \(attempt)/\(maxAttempts) for \(nodeID.prefix(16))... (delay: \(delay)s)")
                try? await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000_000)
                guard self.isEnabled, self.connectedPeers[nodeID] == nil else { return }

                if let peerInfo = await self.discoveryService?.peer(byNodeID: nodeID) {
                    // Use tiebreaker: only the higher nodeID initiates to avoid both sides racing
                    if let config = self.config, config.identity.nodeID < peerInfo.nodeID {
                        self.wanLog("Reconnect: \(peerInfo.displayName) has higher nodeID, waiting for them to initiate")
                        // Still retry — if the other side doesn't initiate within backoff, we try
                    }

                    do {
                        try await self.connectToPeer(peerInfo)
                        self.wanLog("Reconnected to \(peerInfo.displayName) on attempt \(attempt)")
                        return
                    } catch {
                        self.wanLog("Reconnect attempt \(attempt) failed for \(peerInfo.displayName): \(error.localizedDescription)")
                    }
                } else {
                    self.wanLog("Reconnect attempt \(attempt): peer \(nodeID.prefix(16))... not in discovery, refreshing")
                    try? await self.discoveryService?.refresh()
                }

                delay = min(delay * 1.5, 30)
            }
            self?.wanLog("All reconnect attempts exhausted for \(nodeID.prefix(16))...")
        }
    }

    private func handleMessage(_ message: ClusterMessage, from peer: ConnectedWANPeer) async {
        switch message {
        case .heartbeat(let payload):
            connectedPeers[peer.peerInfo.nodeID]?.lastHeartbeat = Date()
            connectedPeers[peer.peerInfo.nodeID]?.peerInfo.capabilities.loadedModels = payload.loadedModels
            FileHandle.standardError.write(Data("[WAN] Heartbeat from \(peer.peerInfo.displayName): loadedModels=\(payload.loadedModels)\n".utf8))

            // Send ack
            let ack = HeartbeatPayload(
                deviceID: localDeviceInfo?.id ?? UUID(),
                timestamp: Date()
            )
            try? await peer.connection.send(.heartbeatAck(ack))
            updateState(mapping: state.publicEndpoint, natType: state.natType)

        case .heartbeatAck:
            connectedPeers[peer.peerInfo.nodeID]?.lastHeartbeat = Date()

        case .inferenceRequest(let payload):
            await onInferenceRequest?(payload, peer.connection)

        case .inferenceChunk, .inferenceComplete, .inferenceError:
            // Handled by WANProvider
            break

        case .ptnJoinRequest(let payload):
            await onPTNJoinRequest?(payload, peer.connection)

        case .ptnJoinResponse:
            // Handled by the joiner's PTNManager
            break

        default:
            break
        }
    }

    /// Peers known to be reachable on LAN (set by AppState when cluster is enabled).
    /// WAN auto-connect skips these to prefer the faster LAN path.
    public var lanPeerNodeIDs: Set<String> = []

    private func handleDiscoveredPeer(_ peer: WANPeerInfo) async {
        wanLog("Discovered peer: \(peer.displayName) nodeID=\(peer.nodeID.prefix(16))... wgKey=\(peer.wgPublicKey?.prefix(16) ?? "nil") models=\(peer.capabilities.loadedModels) available=\(peer.capabilities.isAvailable)")
        guard let config else { wanLog("  -> skip: no config"); return }
        guard peer.nodeID != config.identity.nodeID else { wanLog("  -> skip: self"); return }
        if let existing = connectedPeers[peer.nodeID] {
            let staleness = Date().timeIntervalSince(existing.lastHeartbeat)
            if staleness < 60 {
                // Update peer info if it was a placeholder from a race condition
                // (connection arrived before discovery response)
                let hasPlaceholderName = existing.peerInfo.displayName == "Unknown Peer"
                let hasPlaceholderHardware = existing.peerInfo.capabilities.hardware.totalRAMGB == 0
                if hasPlaceholderName || hasPlaceholderHardware {
                    wanLog("  -> updating placeholder peer info for \(peer.displayName)")
                    connectedPeers[peer.nodeID]?.peerInfo.displayName = peer.displayName
                    connectedPeers[peer.nodeID]?.peerInfo.capabilities.hardware = peer.capabilities.hardware
                    connectedPeers[peer.nodeID]?.peerInfo.capabilities.isAvailable = peer.capabilities.isAvailable
                    connectedPeers[peer.nodeID]?.peerInfo.wgPublicKey = peer.wgPublicKey
                    connectedPeers[peer.nodeID]?.peerInfo.organizationID = peer.organizationID
                    updateState(mapping: state.publicEndpoint, natType: state.natType)
                } else {
                    wanLog("  -> skip: already connected (heartbeat \(Int(staleness))s ago)")
                }
                return
            }
            wanLog("  -> existing connection stale (\(Int(staleness))s), replacing")
            await existing.connection.cancel()
            connectedPeers.removeValue(forKey: peer.nodeID)
        }
        guard peer.wgPublicKey != nil else { wanLog("  -> skip: no wgPublicKey"); return }
        guard peer.capabilities.isAvailable else { wanLog("  -> skip: not available"); return }
        guard !lanPeerNodeIDs.contains(peer.nodeID) else { wanLog("  -> skip: on LAN"); return }

        // Tiebreaker: only the node with the higher nodeID initiates the connection.
        // This prevents simultaneous offers where both nodes send offers and neither
        // listens for answers, causing mutual timeouts.
        guard config.identity.nodeID > peer.nodeID else {
            wanLog("  -> waiting for \(peer.displayName) to initiate (lower nodeID)")
            return
        }

        wanLog("  -> connecting to \(peer.displayName)...")
        do {
            try await connectToPeer(peer)
            wanLog("  -> connected to \(peer.displayName)!")
        } catch {
            wanLog("  -> connection failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Relay Listener (handles incoming offers)

    private func startRelayListener() {
        relayListenerTask = Task { [weak self] in
            // Re-subscribe in a loop: when the WebSocket reconnects,
            // the old stream ends (continuations are cleared) and we
            // need a fresh subscription.
            while !Task.isCancelled {
                guard let self = self, let relay = self.relayClient else { return }
                let messages = await relay.incomingMessages

                for await message in messages {
                    guard !Task.isCancelled else { break }

                    switch message {
                    case .offer(let offer):
                        self.wanLog("Received incoming offer from \(offer.fromNodeID.prefix(16))...")
                        // Don't block the listener — offer handling involves long timeouts
                        Task { await self.handleIncomingOffer(offer) }
                    case .relayOpen(let payload):
                        self.wanLog("Received relay open from \(payload.fromNodeID.prefix(16))...")
                        await self.handleIncomingRelayOpen(payload)
                    default:
                        break
                    }
                }
                // Stream ended (WebSocket reconnected) — re-subscribe
                FileHandle.standardError.write(Data("[WAN] Relay listener stream ended, re-subscribing...\n".utf8))
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    private func handleIncomingOffer(_ offer: RelayMessage.OfferPayload) async {
        guard let nat = natTraversal, let config = config else { return }
        guard connectedPeers.count < config.maxWANPeers else { return }
        guard connectedPeers[offer.fromNodeID] == nil else { return }
        let peerInfo = await discoveryService?.peers.first(where: { $0.nodeID == offer.fromNodeID })
            ?? WANPeerInfo.unknown(nodeID: offer.fromNodeID)
        do {
            // Try direct P2P first
            let connection = try await nat.handleIncomingOffer(offer: offer)
            let connected = ConnectedWANPeer(
                peerInfo: peerInfo,
                connection: .direct(connection),
                connectionType: .direct,
                lastHeartbeat: Date()
            )
            connectedPeers[offer.fromNodeID] = connected
        } catch {
            // Direct P2P failed — fall back to relay
            FileHandle.standardError.write(Data("[WAN] Direct connection from \(offer.fromNodeID.prefix(16)) failed: \(error). Trying relay fallback...\n".utf8))
            do {
                let relayConn = try await relayClient!.openRelayedSession(
                    toNodeID: offer.fromNodeID,
                    sessionID: offer.sessionID,
                    timeoutSeconds: config.connectionTimeoutSeconds
                )
                let connected = ConnectedWANPeer(
                    peerInfo: peerInfo,
                    connection: .relayed(relayConn),
                    connectionType: .relayed,
                    lastHeartbeat: Date()
                )
                connectedPeers[offer.fromNodeID] = connected
                FileHandle.standardError.write(Data("[WAN] Relay fallback succeeded for \(offer.fromNodeID.prefix(16))!\n".utf8))
            } catch {
                FileHandle.standardError.write(Data("[WAN] Relay fallback also failed for \(offer.fromNodeID.prefix(16)): \(error)\n".utf8))
            }
        }
        updateState()
    }

    private func handleIncomingRelayOpen(_ payload: RelayMessage.RelaySessionPayload) async {
        // Accept relay sessions initiated by supply nodes
        if connectedPeers[payload.fromNodeID] == nil {
            do {
                let connection = try await relayClient!.acceptRelayedSession(
                    fromNodeID: payload.fromNodeID,
                    sessionID: payload.sessionID
                )
                let peerInfo = await discoveryService?.peers.first(where: { $0.nodeID == payload.fromNodeID })
                    ?? WANPeerInfo.unknown(nodeID: payload.fromNodeID)
                let connected = ConnectedWANPeer(
                    peerInfo: peerInfo,
                    connection: .relayed(connection),
                    connectionType: .relayed,
                    lastHeartbeat: Date()
                )
                connectedPeers[payload.fromNodeID] = connected
                startListening(to: connected)
                updateState()
            } catch {
                FileHandle.standardError.write(Data("[WAN] Failed to accept relayOpen from \(payload.fromNodeID.prefix(16)): \(error)\n".utf8))
            }
        }
    }

    // MARK: - UDP Listener

    private func startUDPListener(_ listener: NWListener) {
        listenerTask = Task { [weak self] in
            listener.newConnectionHandler = { [weak self] connection in
                Task { await self?.handleIncomingWireGuardConnection(connection) }
            }
            listener.start(queue: .global(qos: .userInitiated))
        }
    }

    private func handleIncomingWireGuardConnection(_ nwConnection: NWConnection) async {
        guard let config = config else { return }
        guard connectedPeers.count < config.maxWANPeers else {
            nwConnection.cancel()
            return
        }

        // Create a responder connection — remote identity is unknown until the Noise
        // handshake completes, at which point the initiator's static public key is revealed.
        let peerConn = WireGuardPeerConnection(
            connection: nwConnection,
            localIdentity: config.identity
        )

        await peerConn.start()

        let isReady = await peerConn.isReady
        guard isReady else {
            await peerConn.cancel()
            return
        }

        // The handshake revealed the remote peer's WG public key.
        // Try to match it to a known peer from discovery.
        let revealedWGKeyHex: String? = await {
            guard let key = await peerConn.remoteWGPublicKeyRevealed else { return nil }
            return key.rawRepresentation.map { String(format: "%02x", $0) }.joined()
        }()

        guard let wgKeyHex = revealedWGKeyHex else {
            await peerConn.cancel()
            return
        }

        // Look up the peer by WG public key in the discovery service
        let discoveredPeers = await discoveryService?.peers ?? []
        let peerInfo = discoveredPeers.first { $0.wgPublicKey == wgKeyHex }
            ?? WANPeerInfo(
                nodeID: wgKeyHex,  // Use WG key hex as provisional nodeID
                publicKey: wgKeyHex,
                wgPublicKey: wgKeyHex,
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

        // Don't accept if already connected to this peer
        guard connectedPeers[peerInfo.nodeID] == nil else {
            await peerConn.cancel()
            return
        }

        let connected = ConnectedWANPeer(
            peerInfo: peerInfo,
            connection: .direct(peerConn),
            connectionType: .direct,
            lastHeartbeat: Date()
        )
        connectedPeers[peerInfo.nodeID] = connected
        startListening(to: connected)
        updateState(mapping: state.publicEndpoint, natType: state.natType)
    }

    // MARK: - Heartbeat Loop

    private func startHeartbeatLoop() {
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                let interval = self?.config?.heartbeatIntervalSeconds ?? 15
                // See ClusterManager.startHeartbeatLoop: Task.sleep(for:)
                // crashes in swift_task_dealloc under Swift 6.3 on long-
                // running loops. This loop must stay alive to keep the
                // gateway's per-device "loaded" flag fresh; without it
                // the heartbeat-stale check strips supplier eligibility.
                try? await Task.sleep(nanoseconds: UInt64(interval) * 1_000_000_000)
                guard let self = self else { return }

                let heartbeat = HeartbeatPayload(
                    deviceID: self.localDeviceInfo?.id ?? UUID(),
                    timestamp: Date(),
                    loadedModels: self.localDeviceInfo?.loadedModels ?? [],
                    isGenerating: false
                )

                for (nodeID, peer) in self.connectedPeers {
                    do {
                        try await peer.connection.send(.heartbeat(heartbeat))
                        self.connectedPeers[nodeID]?.consecutiveHeartbeatFailures = 0
                    } catch {
                        let failures = (self.connectedPeers[nodeID]?.consecutiveHeartbeatFailures ?? 0) + 1
                        self.connectedPeers[nodeID]?.consecutiveHeartbeatFailures = failures
                        self.wanLog("Heartbeat send failed to \(peer.peerInfo.displayName) (\(failures) consecutive): \(error.localizedDescription)")

                        // Be more tolerant during relay reconnection — the relay may be
                        // re-establishing and heartbeat sends will fail temporarily.
                        let relayReconnecting = await self.relayClient?.relayStatus == .reconnecting
                        let maxFailures = relayReconnecting ? 12 : 3
                        if failures >= maxFailures {
                            self.wanLog("Dropping \(peer.peerInfo.displayName) after \(failures) consecutive heartbeat failures")
                            await peer.connection.cancel()
                            self.connectedPeers.removeValue(forKey: nodeID)
                            self.attemptReconnect(nodeID: nodeID)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Health Check Loop

    private func startHealthCheckLoop() {
        healthCheckTask = Task { [weak self] in
            while !Task.isCancelled {
                // See ClusterManager.startHeartbeatLoop for why we route
                // through Task.sleep(nanoseconds:) rather than the newer
                // Task.sleep(for:) — the latter crashes in swift_task_dealloc
                // under Swift 6.3 on long-running loops.
                try? await Task.sleep(nanoseconds: 30 * 1_000_000_000)
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
                    self.wanLog("Health check: pruned peer \(nodeID.prefix(16))..., attempting reconnect")
                    self.attemptReconnect(nodeID: nodeID)
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

    private func updateState() {
        updateState(mapping: state.publicEndpoint, natType: state.natType)
    }

    private func updateState(mapping: NATMapping?, natType: NATType) {
        let summaries = connectedPeerSummaries
        let connectedPeerIDs = Set(summaries.map(\.id))

        state = WANState(
            isEnabled: isEnabled,
            connectedPeers: summaries,
            discoveredPeers: [],
            relayStatus: .disconnected,  // Updated async below
            publicEndpoint: mapping,
            natType: natType,
            discoveredPeerCount: 0,  // Updated async below
            diagnostics: enableDiagnostics
        )

        // Update relay status and discovered count asynchronously
        Task { @MainActor [weak self] in
            guard let self = self else { return }
            let relayStatus = await self.relayClient?.relayStatus ?? .disconnected
            let allDiscoveredPeers = await self.discoveryService?.peers ?? []
            let discoveredPeers = allDiscoveredPeers
                .filter { !connectedPeerIDs.contains($0.nodeID) }
                .sorted { lhs, rhs in
                    lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
                }
            self.state.relayStatus = relayStatus
            self.state.discoveredPeers = discoveredPeers
            self.state.discoveredPeerCount = allDiscoveredPeers.count
        }
    }

    private func currentCapabilities() -> NodeCapabilities {
        let hardware = localDeviceInfo?.hardware ?? HardwareCapability(
            chipFamily: .unknown,
            chipName: "Unknown",
            totalRAMGB: 0,
            gpuCoreCount: 0,
            memoryBandwidthGBs: 0,
            tier: .tier4
        )

        return NodeCapabilities(
            hardware: hardware,
            loadedModels: localDeviceInfo?.loadedModels ?? [],
            maxModelSizeGB: hardware.availableRAMForModelsGB,
            isAvailable: true
        )
    }

    private func refreshStateSnapshot() {
        updateState(mapping: state.publicEndpoint, natType: state.natType)
    }

    // MARK: - Diagnostics

    private func wanLog(_ message: String) {
        let line = "[WAN] \(message)\n"
        FileHandle.standardError.write(Data(line.utf8))
    }

    private func logRelayHealth(diag: inout [String]) async {
        guard let relayURL = config?.relayServerURLs.first else { return }
        // Convert wss://host/ws to https://host/health
        var components = URLComponents(url: relayURL, resolvingAgainstBaseURL: false)
        components?.scheme = relayURL.scheme == "wss" ? "https" : "http"
        components?.path = "/health"
        guard let healthURL = components?.url else { return }

        do {
            let (data, _) = try await URLSession.shared.data(from: healthURL)
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let peers = json["peers"] as? Int {
                let msg = "Relay health: \(peers) peer(s) registered on relay"
                wanLog(msg)
                diag.append(msg)
            }
        } catch {
            let msg = "Relay health: could not reach \(healthURL.absoluteString)"
            wanLog(msg)
            diag.append(msg)
        }
    }
}
