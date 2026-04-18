import Foundation
import CryptoKit
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

    /// Noise session for E2E encryption over the relay (nil = plaintext fallback for legacy peers)
    private var noiseSession: NoiseSession?

    public init(sessionID: String, remoteNodeID: String, relayClient: RelayClient) {
        self.sessionID = sessionID
        self.remoteNodeID = remoteNodeID
        self.relayClient = relayClient

        let (stream, continuation) = AsyncStream<ClusterMessage>.makeStream()
        self._incomingMessages = stream
        self.messageContinuation = continuation
    }

    /// Perform Noise handshake over the relay channel (initiator side).
    public func performHandshake(localIdentity: WANNodeIdentity, remoteWGPublicKey: Curve25519.KeyAgreement.PublicKey) async throws {
        // Send handshake message 1 via relay
        let (msg1, state) = try NoiseHandshake.initiatorBegin(
            localStatic: localIdentity.keyAgreementPrivateKey,
            remoteStaticPublic: remoteWGPublicKey
        )
        var packet = Data([0x01])
        packet.append(msg1)
        try await relayClient.sendRelayedClusterMessage(toNodeID: remoteNodeID, sessionID: sessionID, data: packet)

        // Wait for message 2
        let msg2Data = try await waitForHandshakeResponse()
        guard msg2Data.first == 0x02 else {
            throw NoiseError.handshakeFailed("Expected relay handshake response (0x02)")
        }

        let keys = try NoiseHandshake.initiatorFinish(state: state, message2: Data(msg2Data.dropFirst()))
        self.noiseSession = NoiseSession(keys: keys)
    }

    /// Perform Noise handshake over the relay channel (responder side).
    public func performResponderHandshake(localIdentity: WANNodeIdentity, message1: Data) async throws {
        guard message1.first == 0x01 else {
            throw NoiseError.handshakeFailed("Expected relay handshake initiation (0x01)")
        }

        let (msg2, keys, _) = try NoiseHandshake.responderComplete(
            localStatic: localIdentity.keyAgreementPrivateKey,
            message1: Data(message1.dropFirst())
        )

        var packet = Data([0x02])
        packet.append(msg2)
        try await relayClient.sendRelayedClusterMessage(toNodeID: remoteNodeID, sessionID: sessionID, data: packet)
        self.noiseSession = NoiseSession(keys: keys)
    }

    private var handshakeResponseContinuation: CheckedContinuation<Data, Error>?

    private func waitForHandshakeResponse() async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            self.handshakeResponseContinuation = continuation
        }
    }

    /// Called by RelayClient when raw relay data arrives during handshake
    func receiveHandshakeData(_ data: Data) {
        handshakeResponseContinuation?.resume(returning: data)
        handshakeResponseContinuation = nil
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

        let jsonData = try JSONEncoder().encode(message)

        let dataToSend: Data
        if let session = noiseSession {
            // E2E encrypted: encrypt the JSON before sending through relay
            dataToSend = try session.encrypt(jsonData)
        } else {
            // Plaintext fallback (legacy peers without WG keys)
            dataToSend = jsonData
        }

        try await relayClient.sendRelayedClusterMessage(
            toNodeID: remoteNodeID,
            sessionID: sessionID,
            data: dataToSend
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

        // During handshake phase, route raw data to the handshake continuation
        if noiseSession == nil, handshakeResponseContinuation != nil {
            receiveHandshakeData(data)
            return
        }

        let jsonData: Data
        if let session = noiseSession {
            // E2E encrypted: decrypt before decoding
            guard let decrypted = try? session.decrypt(data) else { return }
            jsonData = decrypted
        } else {
            // Plaintext fallback
            jsonData = data
        }

        do {
            let message = try JSONDecoder().decode(ClusterMessage.self, from: jsonData)
            messageContinuation?.yield(message)
        } catch {
            let preview = String(data: jsonData.prefix(200), encoding: .utf8) ?? "binary"
            FileHandle.standardError.write(Data("[WAN] RelayPeerConnection: failed to decode ClusterMessage: \(error.localizedDescription)\n    Raw: \(preview)\n".utf8))
        }
    }

    func finishLocally() {
        guard !isClosed else { return }
        isClosed = true
        messageContinuation?.finish()
    }
}
