import Foundation
import Network
import SharedTypes
import HardwareProfile

// MARK: - Cluster Manager

/// Central orchestrator for LAN cluster mode
@Observable
public final class ClusterManager: @unchecked Sendable {
    // State
    public private(set) var isEnabled: Bool = false
    public private(set) var isScanning: Bool = false
    public private(set) var peers: [UUID: PeerInfo] = [:]
    public private(set) var topology: ClusterTopology = ClusterTopology()
    public private(set) var clusterState: ClusterState = ClusterState()

    // Configuration
    public var passcode: String?
    public var deviceName: String
    public var organizationID: String?
    public var orgCapacityReservation: Double = 0.6  // 0-1, default 60% reserved for org

    // Components
    public let localDeviceInfo: DeviceInfo
    private var bonjourService: BonjourService?
    private var peerResolver: PeerResolver?
    private let healthMonitor = PeerHealthMonitor()
    private let modelSharingService = ModelSharingService()
    private let tlsManager = ClusterTLSManager()
    private var heartbeatTask: Task<Void, Never>?
    private var healthCheckTask: Task<Void, Never>?
    private var scanStopTask: Task<Void, Never>?
    private var connectingPeerIDs: Set<UUID> = []

    // Model sharing
    private var modelQueryContinuation: AsyncStream<ModelQueryResult>.Continuation?
    public private(set) var activeTransfers: [UUID: TransferProgress] = [:]

    // Load tracking
    public var localQueueDepth: Int = 0

    // Callbacks
    public var onInferenceRequest: ((InferenceRequestPayload, PeerConnection) async -> Void)?
    public var onCreditTransferReceived: ((CreditTransferPayload, PeerConnection) async -> Void)?

    public init(localDeviceInfo: DeviceInfo) {
        self.localDeviceInfo = localDeviceInfo
        self.deviceName = localDeviceInfo.name
    }

    // MARK: - Enable/Disable

    public func enable() {
        guard !isEnabled else { return }
        isEnabled = true

        let passcodeHash = passcode.map { ClusterSecurity.hashPasscode($0) }
        self.organizationID = passcodeHash  // Nodes with same passcode form an org
        let parameters = NWParameters.clusterParameters(passcode: passcode, tlsManager: tlsManager)

        bonjourService = BonjourService(localDeviceID: localDeviceInfo.id, parameters: parameters)
        peerResolver = PeerResolver(localDeviceInfo: localDeviceInfo, passcodeHash: passcodeHash, parameters: parameters)

        // Handle discovered peers
        bonjourService?.onPeerDiscovered = { [weak self] endpoint, txtDict in
            Task { await self?.handlePeerDiscovered(endpoint: endpoint, txtDict: txtDict) }
        }

        bonjourService?.onPeerRemoved = { [weak self] endpoint in
            self?.handlePeerRemoved(endpoint: endpoint)
        }

        // Handle incoming connections
        bonjourService?.onIncomingConnection = { [weak self] connection in
            Task { await self?.handleIncomingConnection(connection) }
        }

        // Start advertising only. Browsing is triggered manually from the UI.
        try? bonjourService?.startAdvertising(deviceInfo: localDeviceInfo)

        // Start heartbeat and health check loops
        startHeartbeatLoop()
        startHealthCheckLoop()

        updateState()
    }

    public func disable() {
        guard isEnabled else { return }
        isEnabled = false

        bonjourService?.stop()
        bonjourService = nil
        peerResolver = nil
        stopScanning()

        heartbeatTask?.cancel()
        healthCheckTask?.cancel()

        // Disconnect all peers
        for (_, peer) in peers {
            Task { await peer.connection.cancel() }
        }
        peers.removeAll()

        updateState()
    }

    public func scanForPeers(duration: Duration = .seconds(10)) {
        guard isEnabled, bonjourService != nil else { return }

        scanStopTask?.cancel()
        bonjourService?.stopBrowsing()
        bonjourService?.startBrowsing()
        isScanning = true

        scanStopTask = Task { [weak self] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled else { return }
            self?.stopScanning()
        }
    }

    public func stopScanning() {
        scanStopTask?.cancel()
        scanStopTask = nil
        bonjourService?.stopBrowsing()
        isScanning = false
    }

    // MARK: - Peer Management

