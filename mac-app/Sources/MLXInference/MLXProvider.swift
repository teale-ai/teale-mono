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

    private func describeMLXError(_ error: Error) -> String {
        if let mlxError = error as? MLXError, let description = mlxError.errorDescription {
            return description
        }
        return error.localizedDescription
    }

    // MARK: - Load Model

    public func loadModel(_ descriptor: ModelDescriptor) async throws {
        try await loadModel(descriptor, onProgress: nil)
    }

    public func loadModel(_ descriptor: ModelDescriptor, onProgress: LoadProgressCallback?) async throws {
        if let current = currentDescriptor, current.id != descriptor.id {
            await unloadModel()
        }

        // Check available memory before loading to avoid Jetsam kill
        var vmStats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &vmStats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        let pageSize = Double(vm_kernel_page_size)
        let availableGB: Double
        if result == KERN_SUCCESS {
            let freePages = Double(vmStats.free_count) + Double(vmStats.inactive_count) + Double(vmStats.purgeable_count)
            availableGB = (freePages * pageSize) / (1024 * 1024 * 1024)
        } else {
            availableGB = Double(ProcessInfo.processInfo.physicalMemory) / (1024 * 1024 * 1024) * 0.5
        }
        let requiredGB = descriptor.requiredRAMGB * 0.8 // weights + overhead, some headroom
        if availableGB < requiredGB {
            let msg = "Not enough free memory to load \(descriptor.name). Available: \(String(format: "%.1f", availableGB)) GB, needs ~\(String(format: "%.0f", descriptor.requiredRAMGB)) GB. Close other apps and try again."
            _status = .error(msg)
            throw InferenceError.generationFailed(msg)
        }

        _status = .loadingModel(descriptor)
        onProgress?(LoadProgress(phase: .verifying, fractionCompleted: 0))

        do {
            let container = try await withError {
                let config = ModelConfiguration(id: descriptor.huggingFaceRepo)

                // Track whether we've seen real download progress to distinguish
                // "verifying cached files" from "actually downloading"
                var sawRealDownload = false
                return try await LLMModelFactory.shared.loadContainer(
                    from: HFDownloader(),
                    using: HFTokenizerLoader(),
                    configuration: config
                ) { progress in
                    let fraction = progress.fractionCompleted
                    if fraction >= 1.0 {
                        onProgress?(LoadProgress(phase: .loadingWeights, fractionCompleted: 0.5))
                    } else if fraction > 0 && fraction < 0.99 {
                        // Real download in progress
                        sawRealDownload = true
                        onProgress?(LoadProgress(phase: .downloading, fractionCompleted: fraction))
                    } else if sawRealDownload {
                        onProgress?(LoadProgress(phase: .downloading, fractionCompleted: fraction))
                    } else {
                        onProgress?(LoadProgress(phase: .verifying, fractionCompleted: fraction))
                    }
                }
            }

            onProgress?(LoadProgress(phase: .warmup, fractionCompleted: 0.9))

            self.modelContainer = container
            self.currentDescriptor = descriptor
            _status = .ready(descriptor)
            onProgress?(LoadProgress(phase: .warmup, fractionCompleted: 1.0))
        } catch {
            let message = describeMLXError(error)
            _status = .error("Failed to load \(descriptor.name): \(message)")
            throw error
        }
    }

    // MARK: - Load Model from Local Directory

    /// Load a model directly from a local directory (no download).
    /// The directory must contain safetensors + config.json + tokenizer files.
    public func loadLocalModel(from directory: URL, descriptor: ModelDescriptor, onProgress: LoadProgressCallback? = nil) async throws {
        if let current = currentDescriptor, current.id != descriptor.id {
            await unloadModel()
        }

        _status = .loadingModel(descriptor)
        onProgress?(LoadProgress(phase: .loadingWeights, fractionCompleted: 0))

        do {
            let container = try await LLMModelFactory.shared.loadContainer(
                from: directory,
                using: HFTokenizerLoader()
            )

            onProgress?(LoadProgress(phase: .warmup, fractionCompleted: 0.9))

            self.modelContainer = container
            self.currentDescriptor = descriptor
            _status = .ready(descriptor)
            onProgress?(LoadProgress(phase: .warmup, fractionCompleted: 1.0))
        } catch {
            _status = .error("Failed to load local model at \(directory.path): \(error.localizedDescription)")
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
        do {
            try await withError {
                let lmInput = try await container.prepare(input: userInput)
                let parameters = GenerateParameters(temperature: temperature)
                let stream = try await container.generate(input: lmInput, parameters: parameters)

                for await generation in stream {
                    if Task.isCancelled { break }
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
            }
        } catch {
            throw InferenceError.generationFailed(describeMLXError(error))
        }

        // Final chunk
        if !Task.isCancelled {
            continuation.yield(makeChunk(id: chatId, model: modelName, role: nil, content: nil, finishReason: "stop"))
        }
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
