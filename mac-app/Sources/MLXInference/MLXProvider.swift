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

    // MARK: Prompt-prefix KV cache

    /// KV cache + the exact token sequence it represents, retained across
    /// requests. Chat clients resend the full conversation each turn, so the
    /// next prompt almost always shares a long prefix with the previous one;
    /// reusing the cache skips re-prefilling those tokens (the dominant
    /// latency cost on long conversations). Correctness does not depend on
    /// how the client built the prompt: we only reuse the longest EXACT
    /// token-prefix match, and trim the cache back to it.
    private var reusableCache: [KVCache]?
    private var reusableTokens: [Int] = []

    /// Don't retain the cache for prompts beyond this size (idle memory).
    private static let maxReusableTokens = 32768

    /// Prompt tokens evaluated per prefill step. mlx-swift-lm defaults to
    /// 512; 2048 cuts kernel-launch/eval round-trips ~4x on long prompts
    /// (first turn, cache misses, long pastes) for a measurable TTFT win.
    /// Pure batching of identical math - no quality impact.
    private static let prefillStepSize = 2048
    /// Minimum prefix length worth reusing.
    private static let minReusablePrefix = 32

    private func dropReusableCache() {
        reusableCache = nil
        reusableTokens = []
    }

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
        } else {
            dropReusableCache()
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

        // Cap MLX's Metal allocation cache at half of physical RAM. Without
        // a limit the cache defaults to the memory limit and grows for the
        // lifetime of the process: hours of serving + a retained 32k-token
        // KV cache pile up cached allocations until the machine swaps and
        // decode throughput falls off a cliff. Per mlx-swift docs, LM
        // workloads recycle same-size buffers, so a bounded cache costs no
        // speed; this only binds in the pathological growth case.
        Memory.cacheLimit = Int(ProcessInfo.processInfo.physicalMemory / 2)

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

        let resolvedDirectory = directory.resolvingSymlinksInPath()

        _status = .loadingModel(descriptor)
        onProgress?(LoadProgress(phase: .loadingWeights, fractionCompleted: 0))

        do {
            let container = try await LLMModelFactory.shared.loadContainer(
                from: resolvedDirectory,
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
        dropReusableCache()

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
        let maxTokens = request.maxTokens ?? 8192
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
        let userInput = UserInput(messages: messages, tools: mlxToolSpecs(from: request.tools))
        do {
            let lmInput = try await container.prepare(input: userInput)
            let promptTokens: [Int] = lmInput.text.tokens.asArray(Int.self)

            // Reuse the retained KV cache for the longest exact token prefix
            // shared with the previous request, and prefill only the suffix.
            var cache: [KVCache]? = nil
            var inputToEval = lmInput
            var reusedPrefix = 0
            if let existing = reusableCache, !reusableTokens.isEmpty {
                let limit = min(promptTokens.count, reusableTokens.count)
                var prefix = 0
                while prefix < limit && promptTokens[prefix] == reusableTokens[prefix] {
                    prefix += 1
                }
                if prefix >= Self.minReusablePrefix && prefix < promptTokens.count {
                    trimPromptCache(existing, numTokens: reusableTokens.count - prefix)
                    cache = existing
                    reusedPrefix = prefix
                    inputToEval = LMInput(tokens: MLXArray(Array(promptTokens[prefix...])))
                    print("[MLXProvider] prompt-cache hit: reusing \(prefix) of \(promptTokens.count) prompt tokens")
                } else {
                    dropReusableCache()
                }
            }

            let parameters = GenerateParameters(
                temperature: temperature,
                prefillStepSize: Self.prefillStepSize
            )
            let cacheBox = UncheckedSendableBox(cache)
            let inputBox = UncheckedSendableBox(inputToEval)
            let (stream, usedCache) = try await container.perform { context in
                let activeCache = cacheBox.value ?? context.model.newCache(parameters: parameters)
                let stream = try MLXLMCommon.generate(
                    input: inputBox.value,
                    cache: activeCache,
                    parameters: parameters,
                    context: context
                )
                return (stream, UncheckedSendableBox(activeCache))
            }

            var completionInfo: GenerateCompletionInfo? = nil
            var toolCallReturned = false
            var hitMaxTokens = false

            generationLoop: for await generation in stream {
                if Task.isCancelled { break }
                switch generation {
                case .chunk(let text):
                    tokenCount += 1
                    continuation.yield(makeChunk(id: chatId, model: modelName, role: nil, content: text, finishReason: nil))
                    if tokenCount >= maxTokens { hitMaxTokens = true; break generationLoop }
                case .info(let info):
                    completionInfo = info
                case .toolCall(let toolCall):
                    continuation.yield(makeToolCallChunk(id: chatId, model: modelName, toolCall: toolCall))
                    continuation.yield(makeChunk(id: chatId, model: modelName, role: nil, content: nil, finishReason: "tool_calls"))
                    continuation.finish()
                    toolCallReturned = true
                    break generationLoop
                }
            }

            // Retain the cache for the next request, trimmed back to exactly
            // the prompt (generation appended its tokens on top). On
            // cancellation or unknown generation length, drop it - an
            // untracked cache is never safe to reuse. A maxTokens-capped
            // generation DOES have a known length (we counted the chunks,
            // and no EOS was evaluated before the break), so it keeps its
            // cache instead of forcing a full re-prefill next turn - the
            // common case for clients that always pass max_tokens.
            let generatedCount: Int? = completionInfo?.generationTokenCount
                ?? (hitMaxTokens ? tokenCount : nil)
            if !Task.isCancelled, let generatedCount {
                trimPromptCache(usedCache.value, numTokens: generatedCount)
                if promptTokens.count <= Self.maxReusableTokens {
                    reusableCache = usedCache.value
                    reusableTokens = promptTokens
                } else {
                    dropReusableCache()
                }
                if reusedPrefix > 0, let info = completionInfo {
                    print("[MLXProvider] prompt-cache: prefilled \(info.promptTokenCount) instead of \(promptTokens.count) tokens (\(String(format: "%.0f", info.promptTime * 1000))ms prefill)")
                }
            } else {
                dropReusableCache()
            }

            if toolCallReturned {
                _status = .ready(descriptor)
                return
            }
        } catch {
            dropReusableCache()
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

    private func makeToolCallChunk(id: String, model: String, toolCall: MLXLMCommon.ToolCall) -> ChatCompletionChunk {
        let args = toolCall.function.arguments.mapValues { $0.anyValue }
        let argsData = try? JSONSerialization.data(withJSONObject: args)
        let argsString = argsData.flatMap { String(data: $0, encoding: .utf8) } ?? "{}"

        return ChatCompletionChunk(
            id: id,
            model: model,
            choices: [
                ChatCompletionChunk.StreamChoice(
                    index: 0,
                    delta: ChatCompletionChunk.Delta(
                        role: nil,
                        content: nil,
                        toolCalls: [
                            SharedTypes.ToolCall(
                                index: 0,
                                id: "call_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))",
                                type: "function",
                                function: .init(name: toolCall.function.name, arguments: argsString)
                            )
                        ]
                    ),
                    finishReason: nil
                )
            ]
        )
    }

    private func mlxToolSpecs(from tools: [OpenAIJSONValue]?) -> [MLXLMCommon.ToolSpec]? {
        guard let specs = tools?.compactMap({ openAIJSONDictionary($0) }), !specs.isEmpty else {
            return nil
        }
        return specs
    }

    private func openAIJSONDictionary(_ value: OpenAIJSONValue) -> [String: any Sendable]? {
        guard case .object(let object) = value else { return nil }
        return object.mapValues { openAIJSONSendable($0) }
    }

    private func openAIJSONSendable(_ value: OpenAIJSONValue) -> any Sendable {
        switch value {
        case .string(let string):
            return string
        case .int(let int):
            return int
        case .double(let double):
            return double
        case .bool(let bool):
            return bool
        case .object(let object):
            return object.mapValues { openAIJSONSendable($0) }
        case .array(let array):
            return array.map { openAIJSONSendable($0) }
        case .null:
            return ""
        }
    }
}

// MARK: - Sendable box

/// Crosses non-Sendable values (LMInput, [KVCache]) through ModelContainer's
/// @Sendable perform closure. Safety: MLXProvider is an actor and generation
/// is serialized, so only one generation touches these at a time.
private final class UncheckedSendableBox<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
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
