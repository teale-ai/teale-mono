import Foundation
import SharedTypes

// MARK: - Relay Message Protocol

/// Relay messages use flat JSON: `{"register": {...}}` (no Swift `_0` wrapper).
/// Custom Codable ensures the encoding matches what the relay server expects.
public enum RelayMessage: Codable, Sendable {
    case register(RegisterPayload)
    case registerAck(RegisterAckPayload)
    case discover(DiscoverPayload)
    case discoverResponse(DiscoverResponsePayload)
    case offer(OfferPayload)
    case answer(AnswerPayload)
    case iceCandidate(ICECandidatePayload)
    case relayOpen(RelaySessionPayload)
    case relayReady(RelaySessionPayload)
    case relayData(RelayDataPayload)
    case relayClose(RelaySessionPayload)
    case peerJoined(PeerNotificationPayload)
    case peerLeft(PeerNotificationPayload)
    case error(RelayErrorPayload)

    private enum CodingKeys: String, CodingKey {
        case register, registerAck, discover, discoverResponse
        case offer, answer, iceCandidate
        case relayOpen, relayReady, relayData, relayClose
        case peerJoined, peerLeft, error
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .register(let p): try container.encode(p, forKey: .register)
        case .registerAck(let p): try container.encode(p, forKey: .registerAck)
        case .discover(let p): try container.encode(p, forKey: .discover)
        case .discoverResponse(let p): try container.encode(p, forKey: .discoverResponse)
        case .offer(let p): try container.encode(p, forKey: .offer)
        case .answer(let p): try container.encode(p, forKey: .answer)
        case .iceCandidate(let p): try container.encode(p, forKey: .iceCandidate)
        case .relayOpen(let p): try container.encode(p, forKey: .relayOpen)
        case .relayReady(let p): try container.encode(p, forKey: .relayReady)
        case .relayData(let p): try container.encode(p, forKey: .relayData)
        case .relayClose(let p): try container.encode(p, forKey: .relayClose)
        case .peerJoined(let p): try container.encode(p, forKey: .peerJoined)
        case .peerLeft(let p): try container.encode(p, forKey: .peerLeft)
        case .error(let p): try container.encode(p, forKey: .error)
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let p = try? container.decode(RegisterPayload.self, forKey: .register) { self = .register(p); return }
        if let p = try? container.decode(RegisterAckPayload.self, forKey: .registerAck) { self = .registerAck(p); return }
        if let p = try? container.decode(DiscoverPayload.self, forKey: .discover) { self = .discover(p); return }
        if let p = try? container.decode(DiscoverResponsePayload.self, forKey: .discoverResponse) { self = .discoverResponse(p); return }
        if let p = try? container.decode(OfferPayload.self, forKey: .offer) { self = .offer(p); return }
        if let p = try? container.decode(AnswerPayload.self, forKey: .answer) { self = .answer(p); return }
        if let p = try? container.decode(ICECandidatePayload.self, forKey: .iceCandidate) { self = .iceCandidate(p); return }
        if let p = try? container.decode(RelaySessionPayload.self, forKey: .relayOpen) { self = .relayOpen(p); return }
        if let p = try? container.decode(RelaySessionPayload.self, forKey: .relayReady) { self = .relayReady(p); return }
        if let p = try? container.decode(RelayDataPayload.self, forKey: .relayData) { self = .relayData(p); return }
        if let p = try? container.decode(RelaySessionPayload.self, forKey: .relayClose) { self = .relayClose(p); return }
        if let p = try? container.decode(PeerNotificationPayload.self, forKey: .peerJoined) { self = .peerJoined(p); return }
        if let p = try? container.decode(PeerNotificationPayload.self, forKey: .peerLeft) { self = .peerLeft(p); return }
        if let p = try? container.decode(RelayErrorPayload.self, forKey: .error) { self = .error(p); return }
        throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Unknown relay message type"))
    }

    // MARK: - Payloads

    public struct RegisterPayload: Codable, Sendable {
        public var nodeID: String
        public var publicKey: String  // hex-encoded Ed25519 signing key
        public var wgPublicKey: String?  // hex-encoded Curve25519 KeyAgreement key for WireGuard
        public var displayName: String
        public var capabilities: NodeCapabilities
        public var signature: String  // hex-encoded signature of nodeID

        public init(nodeID: String, publicKey: String, wgPublicKey: String? = nil, displayName: String, capabilities: NodeCapabilities, signature: String) {
            self.nodeID = nodeID
            self.publicKey = publicKey
            self.wgPublicKey = wgPublicKey
            self.displayName = displayName
            self.capabilities = capabilities
            self.signature = signature
        }
    }

