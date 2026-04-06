import Foundation
import Network

// MARK: - Peer Connection

/// Wraps NWConnection to provide typed async message send/receive
public actor PeerConnection {
    public let connection: NWConnection
    public let peerID: UUID?
    private var messageContinuation: AsyncStream<ClusterMessage>.Continuation?
    private var _incomingMessages: AsyncStream<ClusterMessage>?
    public private(set) var isReady: Bool = false

    public init(connection: NWConnection, peerID: UUID? = nil) {
        self.connection = connection
        self.peerID = peerID
    }

    private static var clusterContentContext: NWConnection.ContentContext {
        let message = NWProtocolFramer.Message(definition: ClusterMessageFramer.definition)
        return NWConnection.ContentContext(
            identifier: ClusterMessageFramer.label,
            metadata: [message]
        )
    }

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
        get async {
            if let stream = _incomingMessages {
                return stream
            }
            // Create and return an empty stream if not started
            return AsyncStream { $0.finish() }
        }
    }

    /// Send a message to the peer
    public func send(_ message: ClusterMessage) async throws {
        let data = try JSONEncoder().encode(message)

        return try await withCheckedThrowingContinuation { continuation in
            connection.send(
                content: data,
                contentContext: Self.clusterContentContext,
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
        connection.cancel()
        messageContinuation?.finish()
    }

    // MARK: - Private

    private func handleStateChange(_ state: NWConnection.State) {
        switch state {
        case .ready:
            isReady = true
        case .failed, .cancelled:
            isReady = false
            messageContinuation?.finish()
        default:
            break
        }
    }

    private func waitForReady() async {
        // Wait up to 10 seconds for connection to be ready
        for _ in 0..<100 {
            if isReady { return }
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    private nonisolated func receiveNextMessage() {
        connection.receiveMessage { [weak self] content, context, isComplete, error in
            guard let self = self else { return }

            if let content, !content.isEmpty,
               let message = try? JSONDecoder().decode(ClusterMessage.self, from: content) {
                Task { await self.deliverMessage(message) }
            }

            if error == nil {
                self.receiveNextMessage()
            }
        }
    }

    private func deliverMessage(_ message: ClusterMessage) {
        messageContinuation?.yield(message)
    }
}
