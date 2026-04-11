import Foundation
import Network
import CryptoKit
import ClusterKit
import Darwin

// MARK: - Hole Punch Result

public enum HolePunchResult: Sendable {
    case direct(WANTransportConnection)
    case relayed(WANTransportConnection)
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
    /// Tries direct WireGuard first, then falls back to relay.
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
            localIP: Self.preferredLocalIPv4Address(),
            localPort: localMapping.publicPort,
            natType: localNATType,
            wgPublicKey: identity.wgPublicKeyHex
        )

        try await relayClient.sendOffer(
            toNodeID: peerInfo.nodeID,
            sessionID: sessionID,
            connectionInfo: connectionInfo
        )

        // Step 4: Wait for answer from the peer
        let answer = try await waitForAnswer(fromNodeID: peerInfo.nodeID, sessionID: sessionID)

        // Resolve remote WG public key (from answer or peer info)
        let remoteWGKeyHex = answer.connectionInfo.wgPublicKey ?? peerInfo.wgPublicKey
        let remoteWGKey: Curve25519.KeyAgreement.PublicKey? = remoteWGKeyHex.flatMap { hex in
            guard let data = Data(hexString: hex) else { return nil }
            return try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: data)
        }

        // Step 5: Attempt direct WireGuard connection if NAT types are compatible
        if canDirect, let wgKey = remoteWGKey {
            if localMapping.publicIP == answer.connectionInfo.publicIP,
               let localIP = answer.connectionInfo.localIP,
               let localPort = answer.connectionInfo.localPort {
                do {
                    let sameLANConn = try await attemptDirectConnection(
                        toHost: localIP,
                        port: localPort,
                        remoteNodeID: peerInfo.nodeID,
                        remoteWGPublicKey: wgKey
                    )
                    return .direct(.direct(sameLANConn))
                } catch {
                    // Fall through to the public endpoint attempt.
                }
            }

            do {
                let directConn = try await attemptDirectConnection(
                    toHost: answer.connectionInfo.publicIP,
                    port: answer.connectionInfo.publicPort,
                    remoteNodeID: peerInfo.nodeID,
                    remoteWGPublicKey: wgKey
                )
                return .direct(.direct(directConn))
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
    ) async throws -> WireGuardPeerConnection {
        // Discover our public endpoint
        let localMapping = try await stunClient.discoverMapping()
        let localNATType = try await stunClient.detectNATType()

        // Send answer back
        let connectionInfo = ConnectionInfo(
            publicIP: localMapping.publicIP,
            publicPort: localMapping.publicPort,
            localIP: Self.preferredLocalIPv4Address(),
            localPort: localMapping.publicPort,
            natType: localNATType,
            wgPublicKey: identity.wgPublicKeyHex
        )

        try await relayClient.sendAnswer(
            toNodeID: offer.fromNodeID,
            sessionID: offer.sessionID,
            connectionInfo: connectionInfo
        )

        // Resolve remote WG public key from offer
        guard let remoteWGKeyHex = offer.connectionInfo.wgPublicKey,
              let keyData = Data(hexString: remoteWGKeyHex),
              let remoteWGKey = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: keyData) else {
            throw WANError.invalidPublicKey
        }

        // Attempt direct connection to offerer
        if localMapping.publicIP == offer.connectionInfo.publicIP,
           let localIP = offer.connectionInfo.localIP,
           let localPort = offer.connectionInfo.localPort {
            do {
                return try await attemptDirectConnection(
                    toHost: localIP,
                    port: localPort,
                    remoteNodeID: offer.fromNodeID,
                    remoteWGPublicKey: remoteWGKey
                )
            } catch {
                // Fall through to the public endpoint attempt.
            }
        }

        let peerConnection = try await attemptDirectConnection(
            toHost: offer.connectionInfo.publicIP,
            port: offer.connectionInfo.publicPort,
            remoteNodeID: offer.fromNodeID,
            remoteWGPublicKey: remoteWGKey
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

    /// Attempt a direct WireGuard connection to the peer's endpoint
    private func attemptDirectConnection(
        toHost host: String,
        port: UInt16,
        remoteNodeID: String,
        remoteWGPublicKey: Curve25519.KeyAgreement.PublicKey
    ) async throws -> WireGuardPeerConnection {
        let peerConn = WireGuardTransport.connect(
            to: host,
            port: port,
            remoteNodeID: remoteNodeID,
            remoteWGPublicKey: remoteWGPublicKey,
            localIdentity: identity
        )

        await peerConn.start()

        let isReady = await peerConn.isReady
        guard isReady else {
            await peerConn.cancel()
            throw WANError.peerConnectionFailed("Direct WireGuard connection timed out")
        }

        // Noise handshake authenticates peers via static keys — no additional auth needed
        return peerConn
    }

    /// Attempt a relayed connection (data goes through relay server)
    private func attemptRelayedConnection(
        to peer: WANPeerInfo,
        sessionID: String
    ) async throws -> WANTransportConnection {
        let connection = try await relayClient.openRelayedSession(
            toNodeID: peer.nodeID,
            sessionID: sessionID,
            timeoutSeconds: timeoutSeconds
        )
        return .relayed(connection)
    }

    private static func preferredLocalIPv4Address() -> String? {
        var interfaces: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaces) == 0, let first = interfaces else { return nil }
        defer { freeifaddrs(interfaces) }

        var preferred: String?
        var candidate = first

        while true {
            let iface = candidate.pointee
            let name = String(cString: iface.ifa_name)
            let flags = Int32(iface.ifa_flags)

            if let address = iface.ifa_addr,
               address.pointee.sa_family == UInt8(AF_INET),
               (flags & IFF_UP) != 0,
               (flags & IFF_RUNNING) != 0,
               (flags & IFF_LOOPBACK) == 0,
               !isTunnelInterface(name) {
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                let result = getnameinfo(
                    address,
                    socklen_t(address.pointee.sa_len),
                    &host,
                    socklen_t(host.count),
                    nil,
                    0,
                    NI_NUMERICHOST
                )

                if result == 0 {
                    let ip = String(cString: host)
                    if name.hasPrefix("en"), isPrivateIPv4(ip) {
                        return ip
                    }
                    if preferred == nil, isPrivateIPv4(ip) {
                        preferred = ip
                    }
                }
            }

            guard let next = iface.ifa_next else { break }
            candidate = next
        }

        return preferred
    }

    private static func isTunnelInterface(_ name: String) -> Bool {
        name.hasPrefix("utun") ||
        name.hasPrefix("tun") ||
        name.hasPrefix("tap") ||
        name.hasPrefix("ipsec") ||
        name.hasPrefix("ppp")
    }

    private static func isPrivateIPv4(_ ip: String) -> Bool {
        let octets = ip.split(separator: ".").compactMap { Int($0) }
        guard octets.count == 4 else { return false }

        if octets[0] == 10 { return true }
        if octets[0] == 192, octets[1] == 168 { return true }
        if octets[0] == 172, (16...31).contains(octets[1]) { return true }
        return false
    }
}
