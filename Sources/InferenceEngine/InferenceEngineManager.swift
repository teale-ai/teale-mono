import Foundation
import SharedTypes
import HardwareProfile

// MARK: - Inference Engine Manager

public actor InferenceEngineManager {
    private var provider: any InferenceProvider
    private let throttler: AdaptiveThrottler

    public init(provider: any InferenceProvider, throttler: AdaptiveThrottler) {
        self.provider = provider
        self.throttler = throttler
    }

    /// Swap the underlying provider (e.g. from local to cluster mode)
    public func setProvider(_ newProvider: any InferenceProvider) {
        self.provider = newProvider
    }

    public var status: EngineStatus {
        get async { await provider.status }
    }

    public var loadedModel: ModelDescriptor? {
        get async { await provider.loadedModel }
    }

    public func loadModel(_ descriptor: ModelDescriptor) async throws {
        try await provider.loadModel(descriptor)
    }

    public func loadModel(_ descriptor: ModelDescriptor, onProgress: LoadProgressCallback?) async throws {
        try await provider.loadModel(descriptor, onProgress: onProgress)
    }

    public func unloadModel() async {
        await provider.unloadModel()
    }

    public nonisolated func generate(request: ChatCompletionRequest) -> AsyncThrowingStream<ChatCompletionChunk, Error> {
        // Note: we can't access provider directly here since this is nonisolated.
        // The provider's generate is also nonisolated, so we capture it via Task.
        AsyncThrowingStream { continuation in
            Task {
                let stream = await self.provider.generate(request: request)
                do {
                    for try await chunk in stream {
                        continuation.yield(chunk)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    public func generateFull(request: ChatCompletionRequest) async throws -> ChatCompletionResponse {
        try await provider.generateFull(request: request)
    }

    public nonisolated var throttleLevel: ThrottleLevel {
        throttler.throttleLevel
    }
}