    public struct RegisterAckPayload: Codable, Sendable {
        public var nodeID: String
        public var registeredAt: Date
        public var ttlSeconds: Int

        public init(nodeID: String, registeredAt: Date = Date(), ttlSeconds: Int = 300) {
            self.nodeID = nodeID
            self.registeredAt = registeredAt
            self.ttlSeconds = ttlSeconds
        }
    }

    public struct DiscoverPayload: Codable, Sendable {
        public var requestingNodeID: String
        public var filter: PeerFilter?

        public init(requestingNodeID: String, filter: PeerFilter? = nil) {
            self.requestingNodeID = requestingNodeID
            self.filter = filter
        }
    }

    public struct DiscoverResponsePayload: Codable, Sendable {
        public var peers: [WANPeerInfo]

        public init(peers: [WANPeerInfo]) {
            self.peers = peers
        }
    }

    public struct OfferPayload: Codable, Sendable {
        public var fromNodeID: String
        public var toNodeID: String
        public var sessionID: String
        public var connectionInfo: ConnectionInfo
        public var signature: String

        public init(fromNodeID: String, toNodeID: String, sessionID: String, connectionInfo: ConnectionInfo, signature: String) {
            self.fromNodeID = fromNodeID
            self.toNodeID = toNodeID
            self.sessionID = sessionID
            self.connectionInfo = connectionInfo
            self.signature = signature
        }
    }

    public struct AnswerPayload: Codable, Sendable {
        public var fromNodeID: String
        public var toNodeID: String
        public var sessionID: String
        public var connectionInfo: ConnectionInfo
        public var signature: String

        public init(fromNodeID: String, toNodeID: String, sessionID: String, connectionInfo: ConnectionInfo, signature: String) {
            self.fromNodeID = fromNodeID
            self.toNodeID = toNodeID
            self.sessionID = sessionID
            self.connectionInfo = connectionInfo
            self.signature = signature
        }
    }

    public struct ICECandidatePayload: Codable, Sendable {
        public var fromNodeID: String
        public var toNodeID: String
        public var sessionID: String
        public var candidate: ICECandidate

        public init(fromNodeID: String, toNodeID: String, sessionID: String, candidate: ICECandidate) {
            self.fromNodeID = fromNodeID
            self.toNodeID = toNodeID
            self.sessionID = sessionID
            self.candidate = candidate
        }
    }

    public struct RelaySessionPayload: Codable, Sendable {
        public var fromNodeID: String
        public var toNodeID: String
        public var sessionID: String

        public init(fromNodeID: String, toNodeID: String, sessionID: String) {
            self.fromNodeID = fromNodeID
            self.toNodeID = toNodeID
            self.sessionID = sessionID
        }
    }

    public struct RelayDataPayload: Codable, Sendable {
        public var fromNodeID: String
        public var toNodeID: String
        public var sessionID: String
        public var data: Data

        public init(fromNodeID: String, toNodeID: String, sessionID: String, data: Data) {
            self.fromNodeID = fromNodeID
            self.toNodeID = toNodeID
            self.sessionID = sessionID
            self.data = data
        }
    }

    public struct PeerNotificationPayload: Codable, Sendable {
        public var nodeID: String
        public var displayName: String

        public init(nodeID: String, displayName: String) {
            self.nodeID = nodeID
            self.displayName = displayName
        }
    }

    public struct RelayErrorPayload: Codable, Sendable {
        public var code: String
        public var message: String
        public var retryAfterSeconds: Int?

        public init(code: String, message: String, retryAfterSeconds: Int? = nil) {
            self.code = code
            self.message = message
            self.retryAfterSeconds = retryAfterSeconds
        }
    }
}

// MARK: - Supporting Types

public struct NodeCapabilities: Codable, Sendable {
    public var hardware: HardwareCapability
    public var loadedModels: [String]
    public var maxModelSizeGB: Double
    public var isAvailable: Bool
    /// Private TealeNet memberships this node belongs to.
    public var ptnIDs: [PTNIdentifier]?

    public init(
        hardware: HardwareCapability,
        loadedModels: [String] = [],
        maxModelSizeGB: Double = 0,
        isAvailable: Bool = true,
        ptnIDs: [PTNIdentifier]? = nil
    ) {
        self.hardware = hardware
        self.loadedModels = loadedModels
        self.maxModelSizeGB = maxModelSizeGB
        self.isAvailable = isAvailable
        self.ptnIDs = ptnIDs
    }
}

