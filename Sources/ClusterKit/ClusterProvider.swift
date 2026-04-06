import Foundation
import SharedTypes

// MARK: - Cluster Inference Provider

/// InferenceProvider that routes requests through the cluster.
/// In standalone mode, delegates to local provider. In cluster mode, uses RequestRouter.
public actor ClusterProvider: InferenceProvider {
    private let localProvider: any InferenceProvider
    private let clusterManager: ClusterManager
    private let router = RequestRouter()

    public init(localProvider: any InferenceProvider, clusterManager: ClusterManager) {
        self.localProvider = localProvider
        self.clusterManager = clusterManager
    }

    public var status: EngineStatus {
        get async { await localProvider.status }
    }

    public var loadedModel: ModelDescriptor? {
        get async { await localProvider.loadedModel }
    }

    public func loadModel(_ descriptor: ModelDescriptor) async throws {
        try await localProvider.loadModel(descriptor)
    }

    public func unloadModel() async {
        await localProvider.unloadModel()
    }

    // MARK: - Generate (with cluster routing)

    public nonisolated func generate(request: ChatCompletionRequest) -> AsyncThrowingStream<ChatCompletionChunk, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await self._generate(request: request, continuation: continuation)
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    private func _generate(
        request: ChatCompletionRequest,
        continuation: AsyncThrowingStream<ChatCompletionChunk, Error>.Continuation
    ) async throws {
        let localModel = await localProvider.loadedModel
        let localModelID = localModel?.huggingFaceRepo

        guard clusterManager.isEnabled else {
            // Standalone mode — delegate to local
            let stream = localProvider.generate(request: request)
            for try await chunk in stream {
                continuation.yield(chunk)
            }
            continuation.finish()
            return
        }

        let decision = router.route(
            request: request,
            clusterManager: clusterManager,
            localModelLoaded: localModelID
        )

        switch decision {
        case .local:
            let stream = localProvider.generate(request: request)
            for try await chunk in stream {
                continuation.yield(chunk)
            }
            continuation.finish()

        case .remote(_, let peer):
            peer.activeRequestCount += 1
            clusterManager.localQueueDepth += 1
            defer {
                peer.activeRequestCount -= 1
                clusterManager.localQueueDepth -= 1
            }
            try await generateRemote(request: request, peer: peer, continuation: continuation)

        case .noModelAvailable:
            throw ClusterError.noModelAvailable

        case .capacityReserved:
            throw ClusterError.capacityReserved
        }
    }

    // MARK: - Remote Generation

    private func generateRemote(
        request: ChatCompletionRequest,
        peer: PeerInfo,
        continuation: AsyncThrowingStream<ChatCompletionChunk, Error>.Continuation
    ) async throws {
        let requestID = UUID()
        let payload = InferenceRequestPayload(requestID: requestID, request: request, streaming: true)

        // Send request to peer
        try await peer.connection.send(.inferenceRequest(payload))

        // Listen for response chunks
        let messages = await peer.connection.incomingMessages
        for await message in messages {
            switch message {
            case .inferenceChunk(let chunkPayload) where chunkPayload.requestID == requestID:
                continuation.yield(chunkPayload.chunk)

            case .inferenceComplete(let completePayload) where completePayload.requestID == requestID:
                continuation.finish()
                return

            case .inferenceError(let errorPayload) where errorPayload.requestID == requestID:
                continuation.finish(throwing: ClusterError.remoteError(errorPayload.errorMessage))
                return

            default:
                continue
            }
        }

        // Connection ended unexpectedly
        continuation.finish(throwing: ClusterError.peerDisconnected)
    }
}

// MARK: - Cluster Errors

public enum ClusterError: LocalizedError, Sendable {
    case noModelAvailable
    case peerDisconnected
    case remoteError(String)
    case routingFailed
    case capacityReserved

    public var errorDescription: String? {
        switch self {
        case .noModelAvailable: return "No model loaded on any device in the cluster"
        case .peerDisconnected: return "Peer disconnected during inference"
        case .remoteError(let msg): return "Remote error: \(msg)"
        case .routingFailed: return "Failed to route request to a peer"
        case .capacityReserved: return "Capacity reserved for organization members"
        }
    }
}
