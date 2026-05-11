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
        var toolAccumulator = ToolCallAccumulator()
        let stream = generate(request: request)
        var lastChunkId = "chatcmpl-\(UUID().uuidString)"
        var model = request.model ?? "unknown"
        var finishReason = "stop"

        for try await chunk in stream {
            lastChunkId = chunk.id
            model = chunk.model
            if let content = chunk.choices.first?.delta.content {
                fullContent += content
            }
            if let toolCalls = chunk.choices.first?.delta.toolCalls {
                toolAccumulator.append(toolCalls)
            }
            if let reason = chunk.choices.first?.finishReason {
                finishReason = reason
            }
        }

        return ChatCompletionResponse(
            id: lastChunkId,
            model: model,
            choices: [
                .init(
                    index: 0,
                    message: APIMessage(
                        role: "assistant",
                        content: fullContent,
                        toolCalls: toolAccumulator.materializedCalls
                    ),
                    finishReason: finishReason
                )
            ],
            usage: nil
        )
    }
}

private struct ToolCallAccumulator {
    private struct PartialCall {
        var id: String?
        var type: String?
        var name: String?
        var arguments = ""
    }

    private var calls: [Int: PartialCall] = [:]

    mutating func append(_ toolCalls: [ToolCall]) {
        for (offset, call) in toolCalls.enumerated() {
            let index = call.index ?? offset
            var partial = calls[index] ?? PartialCall()
            if let id = call.id { partial.id = id }
            if let type = call.type { partial.type = type }
            if let function = call.function {
                if let name = function.name { partial.name = name }
                if let arguments = function.arguments { partial.arguments += arguments }
            }
            calls[index] = partial
        }
    }

    var materializedCalls: [ToolCall]? {
        let materialized = calls.keys.sorted().map { index in
            let partial = calls[index]!
            return ToolCall(
                id: partial.id ?? "call_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))",
                type: partial.type ?? "function",
                function: .init(name: partial.name, arguments: partial.arguments)
            )
        }
        return materialized.isEmpty ? nil : materialized
    }
}