    private func handlePeerDiscovered(endpoint: NWEndpoint, txtDict: [String: String]) async {
        guard let resolver = peerResolver else { return }
        guard let peerIDString = txtDict["deviceID"], let discoveredPeerID = UUID(uuidString: peerIDString) else {
            print("Cluster discovery missing deviceID for \(endpoint)")
            return
        }
        guard discoveredPeerID != localDeviceInfo.id else { return }
        guard peers[discoveredPeerID] == nil, !connectingPeerIDs.contains(discoveredPeerID) else { return }
        guard shouldInitiateOutboundConnection(to: discoveredPeerID) else { return }

        connectingPeerIDs.insert(discoveredPeerID)
        defer { connectingPeerIDs.remove(discoveredPeerID) }

        do {
            let peerInfo = try await resolver.resolve(endpoint: endpoint)
            if peerInfo.id == localDeviceInfo.id {
                await peerInfo.connection.cancel()
                return
            }
            if peerInfo.id != discoveredPeerID {
                print("Cluster resolved deviceID mismatch for \(endpoint): expected \(discoveredPeerID), got \(peerInfo.id)")
                await peerInfo.connection.cancel()
                return
            }
            peers[peerInfo.id] = peerInfo
            startListening(to: peerInfo)
            updateState()
        } catch {
            print("Cluster resolve failed for \(endpoint): \(error.localizedDescription)")
        }
    }

    private func handlePeerRemoved(endpoint: NWEndpoint) {
        // Remove peer associated with this endpoint
        // Since we can't easily match endpoint to peer, mark all as needing revalidation
        // The health monitor will handle cleanup
    }

    private func handleIncomingConnection(_ connection: NWConnection) async {
        guard let resolver = peerResolver else { return }

        do {
            let peerInfo = try await resolver.acceptIncoming(connection: connection)
            if peerInfo.id == localDeviceInfo.id {
                await peerInfo.connection.cancel()
                return
            }
            // Avoid duplicate connections
            if peers[peerInfo.id] == nil {
                peers[peerInfo.id] = peerInfo
                startListening(to: peerInfo)
                updateState()
            } else {
                await peerInfo.connection.cancel()
            }
        } catch {
            print("Cluster incoming connection failed: \(error.localizedDescription)")
        }
    }

    private func shouldInitiateOutboundConnection(to peerID: UUID) -> Bool {
        localDeviceInfo.id.uuidString < peerID.uuidString
    }

    // MARK: - Message Handling

    private func startListening(to peer: PeerInfo) {
        Task {
            let messages = await peer.connection.incomingMessages
            for await message in messages {
                await handleMessage(message, from: peer)
            }
            // Connection ended
            peer.status = .disconnected
            updateState()
        }
    }

    private func handleMessage(_ message: ClusterMessage, from peer: PeerInfo) async {
        switch message {
        case .heartbeat(let payload):
            peer.lastHeartbeat = Date()
            peer.loadedModels = payload.loadedModels
            peer.isGenerating = payload.isGenerating
            peer.thermalLevel = payload.thermalLevel
            peer.throttleLevel = payload.throttleLevel
            peer.activeRequestCount = payload.queueDepth
            peer.organizationID = payload.organizationID
            if peer.status == .degraded {
                peer.status = .connected
            }
            // Send ack
            let ack = HeartbeatPayload(deviceID: localDeviceInfo.id)
            try? await peer.connection.send(.heartbeatAck(ack))
            updateState()

        case .heartbeatAck:
            peer.lastHeartbeat = Date()
            if peer.status == .degraded {
                peer.status = .connected
                updateState()
            }

        case .inferenceRequest(let payload):
            // Delegate to the inference handler
            await onInferenceRequest?(payload, peer.connection)

        case .inferenceChunk, .inferenceComplete, .inferenceError:
            // These are handled by the ClusterProvider waiting on specific requestIDs
            break

        case .modelQuery(let payload):
            try? await modelSharingService.handleModelQuery(payload, connection: peer.connection)

        case .modelQueryResponse(let payload):
            modelQueryContinuation?.yield(ModelQueryResult(
                peerID: peer.id,
                modelID: payload.modelID,
                available: payload.available,
                sizeBytes: payload.totalSizeBytes
            ))

        case .modelTransferRequest(let payload):
            try? await modelSharingService.handleTransferRequest(payload, connection: peer.connection)

        case .modelTransferChunk(let payload):
            try? await modelSharingService.handleTransferChunk(payload)
            // Update transfer progress
            if var progress = activeTransfers[payload.transferID] {
                progress.bytesReceived += UInt64(payload.data.count)
                activeTransfers[payload.transferID] = progress
            }

        case .modelTransferComplete(let payload):
            try? await modelSharingService.handleTransferComplete(payload)
            activeTransfers.removeValue(forKey: payload.transferID)

        case .hello, .helloAck:
            // Handled during connection setup by PeerResolver
            break

        case .agentMessage:
            // Handled by AgentKit layer
            break

        case .creditTransferRequest(let payload):
            await onCreditTransferReceived?(payload, peer.connection)

        case .creditTransferConfirm:
            // Confirmation received — informational only (sender already debited)
            break
        }
    }

