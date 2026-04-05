import Foundation
import SharedTypes
import ClusterKit

// MARK: - WAN Inference Provider

/// InferenceProvider that routes requests to WAN peers.
/// Falls back to a local provider when no WAN peer is available.
public actor WANProvider: InferenceProvider {
    private let localProvider: any InferenceProvider
    private let wanManager: WANManager
    private let wanTimeoutSeconds: TimeInterval

    public init(
        localProvider: any InferenceProvider,
        wanManager: WANManager,
        wanTimeoutSeconds: TimeInterval = 120
    ) {
        self.localProvider = localProvider
        self.wanManager = wanManager
        self.wanTimeoutSeconds = wanTimeoutSeconds
    }

    // MARK: - InferenceProvider conformance

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

    // MARK: - Generate (with WAN routing)

    public nonisolated func generate(request: ChatCompletionRequest) -> AsyncThrowingStream<ChatCompletionChunk, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    try await self._generate(request: request, continuation: continuation)
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    private func _generate(
        request: ChatCompletionRequest,
        continuation: AsyncThrowingStream<ChatCompletionChunk, Error>.Continuation
    ) async throws {
        let localModel = await localProvider.loadedModel
        let requestedModel = request.model

        // If WAN is not enabled, always use local
        guard wanManager.isEnabled else {
            let stream = localProvider.generate(request: request)
            for try await chunk in stream {
                continuation.yield(chunk)
            }
            continuation.finish()
            return
        }

        // If the requested model matches the local model, prefer local
        if let requestedModel = requestedModel,
           let localModel = localModel,
           localModel.huggingFaceRepo == requestedModel {
            let stream = localProvider.generate(request: request)
            for try await chunk in stream {
                continuation.yield(chunk)
            }
            continuation.finish()
            return
        }

        // Try to find a WAN peer with the requested model
        if let requestedModel = requestedModel,
           let connection = wanManager.connectionForPeer(withModel: requestedModel) {
            do {
                try await generateRemote(
                    request: request,
                    connection: connection,
                    continuation: continuation
                )
                return
            } catch {
                // WAN peer failed, fall through to local
            }
        }

        // Fall back to local provider
        let stream = localProvider.generate(request: request)
        for try await chunk in stream {
            continuation.yield(chunk)
        }
        continuation.finish()
    }

    // MARK: - Remote Generation

    private func generateRemote(
        request: ChatCompletionRequest,
        connection: WANPeerConnection,
        continuation: AsyncThrowingStream<ChatCompletionChunk, Error>.Continuation
    ) async throws {
        let requestID = UUID()
        let payload = InferenceRequestPayload(
            requestID: requestID,
            request: request,
            streaming: true
        )

        // Send request
        try await connection.send(.inferenceRequest(payload))

        // Listen for response with timeout
        let messages = await connection.incomingMessages

        try await withThrowingTaskGroup(of: Void.self) { group in
            // Timeout task
            group.addTask {
                try await Task.sleep(for: .seconds(self.wanTimeoutSeconds))
                throw WANError.timeout
            }

            // Message processing task
            group.addTask {
                for await message in messages {
                    switch message {
                    case .inferenceChunk(let chunk) where chunk.requestID == requestID:
                        continuation.yield(chunk.chunk)

                    case .inferenceComplete(let complete) where complete.requestID == requestID:
                        continuation.finish()
                        return

                    case .inferenceError(let error) where error.requestID == requestID:
                        throw WANError.peerConnectionFailed(error.errorMessage)

                    default:
                        continue
                    }
                }
                throw WANError.peerDisconnected
            }

            // Wait for either completion or timeout
            do {
                try await group.next()
            } catch {
                group.cancelAll()
                throw error
            }
            group.cancelAll()
        }
    }
}
