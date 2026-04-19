import Foundation
import SharedTypes

// MARK: - Targeted Dispatch

/// Closure that dispatches a request to a specific device/model on the network.
/// Provided by the app layer (AppState) which has access to cluster and WAN managers.
public typealias TargetedDispatchFn = @Sendable (ChatCompletionRequest, ModelOnNetwork) async throws -> ChatCompletionResponse

// MARK: - Compiler

/// The main entry point for Mixture of Models (MoM) compilation.
/// Conforms to InferenceProvider — drop-in replacement for any existing provider.
///
/// Pipeline: Analyze → Decompose → Select Models → Execute in Parallel → Synthesize
public actor Compiler: InferenceProvider {

    // MARK: - Components

    private let analyzer: RequestAnalyzer
    private let decomposer: TaskDecomposer
    private let selector: ModelSelector
    private let executor: FanOutExecutor
    private let synthesizer: ResponseSynthesizer
    private let fallbackProvider: any InferenceProvider
    private let dispatchFn: TargetedDispatchFn?

    // MARK: - Network State

    private var availableModels: [ModelOnNetwork] = []

    /// Callback fired after a compiled response completes, with contribution records.
    private let onCompilationCompleted: (@Sendable ([ContributionRecord]) async -> Void)?

    // MARK: - InferenceProvider Conformance (delegated)

    public var status: EngineStatus {
        get async { await fallbackProvider.status }
    }

    public var loadedModel: ModelDescriptor? {
        get async { await fallbackProvider.loadedModel }
    }

    // MARK: - Init

    /// Create a Compiler.
    ///
    /// - Parameters:
    ///   - compilerProvider: Small/fast model for decomposition (the "compiler" model).
    ///     Can be the same as fallbackProvider on single-model setups.
    ///   - fallbackProvider: Provider for passthrough requests and synthesis.
    ///   - synthesisProvider: Optional provider for LLM-based synthesis of sub-task results.
    ///   - dispatchFn: Optional closure for targeted dispatch to specific devices.
    ///     When nil, all sub-tasks go through fallbackProvider.
    ///   - onCompilationCompleted: Called with contribution records after a compiled response.
    public init(
        compilerProvider: any InferenceProvider,
        fallbackProvider: any InferenceProvider,
        synthesisProvider: (any InferenceProvider)? = nil,
        dispatchFn: TargetedDispatchFn? = nil,
        onCompilationCompleted: (@Sendable ([ContributionRecord]) async -> Void)? = nil
    ) {
        self.analyzer = RequestAnalyzer()
        self.decomposer = TaskDecomposer(provider: compilerProvider)
        self.selector = ModelSelector()
        self.executor = FanOutExecutor()
        self.synthesizer = ResponseSynthesizer(synthesisProvider: synthesisProvider ?? fallbackProvider)
        self.fallbackProvider = fallbackProvider
        self.dispatchFn = dispatchFn
        self.onCompilationCompleted = onCompilationCompleted
    }

    // MARK: - Network State

    /// Update the list of models currently available on the network.
    /// Call this when peers connect/disconnect or models load/unload.
    public func updateAvailableModels(_ models: [ModelOnNetwork]) {
        self.availableModels = models
    }

    // MARK: - Model Loading (delegated to fallback)

    public func loadModel(_ descriptor: ModelDescriptor) async throws {
        try await fallbackProvider.loadModel(descriptor)
    }

    public func loadModel(_ descriptor: ModelDescriptor, onProgress: LoadProgressCallback?) async throws {
        try await fallbackProvider.loadModel(descriptor, onProgress: onProgress)
    }

    public func unloadModel() async {
        await fallbackProvider.unloadModel()
    }

    // MARK: - Generation

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

    public func generateFull(request: ChatCompletionRequest) async throws -> ChatCompletionResponse {
        let routedRequest = try validateAndRoute(request)

        let shouldCompile = analyzer.shouldCompile(
            request: routedRequest,
            availableModelCount: availableModels.count
        )

        if !shouldCompile {
            return try await fallbackProvider.generateFull(request: routedRequest)
        }

        // Compile the request
        let result = try await compile(request: routedRequest)
        return ChatCompletionResponse(
            id: "chatcmpl-\(UUID().uuidString)",
            model: "mom-compiler",
            choices: [
                .init(index: 0, message: APIMessage(role: "assistant", content: result), finishReason: "stop")
            ]
        )
    }

    // MARK: - Smart Routing

    /// When the user doesn't specify a model, pick the best one for passthrough.
    /// When a model is explicitly set, validate it's available.
    private func validateAndRoute(_ request: ChatCompletionRequest) throws -> ChatCompletionRequest {
        if let requestedModel = request.model {
            // User explicitly chose a model — verify it's actually available
            if !availableModels.isEmpty {
                let found = availableModels.contains { $0.model == requestedModel }
                if !found {
                    let available = Set(availableModels.map(\.model)).sorted()
                    throw CompilationError.modelNotAvailable(
                        requested: requestedModel,
                        available: available
                    )
                }
            }
            // Model found (or no model list yet) — pass through
            return request
        }

        // No model specified — pick the best one automatically
        guard !availableModels.isEmpty else { return request }

        let generalTask = SubTask(
            prompt: "",
            category: .general,
            orderIndex: 0,
            estimatedTokens: 500
        )
        if let best = selector.select(for: generalTask, from: availableModels) {
            var routed = request
            routed.model = best.model
            return routed
        }

        return request
    }

    // MARK: - Core Compilation Pipeline

    private func compile(request: ChatCompletionRequest) async throws -> String {
        // Stage 1 & 2: Decompose
        guard let decomposition = try await decomposer.decompose(request: request) else {
            return try await fallbackFull(request: request)
        }

        let subTasks = decomposition.subTasks
        guard !subTasks.isEmpty else {
            return try await fallbackFull(request: request)
        }

        // Stage 3: Select models for each sub-task
        let assignments = selector.assign(subTasks: subTasks, available: availableModels)

        let unassigned = subTasks.filter { assignments[$0.id] == nil }
        if !unassigned.isEmpty {
            return try await fallbackFull(request: request)
        }

        // Stage 4: Execute in parallel with targeted dispatch
        let dispatch = self.dispatchFn
        let fallback = self.fallbackProvider

        let generateFn: @Sendable (SubTask, ModelOnNetwork, [SubTaskResult]) async throws -> SubTaskResult = {
            subTask, model, depResults in

            let start = CFAbsoluteTimeGetCurrent()

            // Build the sub-task request with dependency context
            var messages = [APIMessage(role: "user", content: subTask.prompt)]
            if !depResults.isEmpty {
                let context = depResults.map(\.content).joined(separator: "\n\n")
                messages.insert(
                    APIMessage(role: "system", content: "Context from prior steps:\n\(context)"),
                    at: 0
                )
            }

            let subRequest = ChatCompletionRequest(
                model: model.model,
                messages: messages,
                maxTokens: subTask.estimatedTokens
            )

            // Use targeted dispatch if available, otherwise fallback
            let response: ChatCompletionResponse
            if let dispatch {
                do {
                    response = try await dispatch(subRequest, model)
                } catch {
                    // Peer may have disconnected — fall back to chain
                    response = try await fallback.generateFull(request: subRequest)
                }
            } else {
                response = try await fallback.generateFull(request: subRequest)
            }

            let content = response.choices.first?.message.content ?? ""
            let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1000

            return SubTaskResult(
                subTaskID: subTask.id,
                content: content,
                model: model.model,
                deviceID: model.deviceID,
                tokenCount: response.usage?.completionTokens ?? content.split(separator: " ").count,
                latencyMs: elapsed
            )
        }

        let results = try await executor.execute(
            subTasks: subTasks,
            assignments: assignments,
            generateFn: generateFn
        )

        // Stage 5: Synthesize
        let finalResponse = try await synthesizer.synthesize(
            results: results,
            originalRequest: request,
            synthesisPrompt: decomposition.synthesisPrompt
        )

        // Record contributions
        let totalTokens = results.reduce(0) { $0 + $1.tokenCount }
        let contributions = results.map { result in
            ContributionRecord(
                deviceID: result.deviceID,
                model: result.model,
                subTaskID: result.subTaskID,
                tokenCount: result.tokenCount,
                weight: totalTokens > 0 ? Double(result.tokenCount) / Double(totalTokens) : 0
            )
        }
        if let callback = onCompilationCompleted {
            await callback(contributions)
        }

        return finalResponse
    }

    // MARK: - Streaming Compilation

    private func _generate(
        request: ChatCompletionRequest,
        continuation: AsyncThrowingStream<ChatCompletionChunk, Error>.Continuation
    ) async throws {
        let routedRequest = try validateAndRoute(request)

        let shouldCompile = analyzer.shouldCompile(
            request: routedRequest,
            availableModelCount: availableModels.count
        )

        if !shouldCompile {
            let stream = fallbackProvider.generate(request: routedRequest)
            for try await chunk in stream {
                continuation.yield(chunk)
            }
            continuation.finish()
            return
        }

        // Compile and stream the result
        let result = try await compile(request: routedRequest)

        let chunkID = "chatcmpl-\(UUID().uuidString)"
        let words = result.components(separatedBy: " ")

        continuation.yield(ChatCompletionChunk(
            id: chunkID,
            model: "mom-compiler",
            choices: [.init(index: 0, delta: .init(role: "assistant"), finishReason: nil)]
        ))

        for (i, word) in words.enumerated() {
            let content = i == 0 ? word : " \(word)"
            continuation.yield(ChatCompletionChunk(
                id: chunkID,
                model: "mom-compiler",
                choices: [.init(index: 0, delta: .init(content: content), finishReason: nil)]
            ))
        }

        continuation.yield(ChatCompletionChunk(
            id: chunkID,
            model: "mom-compiler",
            choices: [.init(index: 0, delta: .init(), finishReason: "stop")]
        ))

        continuation.finish()
    }

    // MARK: - Helpers

    private func fallbackFull(request: ChatCompletionRequest) async throws -> String {
        let response = try await fallbackProvider.generateFull(request: request)
        return response.choices.first?.message.content ?? ""
    }
}
