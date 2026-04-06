import Foundation
import Network
import CryptoKit
import ClusterKit

// MARK: - WAN Peer Connection (QUIC-based transport)

public actor WANPeerConnection {
    public let remoteNodeID: String
    public let connection: NWConnection
    private var messageContinuation: AsyncStream<ClusterMessage>.Continuation?
    private var _incomingMessages: AsyncStream<ClusterMessage>?
    public private(set) var isReady: Bool = false
    public private(set) var connectionState: WANConnectionState = .connecting

    public init(connection: NWConnection, remoteNodeID: String) {
        self.connection = connection
        self.remoteNodeID = remoteNodeID
    }

    // MARK: - Lifecycle

    /// Start the connection and begin receiving messages
    public func start() async {
        let (stream, continuation) = AsyncStream<ClusterMessage>.makeStream()
        self.messageContinuation = continuation
        self._incomingMessages = stream

        connection.stateUpdateHandler = { [weak self] state in
            Task { await self?.handleStateChange(state) }
        }

        connection.start(queue: .global(qos: .userInitiated))
        await waitForReady()
        receiveNextMessage()
    }

    /// Incoming messages as an async stream
    public var incomingMessages: AsyncStream<ClusterMessage> {
        if let stream = _incomingMessages {
            return stream
        }
        return AsyncStream { $0.finish() }
    }

    /// Send a ClusterMessage to the peer
    public func send(_ message: ClusterMessage) async throws {
        let data = try JSONEncoder().encode(message)

        // Length-prefix the message (4 bytes big-endian)
        var length = UInt32(data.count).bigEndian
        var framed = Data(bytes: &length, count: 4)
        framed.append(data)

        return try await withCheckedThrowingContinuation { continuation in
            connection.send(
                content: framed,
                contentContext: .defaultMessage,
                isComplete: true,
                completion: .contentProcessed { error in
                    if let error = error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume()
                    }
                }
            )
        }
    }

    /// Cancel the connection
    public func cancel() {
        connectionState = .disconnected
        connection.cancel()
        messageContinuation?.finish()
    }

    // MARK: - Private

    private func handleStateChange(_ state: NWConnection.State) {
        switch state {
        case .ready:
            isReady = true
            connectionState = .connected
        case .failed(let error):
            isReady = false
            connectionState = .failed(error.localizedDescription)
            messageContinuation?.finish()
        case .cancelled:
            isReady = false
            connectionState = .disconnected
            messageContinuation?.finish()
        case .waiting(let error):
            connectionState = .waiting(error.localizedDescription)
        default:
            break
        }
    }

    private func waitForReady() async {
        for _ in 0..<300 {
            if isReady { return }
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    private nonisolated func receiveNextMessage() {
        // Read length prefix (4 bytes)
        connection.receive(minimumIncompleteLength: 4, maximumLength: 4) { [weak self] lengthData, _, _, error in
            guard let self = self else { return }

            guard let lengthData = lengthData, lengthData.count == 4 else {
                if error != nil {
                    Task { await self.handleReceiveError() }
                }
                return
            }

            let length = lengthData.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
            guard length > 0, length < 10_000_000 else {
                // Invalid length, skip and continue
                self.receiveNextMessage()
                return
            }

            // Read message body
            self.connection.receive(minimumIncompleteLength: Int(length), maximumLength: Int(length)) { [weak self] bodyData, _, _, error in
                guard let self = self else { return }

                if let bodyData = bodyData,
                   let message = try? JSONDecoder().decode(ClusterMessage.self, from: bodyData) {
                    Task { await self.deliverMessage(message) }
                }

                if error == nil {
                    self.receiveNextMessage()
                } else {
                    Task { await self.handleReceiveError() }
                }
            }
        }
    }

    private func deliverMessage(_ message: ClusterMessage) {
        messageContinuation?.yield(message)
    }

    private func handleReceiveError() {
        connectionState = .disconnected
        messageContinuation?.finish()
    }
}

// MARK: - Connection State

public enum WANConnectionState: Sendable {
    case connecting
    case connected
    case waiting(String)
    case failed(String)
    case disconnected
}

// MARK: - QUIC Transport Factory

public enum QUICTransport {

    /// Create QUIC parameters for outgoing connections
    public static func clientParameters(identity: WANNodeIdentity) -> NWParameters {
        let quicOptions = NWProtocolQUIC.Options(alpn: ["teale-wan-1"])

        // Configure TLS with an insecure option for self-signed certs
        // In production, verify against known certificate fingerprints
        let securityOptions = quicOptions.securityProtocolOptions
        sec_protocol_options_set_verify_block(securityOptions, { _, _, completionHandler in
            // Accept self-signed certs — we verify identity via Ed25519 signatures
            completionHandler(true)
        }, .global(qos: .userInitiated))

        let params = NWParameters(quic: quicOptions)
        return params
    }

    /// Create QUIC parameters for a listener
    public static func listenerParameters(identity: WANNodeIdentity) -> NWParameters {
        let quicOptions = NWProtocolQUIC.Options(alpn: ["teale-wan-1"])

        // Use an identity for TLS
        // For now, use an insecure configuration as we verify via Ed25519
        let securityOptions = quicOptions.securityProtocolOptions
        sec_protocol_options_set_verify_block(securityOptions, { _, _, completionHandler in
            completionHandler(true)
        }, .global(qos: .userInitiated))

        let params = NWParameters(quic: quicOptions)
        return params
    }

    /// Connect to a WAN peer via QUIC
    public static func connect(
        to host: String,
        port: UInt16,
        remoteNodeID: String,
        identity: WANNodeIdentity
    ) -> WANPeerConnection {
        let nwHost = NWEndpoint.Host(host)
        let nwPort = NWEndpoint.Port(rawValue: port)!
        let params = clientParameters(identity: identity)

        let connection = NWConnection(host: nwHost, port: nwPort, using: params)
        return WANPeerConnection(connection: connection, remoteNodeID: remoteNodeID)
    }

    /// Create a QUIC listener for incoming WAN connections
    public static func createListener(
        port: UInt16,
        identity: WANNodeIdentity
    ) throws -> NWListener {
        let params = listenerParameters(identity: identity)
        let listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
        return listener
    }
}
