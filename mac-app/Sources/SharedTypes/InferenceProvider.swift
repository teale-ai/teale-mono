import Foundation

// MARK: - Inference Provider Protocol

/// Progress callback for model loading phases
public typealias LoadProgressCallback = @Sendable (LoadProgress) -> Void

/// Describes the current phase and progress of model loading
public struct LoadProgress: Sendable {
    public var phase: Phase
    public var fractionCompleted: Double  // 0.0 - 1.0

    public enum Phase: String, Sendable {
        case downloading = "Downloading model…"
        case verifying = "Verifying files…"
        case loadingWeights = "Loading weights into memory…"
        case warmup = "Warming up model…"
    }

    public init(phase: Phase, fractionCompleted: Double) {
        self.phase = phase
        self.fractionCompleted = fractionCompleted
    }
}

/// Core protocol abstracting inference backends (MLX, CoreML, etc.)
public protocol InferenceProvider: Sendable {
    /// Current status of the engine
    var status: EngineStatus { get async }

    /// The currently loaded model, if any
    var loadedModel: ModelDescriptor? { get async }

    /// Load a model for inference
    func loadModel(_ descriptor: ModelDescriptor) async throws

    /// Load a model with progress reporting
    func loadModel(_ descriptor: ModelDescriptor, onProgress: LoadProgressCallback?) async throws

    /// Unload the current model, freeing memory
    func unloadModel() async

    /// Generate a streaming completion
    func generate(request: ChatCompletionRequest) -> AsyncThrowingStream<ChatCompletionChunk, Error>

    /// Generate a non-streaming completion (collects all tokens)
    func generateFull(request: ChatCompletionRequest) async throws -> ChatCompletionResponse
}

// MARK: - Default: progress variant falls back to plain loadModel

extension InferenceProvider {
    public func loadModel(_ descriptor: ModelDescriptor, onProgress: LoadProgressCallback?) async throws {
        try await loadModel(descriptor)
    }
}

// MARK: - Default implementation for generateFull

extension InferenceProvider {
    public func generateFull(request: ChatCompletionRequest) async throws -> ChatCompletionResponse {
        var fullContent = ""
        let stream = generate(request: request)
        var lastChunkId = "chatcmpl-\(UUID().uuidString)"
        var model = request.model ?? "unknown"

        for try await chunk in stream {
            lastChunkId = chunk.id
            model = chunk.model
            if let content = chunk.choices.first?.delta.content {
                fullContent += content
            }
        }

        return ChatCompletionResponse(
            id: lastChunkId,
            model: model,
            choices: [
                .init(index: 0, message: APIMessage(role: "assistant", content: fullContent), finishReason: "stop")
            ],
            usage: nil
        )
    }
}