public struct ConnectionInfo: Codable, Sendable {
    public var publicIP: String
    public var publicPort: UInt16
    public var localIP: String?
    public var localPort: UInt16?
    public var natType: NATType
    public var wgPublicKey: String?  // hex-encoded Curve25519 KeyAgreement public key for WireGuard

    public init(
        publicIP: String,
        publicPort: UInt16,
        localIP: String? = nil,
        localPort: UInt16? = nil,
        natType: NATType = .unknown,
        wgPublicKey: String? = nil
    ) {
        self.publicIP = publicIP
        self.publicPort = publicPort
        self.localIP = localIP
        self.localPort = localPort
        self.natType = natType
        self.wgPublicKey = wgPublicKey
    }
}

public struct ICECandidate: Codable, Sendable {
    public var ip: String
    public var port: UInt16
    public var type: CandidateType
    public var priority: Int

    public enum CandidateType: String, Codable, Sendable {
        case host
        case serverReflexive
        case relayed
    }

    public init(ip: String, port: UInt16, type: CandidateType, priority: Int) {
        self.ip = ip
        self.port = port
        self.type = type
        self.priority = priority
    }
}

public struct PeerFilter: Codable, Sendable {
    public var modelID: String?
    public var minRAMGB: Double?
    public var minTier: Int?
    public var maxPeers: Int?

    public init(modelID: String? = nil, minRAMGB: Double? = nil, minTier: Int? = nil, maxPeers: Int? = nil) {
        self.modelID = modelID
        self.minRAMGB = minRAMGB
        self.minTier = minTier
        self.maxPeers = maxPeers
    }
}

// MARK: - Relay Client

