import Foundation
import SharedTypes

// MARK: - Relay Message Protocol

public enum RelayMessage: Codable, Sendable {
    case register(RegisterPayload)
    case registerAck(RegisterAckPayload)
    case discover(DiscoverPayload)
    case discoverResponse(DiscoverResponsePayload)
    case offer(OfferPayload)
    case answer(AnswerPayload)
    case iceCandidate(ICECandidatePayload)
    case peerJoined(PeerNotificationPayload)
    case peerLeft(PeerNotificationPayload)
    case error(RelayErrorPayload)

    // MARK: - Payloads

    public struct RegisterPayload: Codable, Sendable {
        public var nodeID: String
        public var publicKey: String  // hex-encoded
        public var displayName: String
        public var capabilities: NodeCapabilities
        public var signature: String  // hex-encoded signature of nodeID

        public init(nodeID: String, publicKey: String, displayName: String, capabilities: NodeCapabilities, signature: String) {
            self.nodeID = nodeID
            self.publicKey = publicKey
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

        public init(code: String, message: String) {
            self.code = code
            self.message = message
        }
    }
}

// MARK: - Supporting Types

public struct NodeCapabilities: Codable, Sendable {
    public var hardware: HardwareCapability
    public var loadedModels: [String]
    public var maxModelSizeGB: Double
    public var isAvailable: Bool

    public init(
        hardware: HardwareCapability,
        loadedModels: [String] = [],
        maxModelSizeGB: Double = 0,
        isAvailable: Bool = true
    ) {
        self.hardware = hardware
        self.loadedModels = loadedModels
        self.maxModelSizeGB = maxModelSizeGB
        self.isAvailable = isAvailable
    }
}

public struct ConnectionInfo: Codable, Sendable {
    public var publicIP: String
    public var publicPort: UInt16
    public var localIP: String?
    public var localPort: UInt16?
    public var natType: NATType
    public var quicParameters: QUICParameters?

    public init(
        publicIP: String,
        publicPort: UInt16,
        localIP: String? = nil,
        localPort: UInt16? = nil,
        natType: NATType = .unknown,
        quicParameters: QUICParameters? = nil
    ) {
        self.publicIP = publicIP
        self.publicPort = publicPort
        self.localIP = localIP
        self.localPort = localPort
        self.natType = natType
        self.quicParameters = quicParameters
    }
}

public struct QUICParameters: Codable, Sendable {
    public var alpn: [String]
    public var certificateFingerprint: String  // hex SHA256 of self-signed cert

    public init(alpn: [String] = ["teale-wan-1"], certificateFingerprint: String) {
        self.alpn = alpn
        self.certificateFingerprint = certificateFingerprint
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

    public init(modelID: String? = nil, minRAMGB: Double? = nil, minTier: Int? = nil) {
        self.modelID = modelID
        self.minRAMGB = minRAMGB
        self.minTier = minTier
    }
}

// MARK: - Relay Client

public actor RelayClient {
    private let config: WANConfig
    private var webSocketTask: URLSessionWebSocketTask?
    private let urlSession: URLSession
    private var messageContinuation: AsyncStream<RelayMessage>.Continuation?
    private var _incomingMessages: AsyncStream<RelayMessage>?
    private var isConnected: Bool = false
    private var reconnectTask: Task<Void, Never>?
    private var currentBackoff: TimeInterval = 1.0
    private static let maxBackoff: TimeInterval = 60.0

    public var relayStatus: RelayStatus {
        if isConnected { return .connected }
        if reconnectTask != nil { return .reconnecting }
        return .disconnected
    }

    public init(config: WANConfig) {
        self.config = config
        self.urlSession = URLSession(configuration: .default)
    }

    // MARK: - Connection

    public func connect() async throws {
        guard let relayURL = config.relayServerURLs.first else {
            throw WANError.relayConnectionFailed("No relay server URLs configured")
        }

        let (stream, continuation) = AsyncStream<RelayMessage>.makeStream()
        self.messageContinuation = continuation
        self._incomingMessages = stream

        let task = urlSession.webSocketTask(with: relayURL)
        self.webSocketTask = task
        task.resume()

        isConnected = true
        currentBackoff = 1.0

        receiveLoop()
    }

    public func disconnect() {
        reconnectTask?.cancel()
        reconnectTask = nil
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        isConnected = false
        messageContinuation?.finish()
    }

    /// Incoming messages from the relay server
    public var incomingMessages: AsyncStream<RelayMessage> {
        if let stream = _incomingMessages {
            return stream
        }
        return AsyncStream { $0.finish() }
    }

    // MARK: - Send

    public func send(_ message: RelayMessage) async throws {
        guard let ws = webSocketTask else {
            throw WANError.relayMessageFailed("Not connected to relay")
        }

        let data = try JSONEncoder().encode(message)
        try await ws.send(.data(data))
    }

    /// Register this node with the relay server
    public func register(capabilities: NodeCapabilities) async throws {
        let identity = config.identity
        let signatureData = try identity.sign(Data(identity.nodeID.utf8))
        let signatureHex = signatureData.map { String(format: "%02x", $0) }.joined()

        let payload = RelayMessage.RegisterPayload(
            nodeID: identity.nodeID,
            publicKey: identity.nodeID,  // nodeID is already the hex public key
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

    // MARK: - Receive Loop

    private nonisolated func receiveLoop() {
        Task { await _receiveLoop() }
    }

    private func _receiveLoop() {
        guard let ws = webSocketTask else { return }

        Task {
            do {
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

                if let message = try? JSONDecoder().decode(RelayMessage.self, from: data) {
                    messageContinuation?.yield(message)
                }

                _receiveLoop()
            } catch {
                isConnected = false
                messageContinuation?.finish()
                scheduleReconnect()
            }
        }
    }

    // MARK: - Reconnection with exponential backoff

    private func scheduleReconnect() {
        guard reconnectTask == nil else { return }

        reconnectTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self = self else { return }
                let backoff = await self.currentBackoff

                try? await Task.sleep(for: .seconds(backoff))
                guard !Task.isCancelled else { return }

                do {
                    try await self.connect()
                    await self.resetReconnect()
                    return
                } catch {
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
}

// MARK: - Relay Status

public enum RelayStatus: String, Sendable {
    case disconnected
    case connecting
    case connected
    case reconnecting
}
