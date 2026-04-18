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

    /// Called after a successful remote inference with (tokenCount, modelName, peerNodeID).
    private var _onRemoteInferenceCompleted: (@Sendable (Int, String, String) async -> Void)?

    public func setOnRemoteInferenceCompleted(_ handler: @escaping @Sendable (Int, String, String) async -> Void) {
        _onRemoteInferenceCompleted = handler
    }

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

        // If there is no explicit request model, prefer local if we already have a model loaded.
        if requestedModel == nil, localModelID != nil {
            let stream = localProvider.generate(request: request)
            for try await chunk in stream {
                continuation.yield(chunk)
            }
            continuation.finish()
            return
        }

        // Otherwise route to a connected WAN peer if one is serving a suitable model.
        // Group-first: if groupID is set, prefer group peers.
        if let peer = wanManager.connectedPeerForInference(preferredModel: requestedModel, groupID: request.groupID) {
            do {
                var proxiedRequest = request
                proxiedRequest.model = proxiedRequest.model ?? peer.peerInfo.capabilities.loadedModels.first
                try await generateRemote(
                    request: proxiedRequest,
                    connection: peer.connection,
                    continuation: continuation
                )
                return
            } catch {
                // WAN peer failed, fall through to next option
            }
        }

        // If no local model is loaded, try any available WAN peer (with failover)
        if localModel == nil {
            for connection in wanManager.allAvailableConnections() {
                do {
                    try await generateRemote(
                        request: request,
                        connection: connection,
                        continuation: continuation
                    )
                    return
                } catch {
                    // This peer failed, try next one
                    continue
                }
            }
        }

        if localModelID == nil {
            throw WANError.noWANPeerAvailable
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
        connection: WANTransportConnection,
        continuation: AsyncThrowingStream<ChatCompletionChunk, Error>.Continuation
    ) async throws {
        let requestID = UUID()
        let payload = InferenceRequestPayload(
            requestID: requestID,
            request: request,
            streaming: true
        )

        // Subscribe before sending so a fast peer cannot race the reply past us.
        let messages = await connection.incomingMessages
        try await connection.send(.inferenceRequest(payload))

        try await withThrowingTaskGroup(of: Void.self) { group in
            // Timeout task
            group.addTask {
                try await Task.sleep(for: .seconds(self.wanTimeoutSeconds))
                throw WANError.timeout
            }

            // Message processing task
            group.addTask {
                var totalTokens = 0
                for await message in messages {
                    switch message {
                    case .inferenceChunk(let chunk) where chunk.requestID == requestID:
                        if let content = chunk.chunk.choices.first?.delta.content {
                            totalTokens += max(content.count / 4, 1)
                        }
                        continuation.yield(chunk.chunk)

                    case .inferenceComplete(let complete) where complete.requestID == requestID:
                        continuation.finish()
                        // Record spending via callback
                        if totalTokens > 0 {
                            let model = request.model ?? "unknown"
                            let peer = connection.remoteNodeID
                            await self._onRemoteInferenceCompleted?(totalTokens, model, peer)
                        }
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