public actor RelayClient {
    private let config: WANConfig
    private var webSocketTask: URLSessionWebSocketTask?
    private let urlSession: URLSession
    /// Multiple subscribers can listen for relay messages (discovery + manager).
    private var messageContinuations: [UUID: AsyncStream<RelayMessage>.Continuation] = [:]
    private var isConnected: Bool = false
    private var reconnectTask: Task<Void, Never>?
    private var currentBackoff: TimeInterval = 1.0
    private var relayedConnections: [String: RelayPeerConnection] = [:]
    private var pendingRelayedData: [String: [Data]] = [:]
    private var relayReadyWaiters: [String: CheckedContinuation<Void, Error>] = [:]
    /// Relay sessions suspended during WebSocket disconnect — re-established on reconnect.
    private var suspendedRelaySessions: [(sessionID: String, connection: RelayPeerConnection, remoteNodeID: String)] = []
    /// WebSocket keepalive ping task.
    private var pingTask: Task<Void, Never>?
    /// Called after a successful reconnect so the discovery service can re-register.
    private var onReconnectHandler: (@Sendable () async -> Void)?

    public func setOnReconnect(_ handler: @escaping @Sendable () async -> Void) {
        onReconnectHandler = handler
    }

    /// Status subscribers fired when the socket drops into reconnect and
    /// after a successful reconnect, so observers (e.g. WANManager.state)
    /// re-latch instead of serving a stale relayStatus snapshot forever.
    private var statusHandlers: [UUID: @Sendable () async -> Void] = [:]

    @discardableResult
    public func addStatusHandler(_ handler: @escaping @Sendable () async -> Void) -> UUID {
        let id = UUID()
        statusHandlers[id] = handler
        return id
    }

    public func removeStatusHandler(_ id: UUID) {
        statusHandlers[id] = nil
    }

    private func fireStatusHandlers() {
        let handlers = statusHandlers
        guard !handlers.isEmpty else { return }
        Task { for (_, handler) in handlers { await handler() } }
    }
    private static let maxBackoff: TimeInterval = 60.0

    public var relayStatus: RelayStatus {
        if isConnected { return .connected }
        if reconnectTask != nil { return .reconnecting }
        return .disconnected
    }

    public init(config: WANConfig) {
        self.config = config
        self.urlSession = URLSession(configuration: .ephemeral)
    }

    // MARK: - Connection

    public func connect() async throws {
        guard let relayURL = config.relayServerURLs.first else {
            throw WANError.relayConnectionFailed("No relay server URLs configured")
        }

        // Append nodeID as query param so proxies (Fly.io) don't coalesce WebSocket
        // connections from the same public IP into a single connection.
        var components = URLComponents(url: relayURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "node", value: config.identity.nodeID)]
        let uniqueURL = components.url ?? relayURL

        let task = urlSession.webSocketTask(with: uniqueURL)
        self.webSocketTask = task
        task.resume()

        isConnected = true
        currentBackoff = 1.0

        FileHandle.standardError.write(Data("[WAN] connect() completed, calling receiveLoop()...\n".utf8))
        startPingLoop()
        receiveLoop()
        FileHandle.standardError.write(Data("[WAN] receiveLoop() returned\n".utf8))
    }

    public func disconnect() {
        reconnectTask?.cancel()
        reconnectTask = nil
        receiveTask?.cancel()
        receiveTask = nil
        pingTask?.cancel()
        pingTask = nil
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        isConnected = false
        failActiveRelaySessions(with: WANError.peerDisconnected)
        for (_, cont) in messageContinuations {
            cont.finish()
        }
        messageContinuations.removeAll()
    }

    /// Create a new subscription to incoming relay messages.
    /// Each subscriber gets ALL messages (broadcast, not competing consumers).
    public var incomingMessages: AsyncStream<RelayMessage> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<RelayMessage>.makeStream()
        messageContinuations[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeSubscriber(id) }
        }
        return stream
    }

    private func removeSubscriber(_ id: UUID) {
        messageContinuations.removeValue(forKey: id)
    }

    // MARK: - Send

    public func send(_ message: RelayMessage) async throws {
        guard let ws = webSocketTask else {
            throw WANError.relayMessageFailed("Not connected to relay")
        }

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .deferredToDate
        let data = try encoder.encode(message)
        // Bound the send: on a half-open WebSocket (dead NAT mapping, silent
        // network drop) ws.send can park indefinitely, and because
        // RelayClient is an actor one parked send serializes every later
        // send behind it — the node's 240s re-registration then never
        // reaches the relay with no error logged anywhere (the "silent
        // re-register exit" behind fleet catalog flapping).
        do {
            try await withSendTimeout(seconds: 15) {
                try await ws.send(.data(data))
            }
        } catch {
            handleDeadConnection(reason: "send failed: \(error.localizedDescription)")
            throw error
        }
    }

    private func withSendTimeout<T: Sendable>(seconds: TimeInterval, operation: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask(operation: operation)
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw WANError.timeout
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }

    /// Force the connection into the reconnect path when a send or ping
    /// proves the WebSocket is dead but no close/error event has surfaced
    /// (half-open connection). Mirrors the receive-loop error path.
    private func handleDeadConnection(reason: String) {
        guard isConnected else { return }
        FileHandle.standardError.write(Data("[WAN] Declaring relay connection dead (\(reason)); forcing reconnect\n".utf8))
        isConnected = false
        pingTask?.cancel()
        pingTask = nil
        receiveTask?.cancel()
        receiveTask = nil
        webSocketTask?.cancel(with: .abnormalClosure, reason: nil)
        webSocketTask = nil
        for (_, cont) in messageContinuations {
            cont.finish()
        }
        messageContinuations.removeAll()
        suspendActiveRelaySessions()
        scheduleReconnect()
    }

    private var consecutivePingFailures = 0

    private func notePingFailure() {
        consecutivePingFailures += 1
        if consecutivePingFailures >= 3 {
            consecutivePingFailures = 0
            handleDeadConnection(reason: "3 consecutive ping failures")
        }
    }

    /// Register this node with the relay server
    public func register(capabilities: NodeCapabilities) async throws {
        let identity = config.identity
        let signatureData = try identity.sign(Data(identity.nodeID.utf8))
        let signatureHex = signatureData.map { String(format: "%02x", $0) }.joined()

        let payload = RelayMessage.RegisterPayload(
            nodeID: identity.nodeID,
            publicKey: identity.nodeID,  // nodeID is already the hex public key
            wgPublicKey: identity.wgPublicKeyHex,
            displayName: config.displayName,
            capabilities: capabilities,
            signature: signatureHex
        )
        try await send(.register(payload))
    }

    /// Discover peers matching a filter
    public func discover(filter: PeerFilter? = nil) async throws {
        let payload = RelayMessage.DiscoverPayload(
            requestingNodeID: config.identity.nodeID,
            filter: filter
        )
        try await send(.discover(payload))
    }

    /// Send a connection offer to a peer
    public func sendOffer(toNodeID: String, sessionID: String, connectionInfo: ConnectionInfo) async throws {
        let identity = config.identity
        let dataToSign = Data("\(identity.nodeID):\(toNodeID):\(sessionID)".utf8)
        let signature = try identity.sign(dataToSign)
        let signatureHex = signature.map { String(format: "%02x", $0) }.joined()

        let payload = RelayMessage.OfferPayload(
            fromNodeID: identity.nodeID,
            toNodeID: toNodeID,
            sessionID: sessionID,
            connectionInfo: connectionInfo,
            signature: signatureHex
        )
        try await send(.offer(payload))
    }

    /// Send a connection answer to a peer
    public func sendAnswer(toNodeID: String, sessionID: String, connectionInfo: ConnectionInfo) async throws {
        let identity = config.identity
        let dataToSign = Data("\(identity.nodeID):\(toNodeID):\(sessionID)".utf8)
        let signature = try identity.sign(dataToSign)
        let signatureHex = signature.map { String(format: "%02x", $0) }.joined()

        let payload = RelayMessage.AnswerPayload(
            fromNodeID: identity.nodeID,
            toNodeID: toNodeID,
            sessionID: sessionID,
            connectionInfo: connectionInfo,
            signature: signatureHex
        )
        try await send(.answer(payload))
    }

    /// Send an ICE candidate to a peer
    public func sendICECandidate(toNodeID: String, sessionID: String, candidate: ICECandidate) async throws {
        let payload = RelayMessage.ICECandidatePayload(
            fromNodeID: config.identity.nodeID,
            toNodeID: toNodeID,
            sessionID: sessionID,
            candidate: candidate
        )
        try await send(.iceCandidate(payload))
    }

    public func openRelayedSession(toNodeID: String, sessionID: String, timeoutSeconds: TimeInterval) async throws -> RelayPeerConnection {
        FileHandle.standardError.write(Data("[WAN] openRelayedSession: sending relayOpen to \(toNodeID.prefix(16))... session=\(sessionID.prefix(8))\n".utf8))
        let connection = relayConnection(sessionID: sessionID, remoteNodeID: toNodeID)
        let payload = RelayMessage.RelaySessionPayload(
            fromNodeID: config.identity.nodeID,
            toNodeID: toNodeID,
            sessionID: sessionID
        )

        try await send(.relayOpen(payload))
        FileHandle.standardError.write(Data("[WAN] openRelayedSession: waiting for relayReady (timeout \(timeoutSeconds)s)...\n".utf8))
        try await waitForRelayReady(fromNodeID: toNodeID, sessionID: sessionID, timeoutSeconds: timeoutSeconds)
        FileHandle.standardError.write(Data("[WAN] openRelayedSession: relayReady received! Connection established.\n".utf8))
        return connection
    }

    public func acceptRelayedSession(fromNodeID: String, sessionID: String) async throws -> RelayPeerConnection {
        let connection = relayConnection(sessionID: sessionID, remoteNodeID: fromNodeID)
        let payload = RelayMessage.RelaySessionPayload(
            fromNodeID: config.identity.nodeID,
            toNodeID: fromNodeID,
            sessionID: sessionID
        )
        try await send(.relayReady(payload))
        return connection
    }

    public func sendRelayedClusterMessage(toNodeID: String, sessionID: String, data: Data) async throws {
        let payload = RelayMessage.RelayDataPayload(
            fromNodeID: config.identity.nodeID,
            toNodeID: toNodeID,
            sessionID: sessionID,
            data: data
        )
        try await send(.relayData(payload))
    }

    public func closeRelayedSession(sessionID: String, toNodeID: String, notifyRemote: Bool) async {
        let connection = relayedConnections.removeValue(forKey: sessionID)
        if notifyRemote {
            let payload = RelayMessage.RelaySessionPayload(
                fromNodeID: config.identity.nodeID,
                toNodeID: toNodeID,
                sessionID: sessionID
            )
            try? await send(.relayClose(payload))
        }
        await connection?.finishLocally()
    }

    private func relayConnection(sessionID: String, remoteNodeID: String) -> RelayPeerConnection {
        if let existing = relayedConnections[sessionID] {
            return existing
        }

        let connection = RelayPeerConnection(
            sessionID: sessionID,
            remoteNodeID: remoteNodeID,
            relayClient: self
        )
        relayedConnections[sessionID] = connection
        if let pendingPackets = pendingRelayedData.removeValue(forKey: sessionID) {
            for packet in pendingPackets {
                Task { await connection.receiveRelayedClusterMessage(packet) }
            }
        }
        return connection
    }

    // MARK: - Receive Loop

    private var receiveTask: Task<Void, Never>?

    private func receiveLoop() {
        FileHandle.standardError.write(Data("[WAN] receiveLoop() called, creating task...\n".utf8))
        receiveTask = Task { [weak self] in
            FileHandle.standardError.write(Data("[WAN] receiveLoop task started\n".utf8))
            await self?._receiveLoop()
        }
    }

    private func _receiveLoop() {
        guard let ws = webSocketTask else {
            FileHandle.standardError.write(Data("[WAN] _receiveLoop: no webSocketTask, exiting\n".utf8))
            return
        }

        Task {
            do {
                FileHandle.standardError.write(Data("[WAN] _receiveLoop: waiting for WebSocket message...\n".utf8))
                let wsMessage = try await ws.receive()
                let data: Data
                switch wsMessage {
                case .data(let d):
                    data = d
                case .string(let s):
                    data = Data(s.utf8)
                @unknown default:
                    _receiveLoop()
                    return
                }

                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .deferredToDate
                let preview = String(data: data.prefix(100), encoding: .utf8) ?? "binary"
                FileHandle.standardError.write(Data("[WAN] Relay recv: \(preview)\n".utf8))
                do {
                    let message = try decoder.decode(RelayMessage.self, from: data)
                    await handleDecodedMessage(message)
                    // Broadcast to all subscribers
                    for (_, cont) in messageContinuations {
                        cont.yield(message)
                    }
                } catch {
                    let preview = String(data: data.prefix(200), encoding: .utf8) ?? "binary"
                    FileHandle.standardError.write(Data("[WAN] Failed to decode relay message: \(error.localizedDescription)\n    Raw: \(preview)\n".utf8))
                }

                _receiveLoop()
            } catch {
                // Stale-socket guard: this receive failure belongs to the
                // socket captured at loop entry. If the current socket has
                // since been replaced (fresh connect, or the send/ping path
                // already declared the old one dead), tearing down state
                // here would kill the NEW healthy connection and schedule a
                // duplicate reconnect.
                guard webSocketTask === ws else {
                    FileHandle.standardError.write(Data("[WAN] Ignoring receive failure from stale WebSocket (already replaced)\n".utf8))
                    return
                }
                let msg = "[WAN] Relay WebSocket disconnected: \(error.localizedDescription)"
                FileHandle.standardError.write(Data((msg + "\n").utf8))
                isConnected = false
                pingTask?.cancel()
                pingTask = nil
                suspendActiveRelaySessions()
                for (_, cont) in messageContinuations {
                    cont.finish()
                }
                messageContinuations.removeAll()
                scheduleReconnect()
            }
        }
    }

    // MARK: - Reconnection with exponential backoff

    /// Nudge the reconnect machinery from outside the socket error paths
    /// (e.g. the periodic re-register failure handler in WANDiscovery).
    /// If a reconnect task exists but the socket is still down, that task
    /// may be wedged with no further progress possible from the outside;
    /// cancel it and start a fresh cycle. If the client is simply idle
    /// and disconnected, this schedules a reconnect that the
    /// reconnectTask == nil guard in scheduleReconnect would otherwise
    /// suppress only when a task is already running.
    public func ensureConnected() {
        guard !isConnected else { return }
        if let wedged = reconnectTask {
            FileHandle.standardError.write(Data("[WAN] ensureConnected: cancelling wedged reconnect task and starting fresh\n".utf8))
            wedged.cancel()
            reconnectTask = nil
        }
        scheduleReconnect()
    }

    private func scheduleReconnect() {
        guard reconnectTask == nil else { return }

        fireStatusHandlers()
        reconnectTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self = self else { return }
                let backoff = await self.currentBackoff

                try? await Task.sleep(nanoseconds: UInt64(backoff) * 1_000_000_000)
                guard !Task.isCancelled else { return }

                do {
                    FileHandle.standardError.write(Data("[WAN] Attempting relay reconnect (backoff: \(backoff)s)...\n".utf8))
                    try await self.connect()
                    FileHandle.standardError.write(Data("[WAN] Relay reconnected successfully\n".utf8))
                    await self.resetReconnect()
                    await self.fireStatusHandlers()
                    // Re-register after reconnect
                    await self.onReconnectHandler?()
                    // Re-establish suspended relay sessions
                    await self.resumeRelaySessions()
                    return
                } catch {
                    FileHandle.standardError.write(Data("[WAN] Relay reconnect failed: \(error.localizedDescription)\n".utf8))
                    await self.increaseBackoff()
                }
            }
        }
    }

    private func resetReconnect() {
        reconnectTask = nil
        currentBackoff = 1.0
    }

    private func increaseBackoff() {
        currentBackoff = min(currentBackoff * 2, Self.maxBackoff)
    }

    private func handleDecodedMessage(_ message: RelayMessage) async {
        switch message {
        case .relayReady(let payload):
            guard let waiter = relayReadyWaiters.removeValue(forKey: payload.sessionID),
                  payload.fromNodeID != config.identity.nodeID
            else { return }
            waiter.resume(returning: ())

        case .relayData(let payload):
            guard let connection = relayedConnections[payload.sessionID] else {
                pendingRelayedData[payload.sessionID, default: []].append(payload.data)
                FileHandle.standardError.write(Data("[WAN] relayData: no connection for session \(payload.sessionID.prefix(8))... (known sessions: \(relayedConnections.keys.map { String($0.prefix(8)) }))\n".utf8))
                return
            }
            await connection.receiveRelayedClusterMessage(payload.data)

        case .relayClose(let payload):
            pendingRelayedData.removeValue(forKey: payload.sessionID)
            guard let connection = relayedConnections.removeValue(forKey: payload.sessionID) else { return }
            await connection.finishLocally()

        case .error(let payload):
            FileHandle.standardError.write(Data("[WAN] Relay error: \(payload.code) - \(payload.message)\n".utf8))
            // peer_not_found means the relay has no live connection for the
            // target node (e.g. the gateway restarted and re-registered on a
            // fresh socket, or this client's session outlived the peer's).
            // Fail every session aimed at that node so send paths throw, the
            // peer is dropped, and a fresh session is dialed - otherwise
            // sends keep "succeeding" into the void and the stale session
            // never recovers (post-restart heartbeat blackhole).
            if payload.code == "peer_not_found",
               let targetNodeID = Self.extractPeerNodeID(from: payload.message) {
                failRelaySessions(forRemoteNodeID: targetNodeID, with: WANError.peerDisconnected)
            }

        default:
            break
        }
    }

    private func waitForRelayReady(fromNodeID: String, sessionID: String, timeoutSeconds: TimeInterval) async throws {
        try await withCheckedThrowingContinuation { continuation in
            relayReadyWaiters[sessionID] = continuation

            Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
                await self?.timeoutRelayReadyWaiter(sessionID: sessionID, expectedNodeID: fromNodeID)
            }
        }
    }

    private func timeoutRelayReadyWaiter(sessionID: String, expectedNodeID: String) {
        guard let waiter = relayReadyWaiters.removeValue(forKey: sessionID) else { return }
        _ = expectedNodeID
        waiter.resume(throwing: WANError.timeout)
    }

    private func failActiveRelaySessions(with error: Error) {
        let relayed = Array(relayedConnections.values)
        relayedConnections.removeAll()
        pendingRelayedData.removeAll()
        suspendedRelaySessions.removeAll()

        let waiters = relayReadyWaiters.values
        relayReadyWaiters.removeAll()
        for waiter in waiters {
            waiter.resume(throwing: error)
        }

        for connection in relayed {
            Task { await connection.finishLocally() }
        }
    }

    /// Fail every session whose remote end is `nodeID` - the targeted
    /// variant of failActiveRelaySessions, driven by the relay's
    /// peer_not_found error for one unreachable peer while the socket and
    /// the remaining sessions stay up.
    private func failRelaySessions(forRemoteNodeID nodeID: String, with error: Error) {
        let matching = relayedConnections.filter { $0.value.remoteNodeID == nodeID }
        guard !matching.isEmpty else { return }
        FileHandle.standardError.write(Data("[WAN] Failing \(matching.count) session(s) to unreachable peer \(nodeID.prefix(16))...\n".utf8))
        for (sessionID, connection) in matching {
            relayedConnections.removeValue(forKey: sessionID)
            pendingRelayedData.removeValue(forKey: sessionID)
            if let waiter = relayReadyWaiters.removeValue(forKey: sessionID) {
                waiter.resume(throwing: error)
            }
            Task { await connection.finishLocally() }
        }
    }

    /// Parse the target node id out of the relay's peer_not_found message
    /// ("Peer <nodeID> is not connected", relay/server.ts forwardToTarget).
    private static func extractPeerNodeID(from message: String) -> String? {
        guard message.hasPrefix("Peer ") else { return nil }
        let rest = message.dropFirst(5)
        guard let end = rest.firstIndex(of: " ") else { return nil }
        return String(rest[..<end])
    }

    /// Preserve active relay sessions during a temporary WebSocket disconnect.
    /// The connections stay alive (their AsyncStream is not finished) so that
    /// WANManager's startListening loops don't trigger reconnect cascades.
    private func suspendActiveRelaySessions() {
        for (sessionID, connection) in relayedConnections {
            suspendedRelaySessions.append((
                sessionID: sessionID,
                connection: connection,
                remoteNodeID: connection.remoteNodeID
            ))
        }
        relayedConnections.removeAll()
        pendingRelayedData.removeAll()

        // Fail pending waiters — they can retry after reconnect
        let waiters = relayReadyWaiters.values
        relayReadyWaiters.removeAll()
        for waiter in waiters {
            waiter.resume(throwing: WANError.peerDisconnected)
        }

        FileHandle.standardError.write(Data("[WAN] Suspended \(suspendedRelaySessions.count) relay session(s) during disconnect\n".utf8))
    }

    /// Re-establish suspended relay sessions on a new WebSocket connection.
    private func resumeRelaySessions() async {
        let sessions = suspendedRelaySessions
        suspendedRelaySessions.removeAll()

        guard !sessions.isEmpty else { return }
        FileHandle.standardError.write(Data("[WAN] Resuming \(sessions.count) suspended relay session(s)...\n".utf8))

        for session in sessions {
            // The session may have been torn down while suspended (e.g.
            // WANManager found its Noise keys unrecoverable and closed it);
            // never re-register a closed connection.
            if await session.connection.isClosed {
                FileHandle.standardError.write(Data("[WAN] Skipping resume of closed relay session \(session.sessionID.prefix(8))...\n".utf8))
                continue
            }
            do {
                let payload = RelayMessage.RelaySessionPayload(
                    fromNodeID: config.identity.nodeID,
                    toNodeID: session.remoteNodeID,
                    sessionID: session.sessionID
                )
                // Re-register BEFORE sending relayOpen: if the peer's own
                // resume relayOpen (or any relayData) races in between, the
                // session must already map to THIS connection object or the
                // peer's idempotent re-ack would recreate and diverge it.
                relayedConnections[session.sessionID] = session.connection
                // Drain anything that arrived while the session was
                // unregistered (relayConnection() does this for fresh
                // sessions; the direct assignment here used to skip it,
                // silently losing every message from the race window).
                if let pending = pendingRelayedData.removeValue(forKey: session.sessionID) {
                    for packet in pending {
                        Task { await session.connection.receiveRelayedClusterMessage(packet) }
                    }
                }
                try await send(.relayOpen(payload))
                FileHandle.standardError.write(Data("[WAN] Resumed relay session \(session.sessionID.prefix(8))... to \(session.remoteNodeID.prefix(16))...\n".utf8))
            } catch {
                FileHandle.standardError.write(Data("[WAN] Failed to resume relay session \(session.sessionID.prefix(8))...: \(error.localizedDescription)\n".utf8))
                relayedConnections.removeValue(forKey: session.sessionID)
                await session.connection.finishLocally()
            }
        }
    }

    /// Last time a pong completion arrived. sendPing's handler is the
    /// pongReceiveHandler - on a dead-but-quiet socket (dead NAT mapping,
    /// silent network drop) it simply never fires, with no error, so the
    /// consecutive-failure counter alone can never trip. The watchdog
    /// below treats 90s of completion silence as a failed connection.
    private var lastPongAt = Date()

    /// Periodic WebSocket ping to keep the connection alive through NAT/firewalls.
    private func startPingLoop() {
        pingTask?.cancel()
        lastPongAt = Date()
        pingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 25 * 1_000_000_000)
                guard !Task.isCancelled, let self else { return }
                let silence = Date().timeIntervalSince(await self.lastPongAt)
                if silence > 90 {
                    FileHandle.standardError.write(Data("[WAN] No WebSocket pong for \(Int(silence))s; declaring connection dead\n".utf8))
                    await self.notePingSilence()
                    continue
                }
                let ws = await self.webSocketTask
                ws?.sendPing { [weak self] error in
                    guard let self else { return }
                    if let error {
                        FileHandle.standardError.write(Data("[WAN] WebSocket ping failed: \(error.localizedDescription)\n".utf8))
                        Task { await self.notePingFailure() }
                    } else {
                        Task { await self.resetPingFailures() }
                    }
                }
            }
        }
    }

    private func notePingSilence() {
        handleDeadConnection(reason: "no pong for 90s")
    }

    private func resetPingFailures() {
        consecutivePingFailures = 0
        lastPongAt = Date()
    }
}

// MARK: - Relay Status

public enum RelayStatus: String, Sendable {
    case disconnected
    case connecting
    case connected
    case reconnecting
}
