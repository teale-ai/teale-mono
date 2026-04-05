import Foundation
import Network
import ClusterKit

// MARK: - Hole Punch Result

public enum HolePunchResult: Sendable {
    case direct(WANPeerConnection)
    case relayed(WANPeerConnection)
    case failed(WANError)
}

// MARK: - NAT Traversal Coordinator

public actor NATTraversal {
    private let stunClient: STUNClient
    private let relayClient: RelayClient
    private let identity: WANNodeIdentity
    private let timeoutSeconds: TimeInterval

    public init(
        stunClient: STUNClient,
        relayClient: RelayClient,
        identity: WANNodeIdentity,
        timeoutSeconds: TimeInterval = 30
    ) {
        self.stunClient = stunClient
        self.relayClient = relayClient
        self.identity = identity
        self.timeoutSeconds = timeoutSeconds
    }

    // MARK: - Public API

    /// Discover our public endpoint via STUN
    public func discoverPublicEndpoint() async throws -> NATMapping {
        try await stunClient.discoverMapping()
    }

    /// Detect our NAT type
    public func detectNATType() async throws -> NATType {
        try await stunClient.detectNATType()
    }

    /// Attempt to establish a P2P connection with a remote peer.
    /// Tries direct QUIC first, then falls back to relay.
    public func connectToPeer(
        peerInfo: WANPeerInfo,
        sessionID: String
    ) async throws -> HolePunchResult {
        // Step 1: Discover our own public endpoint
        let localMapping: NATMapping
        do {
            localMapping = try await stunClient.discoverMapping()
        } catch {
            return .failed(.natTraversalFailed("Failed to discover local mapping: \(error.localizedDescription)"))
        }

        // Step 2: Determine if direct connection is feasible
        let localNATType = try await stunClient.detectNATType()
        let remoteNATType = peerInfo.natType

        let canDirect = localNATType.canHolePunch && remoteNATType.canHolePunch

        // Step 3: Exchange connection info via relay
        let connectionInfo = ConnectionInfo(
            publicIP: localMapping.publicIP,
            publicPort: localMapping.publicPort,
            natType: localNATType
        )

        try await relayClient.sendOffer(
            toNodeID: peerInfo.nodeID,
            sessionID: sessionID,
            connectionInfo: connectionInfo
        )

        // Step 4: Wait for answer from the peer
        let answer = try await waitForAnswer(fromNodeID: peerInfo.nodeID, sessionID: sessionID)

        // Step 5: Attempt direct QUIC connection if NAT types are compatible
        if canDirect {
            do {
                let directConn = try await attemptDirectConnection(
                    to: answer.connectionInfo,
                    remoteNodeID: peerInfo.nodeID
                )
                return .direct(directConn)
            } catch {
                // Direct connection failed, fall through to relay
            }
        }

        // Step 6: Fall back to relay-assisted connection
        do {
            let relayedConn = try await attemptRelayedConnection(
                to: peerInfo,
                sessionID: sessionID
            )
            return .relayed(relayedConn)
        } catch {
            return .failed(.natTraversalFailed("All connection methods failed"))
        }
    }

    /// Handle an incoming connection offer (called when we receive an offer from relay)
    public func handleIncomingOffer(
        offer: RelayMessage.OfferPayload
    ) async throws -> WANPeerConnection {
        // Discover our public endpoint
        let localMapping = try await stunClient.discoverMapping()
        let localNATType = try await stunClient.detectNATType()

        // Send answer back
        let connectionInfo = ConnectionInfo(
            publicIP: localMapping.publicIP,
            publicPort: localMapping.publicPort,
            natType: localNATType
        )

        try await relayClient.sendAnswer(
            toNodeID: offer.fromNodeID,
            sessionID: offer.sessionID,
            connectionInfo: connectionInfo
        )

        // Attempt direct connection to offerer
        let peerConnection = try await attemptDirectConnection(
            to: offer.connectionInfo,
            remoteNodeID: offer.fromNodeID
        )

        return peerConnection
    }

    // MARK: - Private

    /// Wait for an answer from a specific peer
    private func waitForAnswer(
        fromNodeID: String,
        sessionID: String
    ) async throws -> RelayMessage.AnswerPayload {
        let messages = await relayClient.incomingMessages

        return try await withThrowingTaskGroup(of: RelayMessage.AnswerPayload.self) { group in
            group.addTask {
                for await message in messages {
                    if case .answer(let payload) = message,
                       payload.fromNodeID == fromNodeID,
                       payload.sessionID == sessionID {
                        return payload
                    }
                }
                throw WANError.natTraversalFailed("Relay connection ended while waiting for answer")
            }

            group.addTask {
                try await Task.sleep(for: .seconds(self.timeoutSeconds))
                throw WANError.timeout
            }

            guard let result = try await group.next() else {
                throw WANError.timeout
            }
            group.cancelAll()
            return result
        }
    }

    /// Attempt a direct QUIC connection to the peer's public endpoint
    private func attemptDirectConnection(
        to info: ConnectionInfo,
        remoteNodeID: String
    ) async throws -> WANPeerConnection {
        let peerConn = QUICTransport.connect(
            to: info.publicIP,
            port: info.publicPort,
            remoteNodeID: remoteNodeID,
            identity: identity
        )

        await peerConn.start()

        let isReady = await peerConn.isReady
        guard isReady else {
            await peerConn.cancel()
            throw WANError.peerConnectionFailed("Direct QUIC connection timed out")
        }

        // Authenticate: send a signed hello
        try await authenticateConnection(peerConn, remoteNodeID: remoteNodeID)

        return peerConn
    }

    /// Attempt a relayed connection (data goes through relay server)
    private func attemptRelayedConnection(
        to peer: WANPeerInfo,
        sessionID: String
    ) async throws -> WANPeerConnection {
        // For relay-assisted connections, we'd connect to the relay server's
        // data channel and the relay forwards packets between peers.
        // This is a placeholder — the relay server would need to support
        // a TURN-like data forwarding mode.
        throw WANError.natTraversalFailed("Relay-assisted connections not yet implemented")
    }

    /// Authenticate a connection by exchanging signed messages
    private func authenticateConnection(
        _ connection: WANPeerConnection,
        remoteNodeID: String
    ) async throws {
        // Create a challenge-response authentication
        let challenge = UUID().uuidString
        let signedChallenge = try identity.sign(Data(challenge.utf8))

        // Send auth hello via a ClusterMessage heartbeat with our nodeID in loadedModels
        // (Reusing existing ClusterMessage protocol — auth messages could be a future extension)
        let authPayload = HeartbeatPayload(
            deviceID: UUID(),  // placeholder
            timestamp: Date(),
            loadedModels: [identity.nodeID, challenge,
                           signedChallenge.map { String(format: "%02x", $0) }.joined()]
        )
        try await connection.send(.heartbeat(authPayload))
    }
}
