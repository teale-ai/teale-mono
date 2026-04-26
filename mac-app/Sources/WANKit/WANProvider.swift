import Foundation
import SharedTypes
import ClusterKit
import PrivacyFilterKit

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
           localModel.matchesIdentifier(requestedModel) {
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

        // If the local provider (which may be a ClusterProvider) can handle this request,
        // prefer it over WAN — LAN is faster and free.
        if localModel == nil {
            let localStream = localProvider.generate(request: request)
            var gotChunks = false
            do {
                for try await chunk in localStream {
                    gotChunks = true
                    continuation.yield(chunk)
                }
                if gotChunks {
                    continuation.finish()
                    return
                }
            } catch {
                if gotChunks {
                    continuation.finish(throwing: error)
                    return
                }
                // Local/cluster couldn't handle it, fall through to WAN
            }
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

        // If the right model is discoverable over WAN but not yet connected,
        // opportunistically establish that connection on demand and retry once.
        if let requestedModel {
            let discoveredPeers = await wanManager.discoveredPeers()
                .filter { $0.hasModel(requestedModel) && $0.wgPublicKey != nil && $0.capabilities.isAvailable }
                .sorted { lhs, rhs in
                    lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
                }

            for discoveredPeer in discoveredPeers {
                do {
                    try await wanManager.connectToPeer(nodeID: discoveredPeer.nodeID)

                    if let connectedPeer = wanManager.connectedPeerForInference(
                        preferredModel: requestedModel,
                        groupID: request.groupID
                    ) {
                        var proxiedRequest = request
                        proxiedRequest.model = proxiedRequest.model ?? connectedPeer.peerInfo.capabilities.loadedModels.first
                        try await generateRemote(
                            request: proxiedRequest,
                            connection: connectedPeer.connection,
                            continuation: continuation
                        )
                        return
                    }
                } catch {
                    continue
                }
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

        // Fall back to local provider only for implicit routing or when the
        // local model actually matches the explicit request.
        if let requestedModel = requestedModel {
            let localCandidates = [localModel?.id, localModel?.huggingFaceRepo, localModel?.openrouterId]
                .compactMap { $0?.lowercased().replacingOccurrences(of: "_", with: "-") }
            let normalizedRequested = requestedModel.lowercased().replacingOccurrences(of: "_", with: "-")
            let requestedTail = normalizedRequested.split(separator: "/").last.map(String.init) ?? normalizedRequested
            let matchesLocal = localCandidates.contains { candidate in
                if candidate == normalizedRequested { return true }
                let candidateTail = candidate.split(separator: "/").last.map(String.init) ?? candidate
                return candidateTail == requestedTail
            }
            guard matchesLocal else {
                throw WANError.noWANPeerAvailable
            }
        }

        let stream = localProvider.generate(request: request)
        for try await chunk in stream {
            continuation.yield(chunk)
        }
        continuation.finish()
    }

    // MARK: - Public Targeted Dispatch

    /// Execute a full (non-streaming) inference request on a specific WAN peer by node ID.
    /// Used by CompilerKit for targeted sub-task dispatch.
    public func generateFull(onPeerNodeID nodeID: String, request: ChatCompletionRequest) async throws -> ChatCompletionResponse {
        guard let connection = wanManager.connectedPeers(byNodeID: nodeID) else {
            throw WANError.peerDisconnected
        }

        let prepared = try await preparedRemoteRequest(from: request)
        let requestID = UUID()
        let payload = InferenceRequestPayload(
            requestID: requestID,
            request: prepared.request,
            streaming: true
        )

        let messages = await connection.incomingMessages
        try await connection.send(.inferenceRequest(payload))

        return try await withThrowingTaskGroup(of: ChatCompletionResponse.self) { group in
            // Timeout task
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(self.wanTimeoutSeconds) * 1_000_000_000)
                throw WANError.timeout
            }

            // Message processing task
            group.addTask {
                var totalTokens = 0
                var fullContent = ""
                for await message in messages {
                    switch message {
                    case .inferenceChunk(let chunk) where chunk.requestID == requestID:
                        if let content = chunk.chunk.choices.first?.delta.content {
                            totalTokens += max(content.count / 4, 1)
                            fullContent += content
                        }
                        if chunk.chunk.choices.first?.finishReason != nil {
                            if totalTokens > 0 {
                                let model = request.model ?? "unknown"
                            await self._onRemoteInferenceCompleted?(totalTokens, model, nodeID)
                        }
                        return prepared.restoreResponse(ChatCompletionResponse(
                            id: "chatcmpl-\(requestID.uuidString)",
                            model: prepared.request.model ?? "unknown",
                            choices: [
                                .init(index: 0, message: APIMessage(role: "assistant", content: fullContent), finishReason: "stop")
                            ],
                            usage: .init(promptTokens: 0, completionTokens: totalTokens, totalTokens: totalTokens)
                        ))
                    }

                    case .inferenceComplete(let complete) where complete.requestID == requestID:
                        if totalTokens > 0 {
                            let model = prepared.request.model ?? "unknown"
                            await self._onRemoteInferenceCompleted?(totalTokens, model, nodeID)
                        }
                        return prepared.restoreResponse(ChatCompletionResponse(
                            id: "chatcmpl-\(requestID.uuidString)",
                            model: prepared.request.model ?? "unknown",
                            choices: [
                                .init(index: 0, message: APIMessage(role: "assistant", content: fullContent), finishReason: "stop")
                            ],
                            usage: .init(promptTokens: 0, completionTokens: totalTokens, totalTokens: totalTokens)
                        ))

                    case .inferenceError(let error) where error.requestID == requestID:
                        throw WANError.peerConnectionFailed(error.errorMessage)

                    default:
                        continue
                    }
                }
                throw WANError.peerDisconnected
            }

            do {
                let result = try await group.next()!
                group.cancelAll()
                return result
            } catch {
                group.cancelAll()
                throw error
            }
        }
    }

    // MARK: - Remote Generation

    private func generateRemote(
        request: ChatCompletionRequest,
        connection: WANTransportConnection,
        continuation: AsyncThrowingStream<ChatCompletionChunk, Error>.Continuation
    ) async throws {
        let prepared = try await preparedRemoteRequest(from: request)
        let requestID = UUID()
        let payload = InferenceRequestPayload(
            requestID: requestID,
            request: prepared.request,
            streaming: true
        )

        // Subscribe before sending so a fast peer cannot race the reply past us.
        let messages = await connection.incomingMessages
        try await connection.send(.inferenceRequest(payload))
        let restorer = prepared.makeStreamingRestorer()

        try await withThrowingTaskGroup(of: Void.self) { group in
            // Timeout task
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(self.wanTimeoutSeconds) * 1_000_000_000)
                throw WANError.timeout
            }

            // Message processing task
            group.addTask {
                var totalTokens = 0
                var lastChunk: ChatCompletionChunk?
                for await message in messages {
                    switch message {
                    case .inferenceChunk(let chunk) where chunk.requestID == requestID:
                        var restoredChunk = chunk.chunk
                        if let content = restoredChunk.choices.first?.delta.content {
                            totalTokens += max(content.count / 4, 1)
                        }
                        if let restorer {
                            let terminal = restoredChunk.choices.first?.finishReason != nil
                            let restoredText = restorer.consume(
                                restoredChunk.choices.first?.delta.content ?? "",
                                terminal: terminal
                            )
                            if !restoredChunk.choices.isEmpty {
                                restoredChunk.choices[0].delta.content = restoredText.isEmpty ? nil : restoredText
                            }
                        }
                        if Self.shouldEmit(restoredChunk) {
                            lastChunk = restoredChunk
                            continuation.yield(restoredChunk)
                        }

                        // Detect stream completion from finish_reason in chunk
                        // (handles case where InferenceComplete message is lost on WAN)
                        if restoredChunk.choices.first?.finishReason != nil {
                            continuation.finish()
                            if totalTokens > 0 {
                                let model = prepared.request.model ?? "unknown"
                                let peer = connection.remoteNodeID
                                await self._onRemoteInferenceCompleted?(totalTokens, model, peer)
                            }
                            return
                        }

                    case .inferenceComplete(let complete) where complete.requestID == requestID:
                        if let restorer,
                           let trailing = Self.trailingChunk(from: restorer, template: lastChunk) {
                            continuation.yield(trailing)
                        }
                        continuation.finish()
                        // Record spending via callback
                        if totalTokens > 0 {
                            let model = prepared.request.model ?? "unknown"
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

    private func preparedRemoteRequest(from request: ChatCompletionRequest) async throws -> PreparedPrivacyFilteredRequest {
        let mode = PrivacyFilterMode.storedDefault()
        guard mode != .off else {
            return PreparedPrivacyFilteredRequest(request: request, placeholderMap: [:])
        }
        return try await DesktopPrivacyFilter.shared.prepare(request: request)
    }

    private static func shouldEmit(_ chunk: ChatCompletionChunk) -> Bool {
        if chunk.usage != nil { return true }
        if chunk.choices.first?.finishReason != nil { return true }
        let content = chunk.choices.first?.delta.content ?? ""
        return !content.isEmpty
    }

    private static func trailingChunk(
        from restorer: StreamingPlaceholderRestorer,
        template: ChatCompletionChunk?
    ) -> ChatCompletionChunk? {
        let trailing = restorer.finish()
        guard !trailing.isEmpty, var chunk = template else { return nil }
        if chunk.choices.isEmpty {
            chunk.choices = [.init(index: 0, delta: .init(role: nil, content: trailing), finishReason: nil)]
        } else {
            chunk.choices[0].delta.content = trailing
            chunk.choices[0].finishReason = nil
        }
        chunk.usage = nil
        return chunk
    }
}
