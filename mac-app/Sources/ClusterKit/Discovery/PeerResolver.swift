import Foundation
import Network
import OSLog
import SharedTypes

// MARK: - Peer Resolver

/// Resolves a discovered Bonjour endpoint into a fully connected PeerInfo
public actor PeerResolver {
    private static let logger = Logger(subsystem: "com.teale.app", category: "ClusterResolver")
    private let localDeviceInfo: DeviceInfo
    private let passcodeHash: String?
    private let parameters: NWParameters
    private let localOwnerUserID: UUID?

    public init(
        localDeviceInfo: DeviceInfo,
        passcodeHash: String? = nil,
        parameters: NWParameters = .clusterParameters(),
        localOwnerUserID: UUID? = nil
    ) {
        self.localDeviceInfo = localDeviceInfo
        self.passcodeHash = passcodeHash
        self.parameters = parameters
        self.localOwnerUserID = localOwnerUserID
    }

    /// Connect to a discovered endpoint and perform handshake
    public func resolve(endpoint: NWEndpoint) async throws -> PeerInfo {
        Self.logger.info("Resolving endpoint=\(String(describing: endpoint), privacy: .public)")
        let connection = NWConnection(to: endpoint, using: parameters)
        let peerConnection = PeerConnection(connection: connection)
        await peerConnection.start()

        guard await peerConnection.isReady else {
            if await peerConnection.localNetworkDenied {
                throw PeerResolverError.localNetworkPermissionDenied
            }
            throw PeerResolverError.connectionFailed
        }

        // Send hello
        let hello = HelloPayload(
            deviceInfo: localDeviceInfo,
            clusterPasscodeHash: passcodeHash,
            loadedModels: localDeviceInfo.loadedModels,
            ownerUserID: localOwnerUserID
        )
        try await peerConnection.send(.hello(hello))

        // Wait for helloAck
        let messages = await peerConnection.incomingMessages
        for await message in messages {
            switch message {
            case .helloAck(let ackPayload):
                // Validate passcode
                if !ClusterSecurity.validatePasscode(local: passcodeHash, remote: ackPayload.clusterPasscodeHash) {
                    await peerConnection.cancel()
                    throw PeerResolverError.passcodeRejected
                }

                // Detect connection quality
                let quality = detectConnectionQuality(connection: connection)

                return PeerInfo(
                    deviceInfo: ackPayload.deviceInfo,
                    connection: peerConnection,
                    status: .connected,
                    connectionQuality: quality,
                    lastHeartbeat: Date(),
                    loadedModels: ackPayload.loadedModels,
                    ownerUserID: ackPayload.ownerUserID
                )

            default:
                continue  // Ignore unexpected messages during handshake
            }
        }

        throw PeerResolverError.handshakeTimeout
    }

    /// Handle an incoming connection and perform handshake
    public func acceptIncoming(connection: NWConnection) async throws -> PeerInfo {
        let peerConnection = PeerConnection(connection: connection)
        await peerConnection.start()

        guard await peerConnection.isReady else {
            if await peerConnection.localNetworkDenied {
                throw PeerResolverError.localNetworkPermissionDenied
            }
            throw PeerResolverError.connectionFailed
        }

        // Wait for hello
        let messages = await peerConnection.incomingMessages
        for await message in messages {
            switch message {
            case .hello(let helloPayload):
                // Validate passcode
                if !ClusterSecurity.validatePasscode(local: passcodeHash, remote: helloPayload.clusterPasscodeHash) {
                    await peerConnection.cancel()
                    throw PeerResolverError.passcodeRejected
                }

                // Send helloAck
                let ack = HelloPayload(
                    deviceInfo: localDeviceInfo,
                    clusterPasscodeHash: passcodeHash,
                    loadedModels: localDeviceInfo.loadedModels,
                    ownerUserID: localOwnerUserID
                )
                try await peerConnection.send(.helloAck(ack))

                let quality = detectConnectionQuality(connection: connection)

                return PeerInfo(
                    deviceInfo: helloPayload.deviceInfo,
                    connection: peerConnection,
                    status: .connected,
                    connectionQuality: quality,
                    lastHeartbeat: Date(),
                    loadedModels: helloPayload.loadedModels,
                    ownerUserID: helloPayload.ownerUserID
                )

            default:
                continue
            }
        }

        throw PeerResolverError.handshakeTimeout
    }

    // MARK: - Connection Quality Detection

    private func detectConnectionQuality(connection: NWConnection) -> ConnectionQuality {
        guard let path = connection.currentPath else { return .unknown }

        for interface in path.availableInterfaces {
            switch interface.type {
            case .wiredEthernet:
                // Check if this is a Thunderbolt bridge
                if interface.name.hasPrefix("bridge") || interface.name.hasPrefix("thunderbolt") {
                    return .thunderbolt
                }
                return .gigabit
            case .wifi:
                return .wifi
            default:
                continue
            }
        }
        return .unknown
    }
}

// MARK: - Errors

public enum PeerResolverError: LocalizedError, Sendable {
    case connectionFailed
    case handshakeTimeout
    case passcodeRejected
    case incompatibleVersion
    case localNetworkPermissionDenied

    public var errorDescription: String? {
        switch self {
        case .connectionFailed: return "Failed to connect to peer"
        case .handshakeTimeout: return "Handshake timed out"
        case .passcodeRejected: return "Cluster passcode does not match"
        case .incompatibleVersion: return "Incompatible protocol version"
        case .localNetworkPermissionDenied: return "Local Network access is blocked for Teale"
        }
    }
}
