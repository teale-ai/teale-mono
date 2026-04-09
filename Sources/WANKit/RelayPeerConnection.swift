import Foundation
import ClusterKit

public enum WANTransportConnection: Sendable {
    case direct(WireGuardPeerConnection)
    case relayed(RelayPeerConnection)

    public var remoteNodeID: String {
        switch self {
        case .direct(let connection):
            return connection.remoteNodeID
        case .relayed(let connection):
            return connection.remoteNodeID
        }
    }

    public func send(_ message: ClusterMessage) async throws {
        switch self {
        case .direct(let connection):
            try await connection.send(message)
        case .relayed(let connection):
            try await connection.send(message)
        }
    }

    public var incomingMessages: AsyncStream<ClusterMessage> {
        get async {
            switch self {
            case .direct(let connection):
                return await connection.incomingMessages
            case .relayed(let connection):
                return await connection.incomingMessages
            }
        }
    }

    public func cancel() async {
        switch self {
        case .direct(let connection):
            await connection.cancel()
        case .relayed(let connection):
            await connection.cancel()
        }
    }
}

public actor RelayPeerConnection {
    public let sessionID: String
    public let remoteNodeID: String

    private let relayClient: RelayClient
    private var messageContinuation: AsyncStream<ClusterMessage>.Continuation?
    private var _incomingMessages: AsyncStream<ClusterMessage>?
    private var isClosed = false

    public init(sessionID: String, remoteNodeID: String, relayClient: RelayClient) {
        self.sessionID = sessionID
        self.remoteNodeID = remoteNodeID
        self.relayClient = relayClient

        let (stream, continuation) = AsyncStream<ClusterMessage>.makeStream()
        self._incomingMessages = stream
        self.messageContinuation = continuation
    }

    public var incomingMessages: AsyncStream<ClusterMessage> {
        if let stream = _incomingMessages {
            return stream
        }
        return AsyncStream { $0.finish() }
    }

    public func send(_ message: ClusterMessage) async throws {
        guard !isClosed else {
            throw WANError.peerDisconnected
        }

        let data = try JSONEncoder().encode(message)
        try await relayClient.sendRelayedClusterMessage(
            toNodeID: remoteNodeID,
            sessionID: sessionID,
            data: data
        )
    }

    public func cancel() async {
        guard !isClosed else { return }
        isClosed = true
        messageContinuation?.finish()
        await relayClient.closeRelayedSession(
            sessionID: sessionID,
            toNodeID: remoteNodeID,
            notifyRemote: true
        )
    }

    func receiveRelayedClusterMessage(_ data: Data) {
        guard !isClosed else { return }
        guard let message = try? JSONDecoder().decode(ClusterMessage.self, from: data) else {
            return
        }
        messageContinuation?.yield(message)
    }

    func finishLocally() {
        guard !isClosed else { return }
        isClosed = true
        messageContinuation?.finish()
    }
}
