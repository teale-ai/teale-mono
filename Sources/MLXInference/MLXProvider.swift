import Foundation
import SharedTypes
import MLX
import MLXLLM
import MLXLMCommon

// MARK: - MLX Inference Provider

public actor MLXProvider: InferenceProvider {
    private var modelContainer: ModelContainer?
    private var currentDescriptor: ModelDescriptor?
    private var _status: EngineStatus = .idle

    public var status: EngineStatus {
        _status
    }

    public var loadedModel: ModelDescriptor? {
        currentDescriptor
    }

    public init() {}

    // MARK: - Load Model

    public func loadModel(_ descriptor: ModelDescriptor) async throws {
        try await loadModel(descriptor, onProgress: nil)
    }

    public func loadModel(_ descriptor: ModelDescriptor, onProgress: LoadProgressCallback?) async throws {
        if let current = currentDescriptor, current.id != descriptor.id {
            await unloadModel()
        }

        _status = .loadingModel(descriptor)
        onProgress?(LoadProgress(phase: .downloading, fractionCompleted: 0))

        do {
            let config = ModelConfiguration(id: descriptor.huggingFaceRepo)

            let container = try await LLMModelFactory.shared.loadContainer(
                from: HFDownloader(),
                using: HFTokenizerLoader(),
                configuration: config
            ) { progress in
                let fraction = progress.fractionCompleted
                if fraction < 1.0 {
                    onProgress?(LoadProgress(phase: .downloading, fractionCompleted: fraction))
                } else {
                    onProgress?(LoadProgress(phase: .loadingWeights, fractionCompleted: 0.5))
                }
            }

            onProgress?(LoadProgress(phase: .warmup, fractionCompleted: 0.9))

            self.modelContainer = container
            self.currentDescriptor = descriptor
            _status = .ready(descriptor)
            onProgress?(LoadProgress(phase: .warmup, fractionCompleted: 1.0))
        } catch {
            _status = .error("Failed to load \(descriptor.name): \(error.localizedDescription)")
            throw error
        }
    }

    // MARK: - Unload Model

    public func unloadModel() async {
        _status = .idle
        currentDescriptor = nil

        // Release the container first, then yield to let MLX finish
        // any pending GPU work before clearing the cache
        let hadModel = modelContainer != nil
        modelContainer = nil

        if hadModel {
            // Give MLX time to finish any in-flight GPU operations
            try? await Task.sleep(for: .milliseconds(200))
            Memory.clearCache()
        }
    }

    // MARK: - Generate (Streaming)

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
        guard let container = modelContainer, let descriptor = currentDescriptor else {
            throw InferenceError.noModelLoaded
        }

        let chatId = "chatcmpl-\(UUID().uuidString.prefix(12))"
        var tokenCount = 0
        let maxTokens = request.maxTokens ?? 2048
        let temperature = Float(request.temperature ?? 0.7)
        let modelName = descriptor.huggingFaceRepo

        // Send initial role chunk
        continuation.yield(makeChunk(id: chatId, model: modelName, role: "assistant", content: nil, finishReason: nil))

        _status = .generating(descriptor, tokensGenerated: 0)

        // Build messages as [Message] where Message = [String: any Sendable]
        let messages: [MLXLMCommon.Message] = request.messages.map { msg in
            ["role": msg.role as any Sendable, "content": msg.content as any Sendable]
        }

        // Prepare input and generate
        let userInput = UserInput(messages: messages)
        let lmInput = try await container.prepare(input: userInput)
        let parameters = GenerateParameters(temperature: temperature)
        let stream = try await container.generate(input: lmInput, parameters: parameters)

        for await generation in stream {
            switch generation {
            case .chunk(let text):
                tokenCount += 1
                continuation.yield(makeChunk(id: chatId, model: modelName, role: nil, content: text, finishReason: nil))
                if tokenCount >= maxTokens { break }
            case .info:
                break
            case .toolCall:
                break
            }
        }

        // Final chunk
        continuation.yield(makeChunk(id: chatId, model: modelName, role: nil, content: nil, finishReason: "stop"))
        continuation.finish()
        _status = .ready(descriptor)
    }

    // MARK: - Helper

    private func makeChunk(id: String, model: String, role: String?, content: String?, finishReason: String?) -> ChatCompletionChunk {
        ChatCompletionChunk(
            id: id,
            model: model,
            choices: [
                ChatCompletionChunk.StreamChoice(
                    index: 0,
                    delta: ChatCompletionChunk.Delta(role: role, content: content),
                    finishReason: finishReason
                )
            ]
        )
    }
}

// MARK: - Errors

public enum InferenceError: LocalizedError, Sendable {
    case noModelLoaded
    case generationFailed(String)
    case modelNotFound(String)

    public var errorDescription: String? {
        switch self {
        case .noModelLoaded: return "No model is loaded"
        case .generationFailed(let msg): return "Generation failed: \(msg)"
        case .modelNotFound(let id): return "Model not found: \(id)"
        }
    }
}