    // MARK: - Heartbeat Loop

    private func startHeartbeatLoop() {
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard let self = self else { return }

                var heartbeat = await self.healthMonitor.makeHeartbeat(
                    deviceID: self.localDeviceInfo.id,
                    thermalLevel: .nominal,  // TODO: wire to actual throttler
                    throttleLevel: 100,
                    loadedModels: self.localDeviceInfo.loadedModels,
                    isGenerating: false,
                    queueDepth: self.localQueueDepth
                )
                heartbeat.organizationID = self.organizationID

                for (_, peer) in self.peers where peer.status == .connected || peer.status == .degraded {
                    try? await peer.connection.send(.heartbeat(heartbeat))
                }
            }
        }
    }

    private func startHealthCheckLoop() {
        healthCheckTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard let self = self else { return }

                let updates = await self.healthMonitor.checkHealth(peers: Array(self.peers.values))
                for (peerID, newStatus) in updates {
                    if let peer = self.peers[peerID] {
                        peer.status = newStatus
                        if newStatus == .disconnected {
                            await peer.connection.cancel()
                        }
                    }
                }

                // Remove disconnected peers after a grace period
                let disconnectedIDs = self.peers.filter { $0.value.status == .disconnected }.map { $0.key }
                for id in disconnectedIDs {
                    self.peers.removeValue(forKey: id)
                }

                if !updates.isEmpty {
                    self.updateState()
                }
            }
        }
    }

    // MARK: - State Updates

    private func updateState() {
        topology.update(peers: Array(peers.values))
        clusterState = topology.toClusterState(isEnabled: isEnabled)
    }

    /// Get summaries of all peers for UI
    public var peerSummaries: [PeerSummary] {
        Array(peers.values).map { $0.toSummary() }
    }

    /// Find the best peer to handle inference for a given model
    public func bestPeer(forModel modelID: String) -> PeerInfo? {
        topology.bestPeerForModel(modelID)
    }

    // MARK: - Credit Transfers

    /// Send a credit transfer to a specific peer
    public func sendCreditTransfer(to peerID: UUID, payload: CreditTransferPayload) async throws {
        guard let peer = peers[peerID] else {
            throw ClusterError.routingFailed
        }
        try await peer.connection.send(.creditTransferRequest(payload))
    }

    // MARK: - Model Sharing

    /// Query all connected peers for model availability
    public func queryModelAvailability(modelID: String) -> AsyncStream<ModelQueryResult> {
        let (stream, continuation) = AsyncStream<ModelQueryResult>.makeStream()
        self.modelQueryContinuation = continuation

        let query = ModelQueryPayload(modelID: modelID)
        for (_, peer) in peers where peer.status == .connected {
            Task { try? await peer.connection.send(.modelQuery(query)) }
        }

        // Auto-close after timeout
        Task {
            try? await Task.sleep(for: .seconds(5))
            continuation.finish()
            self.modelQueryContinuation = nil
        }

        return stream
    }

    /// Request a model transfer from a specific peer
    public func requestModelFromPeer(modelID: String, peerID: UUID) async throws {
        guard let peer = peers[peerID] else {
            throw ClusterError.routingFailed
        }

        let transferID = UUID()
        let request = ModelTransferRequestPayload(transferID: transferID, modelID: modelID)
        activeTransfers[transferID] = TransferProgress(modelID: modelID, bytesReceived: 0, totalBytes: nil)
        try await peer.connection.send(.modelTransferRequest(request))
    }
}

// MARK: - Model Query Result

public struct ModelQueryResult: Sendable {
    public let peerID: UUID
    public let modelID: String
    public let available: Bool
    public let sizeBytes: UInt64?
}

// MARK: - Transfer Progress

// MARK: - PeerModelSource Conformance

extension ClusterManager: PeerModelSource {
    public func queryModelAvailability(modelID: String) async -> [(peerID: UUID, available: Bool, sizeBytes: UInt64?)] {
        let stream = queryModelAvailability(modelID: modelID) as AsyncStream<ModelQueryResult>
        var results: [(peerID: UUID, available: Bool, sizeBytes: UInt64?)] = []
        for await result in stream {
            results.append((peerID: result.peerID, available: result.available, sizeBytes: result.sizeBytes))
        }
        return results
    }
}

public struct TransferProgress: Sendable {
    public var modelID: String
    public var bytesReceived: UInt64
    public var totalBytes: UInt64?

    public var fraction: Double? {
        guard let total = totalBytes, total > 0 else { return nil }
        return Double(bytesReceived) / Double(total)
    }
}
