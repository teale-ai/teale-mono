import Foundation
import SharedTypes

// MARK: - LlamaCpp Inference Provider

/// Manages a llama-server subprocess and communicates via its OpenAI-compatible HTTP API.
public actor LlamaCppProvider: InferenceProvider {
    private var serverProcess: Process?
    private var currentDescriptor: ModelDescriptor?
    /// GGUF file the running llama-server was started with.
    private var currentModelPath: String?
    private var _status: EngineStatus = .idle
    private var serverPort: Int
    private let session: URLSession

    /// Path to the llama-server binary. Defaults to searching PATH.
    private var binaryPath: String

    /// GPU layers to offload (999 = all layers).
    private var gpuLayers: Int

    /// Context size for the server.
    private var contextSize: Int

    /// Number of parallel request slots.
    private var parallelSlots: Int

    /// Batch size for prompt processing.
    private var batchSize: Int

    /// Whether to disable thinking/reasoning mode.
    private var reasoningOff: Bool

    /// KV cache quantization type (e.g. "q8_0", "f16").
    private var kvCacheType: String

    /// Number of threads for computation.
    private var threads: Int?

    /// Enable flash attention.
    private var flashAttn: Bool

    /// Enable memory-mapped model loading.
    private var mmap: Bool

    /// Host to bind to (127.0.0.1 for local, 0.0.0.0 for network).
    private var host: String

    /// Additional raw arguments to pass to llama-server.
    private var extraArgs: [String]

    public init(
        binaryPath: String = "llama-server",
        port: Int = 11436,
        gpuLayers: Int = 999,
        contextSize: Int = 65536,
        parallelSlots: Int = 1,
        batchSize: Int = 4096,
        reasoningOff: Bool = true,
        kvCacheType: String = "q8_0",
        threads: Int? = nil,
        flashAttn: Bool = false,
        mmap: Bool = false,
        host: String = "127.0.0.1",
        extraArgs: [String] = []
    ) {
        self.binaryPath = binaryPath
        self.serverPort = port
        self.gpuLayers = gpuLayers
        self.contextSize = contextSize
        self.parallelSlots = parallelSlots
        self.batchSize = batchSize
        self.reasoningOff = reasoningOff
        self.kvCacheType = kvCacheType
        self.threads = threads
        self.flashAttn = flashAttn
        self.mmap = mmap
        self.host = host
        self.extraArgs = extraArgs

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 600
        self.session = URLSession(configuration: config)
    }

    // MARK: - InferenceProvider

    public var status: EngineStatus { _status }

    public var loadedModel: ModelDescriptor? { currentDescriptor }

    public func loadModel(_ descriptor: ModelDescriptor) async throws {
        // Stop any existing server
        await stopServer()

        _status = .loadingModel(descriptor)

        // Scanned GGUFs carry their file path in huggingFaceRepo; catalog
        // GGUF entries resolve to the downloaded file under Teale/gguf/<id>.
        guard let modelURL = ModelStorageLayout.localGGUFFile(for: descriptor) else {
            let missing = descriptor.huggingFaceRepo
            _status = .error("GGUF file not found for \(descriptor.name): \(missing)")
            throw LlamaCppError.modelNotFound(missing)
        }
        let modelPath = modelURL.path

        try await startServer(modelPath: modelPath)

        currentModelPath = modelPath
        currentDescriptor = descriptor
        _status = .ready(descriptor)
    }

    public func unloadModel() async {
        await stopServer()
        currentDescriptor = nil
        currentModelPath = nil
        _status = .idle
    }

    /// One-shot server-truth probe, mirroring
    /// RapidMLXProvider.refreshFromServer: make status follow what the
    /// llama-server process is actually doing.
    ///
    /// Unlike waitForHealth this NEVER touches the subprocess - a dead
    /// or busy server only throws here, it is never terminated. Any HTTP
    /// response from /health counts as alive because it can return non-200
    /// while every slot is busy generating; the dead-backend case this
    /// exists for is a refused connection or an exited child process.
    /// Liveness alone is not enough, though: a stale llama-server left on
    /// the fixed port (e.g. after Teale was SIGKILLed) also answers, so the
    /// probe then checks /v1/models reports the GGUF we loaded. A healthy,
    /// verified probe re-adopts the descriptor loaded via loadModel() so a
    /// recovered backend re-advertises without user action; an in-flight
    /// generation state is never clobbered.
    public func refreshFromServer() async throws {
        // Managed child died out from under us (kill, OOM, fleet launchd
        // bootout) - the cheapest, most deterministic truth.
        if let process = serverProcess, !process.isRunning {
            serverProcess = nil
            throw LlamaCppError.serverUnreachable
        }
        let url = serverBaseURL.appendingPathComponent("health")
        let probeConfig = URLSessionConfiguration.default
        probeConfig.timeoutIntervalForRequest = 5
        let probeSession = URLSession(configuration: probeConfig)
        defer { probeSession.finishTasksAndInvalidate() }
        let (_, response) = try await probeSession.data(from: url)
        guard response is HTTPURLResponse else {
            throw LlamaCppError.serverUnreachable
        }
        if verifiesServedModelIdentity,
           let expected = currentModelPath,
           let served = try? await servedModelIDs(using: probeSession),
           !served.isEmpty,
           !Self.servedModelsInclude(path: expected, served: served) {
            throw LlamaCppError.modelMismatch(expected: expected, serving: served.joined(separator: ", "))
        }
        switch _status {
        case .idle, .error:
            if let descriptor = currentDescriptor {
                _status = .ready(descriptor)
            }
        default:
            break
        }
    }

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

    // MARK: - Configuration

    /// Update all settings at once. Takes effect on next model load.
    public func updateConfiguration(
        binaryPath: String? = nil,
        port: Int? = nil,
        gpuLayers: Int? = nil,
        contextSize: Int? = nil,
        parallelSlots: Int? = nil,
        batchSize: Int? = nil,
        reasoningOff: Bool? = nil,
        kvCacheType: String? = nil,
        threads: Int? = nil,
        flashAttn: Bool? = nil,
        mmap: Bool? = nil,
        host: String? = nil,
        extraArgs: [String]? = nil
    ) {
        if let v = binaryPath { self.binaryPath = v }
        if let v = port { self.serverPort = v }
        if let v = gpuLayers { self.gpuLayers = v }
        if let v = contextSize { self.contextSize = v }
        if let v = parallelSlots { self.parallelSlots = v }
        if let v = batchSize { self.batchSize = v }
        if let v = reasoningOff { self.reasoningOff = v }
        if let v = kvCacheType { self.kvCacheType = v }
        if let v = threads { self.threads = v }
        if let v = flashAttn { self.flashAttn = v }
        if let v = mmap { self.mmap = v }
        if let v = host { self.host = v }
        if let v = extraArgs { self.extraArgs = v }
    }

    // MARK: - Server Lifecycle

    private func startServer(modelPath: String) async throws {
        let resolvedBinary = resolvedBinaryPath()
        guard FileManager.default.isExecutableFile(atPath: resolvedBinary) else {
            _status = .error("llama-server not found at: \(resolvedBinary)")
            throw LlamaCppError.binaryNotFound(resolvedBinary)
        }

        var args = [
            "--model", modelPath,
            "--host", host,
            "--port", "\(serverPort)",
            "--n-gpu-layers", "\(gpuLayers)",
            "--ctx-size", "\(contextSize)",
            "--parallel", "\(parallelSlots)",
            "--batch-size", "\(batchSize)",
            "--ubatch-size", "2048",
            "--cache-type-k", kvCacheType,
            "--cache-type-v", kvCacheType,
            "--no-webui",
        ]

        if let threads {
            args += ["--threads", "\(threads)"]
        }

        if flashAttn {
            args += ["--flash-attn", "on"]
        }

        // mmap is enabled by default in llama.cpp; only pass --no-mmap when disabled
        if !mmap {
            args += ["--no-mmap"]
        }

        if reasoningOff {
            args += ["--reasoning", "off"]
        }

        // RoPE scaling is handled by the model's GGUF metadata — llama-server reads
        // the correct rope config automatically. Do NOT force --rope-scaling or
        // --yarn-orig-ctx here; wrong values corrupt positional embeddings and cause
        // incoherent output (e.g. Qwen3-235B-A22B already has YaRN baked in).

        args += extraArgs

        let process = Process()
        process.executableURL = URL(fileURLWithPath: resolvedBinary)
        process.arguments = args

        // Set library path so dylibs alongside the binary are found
        let binaryDir = URL(fileURLWithPath: resolvedBinary).deletingLastPathComponent().path
        var env = ProcessInfo.processInfo.environment
        let existingPath = env["DYLD_LIBRARY_PATH"] ?? ""
        env["DYLD_LIBRARY_PATH"] = existingPath.isEmpty ? binaryDir : "\(binaryDir):\(existingPath)"
        process.environment = env

        // Server output goes to a private log under ~/Library/Logs/Teale
        // (not a fixed world-writable /tmp path: it can contain prompts).
        let outputHandle = ManagedSubprocess.openLogFile(named: "llama-server.log")
        process.standardOutput = outputHandle
        process.standardError = outputHandle
        process.standardInput = FileHandle.nullDevice
        process.terminationHandler = { [weak self] exited in
            let status = exited.terminationStatus
            Task { await self?.handleServerExit(exited, status: status) }
        }

        try process.run()
        ManagedSubprocess.register(process)
        serverProcess = process

        // Wait for the server to become healthy
        // Large models (100B+) can take 10+ minutes to load into memory
        try await waitForHealth(timeoutSeconds: 900, expectedModelPath: modelPath)
    }

    /// SIGTERM, bounded wait without blocking the actor's thread, then
    /// SIGKILL. Clears `serverProcess` first so the termination handler
    /// knows the exit was intentional.
    private func stopServer() async {
        guard let process = serverProcess else { return }
        serverProcess = nil
        await ManagedSubprocess.terminate(process, grace: 10)
        ManagedSubprocess.unregister(process)
    }

    /// Called from the Process termination handler. An exit we did not ask
    /// for (crash, OOM kill) flips status to `.error` right away instead of
    /// waiting for the next request or health probe to notice.
    private func handleServerExit(_ process: Process, status: Int32) {
        ManagedSubprocess.unregister(process)
        guard serverProcess === process else { return }
        serverProcess = nil
        _status = .error("llama-server exited unexpectedly (status \(status))")
    }

    private func waitForHealth(timeoutSeconds: Int, expectedModelPath: String) async throws {
        let url = serverBaseURL.appendingPathComponent("health")
        let deadline = Date().addingTimeInterval(Double(timeoutSeconds))

        let healthSession: URLSession
        let healthConfig = URLSessionConfiguration.default
        healthConfig.timeoutIntervalForRequest = 5
        healthSession = URLSession(configuration: healthConfig)
        defer { healthSession.finishTasksAndInvalidate() }

        while Date() < deadline {
            // Check if the process died (e.g. the port was already taken)
            guard let process = serverProcess, process.isRunning else {
                serverProcess = nil
                throw LlamaCppError.serverStartTimeout
            }

            do {
                let (_, response) = try await healthSession.data(from: url)
                if let http = response as? HTTPURLResponse, http.statusCode == 200 {
                    // Make sure it is OUR server answering, not a stale one
                    // still bound to the port.
                    let served = try await servedModelIDs(using: healthSession)
                    if !verifiesServedModelIdentity
                        || served.isEmpty
                        || Self.servedModelsInclude(path: expectedModelPath, served: served) {
                        return
                    }
                    await stopServer()
                    throw LlamaCppError.modelMismatch(
                        expected: expectedModelPath,
                        serving: served.joined(separator: ", ")
                    )
                }
            } catch let error as LlamaCppError {
                throw error
            } catch {
                // Server not ready yet — connection refused is expected
            }
            try await Task.sleep(nanoseconds: 500_000_000) // 0.5s
        }

        // Timed out — kill the server
        await stopServer()
        throw LlamaCppError.serverStartTimeout
    }

    /// Model ids reported by llama-server's `/v1/models` (the `--model`
    /// path, or its alias).
    private func servedModelIDs(using session: URLSession) async throws -> [String] {
        let url = serverBaseURL.appendingPathComponent("v1/models")
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entries = object["data"] as? [[String: Any]] else {
            return []
        }
        return entries.compactMap { $0["id"] as? String }
    }

    /// An operator `--alias` replaces the path in `/v1/models`, so the
    /// identity check only runs when no alias was passed.
    private var verifiesServedModelIdentity: Bool {
        !extraArgs.contains("--alias") && !extraArgs.contains("-a")
    }

    /// llama-server reports the `--model` argument as the id; older and
    /// newer builds differ on whether it is the full path or the filename.
    static func servedModelsInclude(path: String, served: [String]) -> Bool {
        let fileName = URL(fileURLWithPath: path).lastPathComponent
        return served.contains { id in
            id == path || id == fileName || id.hasSuffix("/" + fileName)
        }
    }

    // MARK: - Generation

    private func _generate(
        request: ChatCompletionRequest,
        continuation: AsyncThrowingStream<ChatCompletionChunk, Error>.Continuation
    ) async throws {
        guard let descriptor = currentDescriptor else {
            throw LlamaCppError.noModelLoaded
        }

        _status = .generating(descriptor, tokensGenerated: 0)

        let url = serverBaseURL.appendingPathComponent("v1/chat/completions")
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Loopback hop: compression only burns CPU on both sides (URLSession
        // adds Accept-Encoding: gzip/deflate/br by default and transparently
        // decompresses). Ask for identity so token chunks stream untouched.
        urlRequest.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        urlRequest.timeoutInterval = 600

        var proxiedRequest = request
        if let requestedModel = proxiedRequest.model,
           requestMatchesLoadedModel(requestedModel, descriptor: descriptor) {
            // llama-server is serving exactly one GGUF at a time. Normalize
            // canonical slugs and other aliases back to the loaded file path
            // so explicit remote-model routing works for GGUF suppliers too.
            proxiedRequest.model = currentModelPath ?? descriptor.huggingFaceRepo
        }
        proxiedRequest.stream = true
        urlRequest.httpBody = try JSONEncoder().encode(proxiedRequest)

        // TEALE_SSE_TIMING=1: timestamped stderr markers around the upstream
        // POST, to split server-side latency from daemon-side stalls.
        let sseT0 = Date()
        let sseTiming = ProcessInfo.processInfo.environment["TEALE_SSE_TIMING"] != nil
        func sseStamp(_ label: String) {
            guard sseTiming else { return }
            let ms = Int(Date().timeIntervalSince(sseT0) * 1000)
            FileHandle.standardError.write(Data("[sse-timing] +\(ms)ms llama-provider: \(label)\n".utf8))
        }
        sseStamp("posting to llama-server")

        do {
            let (bytes, response) = try await session.bytes(for: urlRequest)
            sseStamp("upstream headers received")
            guard let httpResponse = response as? HTTPURLResponse else {
                throw LlamaCppError.invalidResponse
            }

            guard httpResponse.statusCode == 200 else {
                throw LlamaCppError.serverError("HTTP \(httpResponse.statusCode)")
            }

            var tokenCount = 0
            var lineCount = 0
            for try await line in bytes.lines {
                if lineCount == 0 { sseStamp("first upstream line") }
                if lineCount % 100 == 0 { sseStamp("line \(lineCount)") }
                lineCount += 1
                guard line.hasPrefix("data: ") else { continue }
                let payload = String(line.dropFirst(6))

                if payload == "[DONE]" {
                    break
                }

                guard let data = payload.data(using: .utf8) else { continue }
                let chunk = try JSONDecoder().decode(ChatCompletionChunk.self, from: data)
                if let content = chunk.choices.first?.delta.content, !content.isEmpty {
                    tokenCount += 1
                    _status = .generating(descriptor, tokensGenerated: tokenCount)
                }
                continuation.yield(chunk)
            }

            sseStamp("upstream lines done (\(lineCount) lines, \(tokenCount) tokens)")
            _status = .ready(descriptor)
            continuation.finish()
        } catch {
            // A client that hangs up is not a backend failure.
            if HTTPProviderCancellation.isCancellation(error) {
                _status = .ready(descriptor)
            } else {
                _status = .error(error.localizedDescription)
            }
            throw error
        }
    }

    // MARK: - Helpers

    private var serverBaseURL: URL {
        URL(string: "http://127.0.0.1:\(serverPort)")!
    }

    private func resolvedBinaryPath() -> String {
        // If an absolute path was given, use it directly
        if binaryPath.hasPrefix("/") {
            return binaryPath
        }

        // Search common locations
        let searchPaths = [
            "\(FileManager.default.homeDirectoryForCurrentUser.path)/.local/bin/\(binaryPath)",
            "/opt/homebrew/bin/\(binaryPath)",
            "/usr/local/bin/\(binaryPath)",
            // App bundle
            Bundle.main.bundlePath + "/Contents/MacOS/\(binaryPath)",
            Bundle.main.bundlePath + "/Contents/Resources/\(binaryPath)",
        ]

        for path in searchPaths {
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }

        // Fall back to PATH resolution via /usr/bin/which
        if let whichResult = try? shellWhich(binaryPath) {
            return whichResult
        }

        return binaryPath
    }

    private func shellWhich(_ name: String) throws -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = [name]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Check if the server process is currently running.
    public var isServerRunning: Bool {
        serverProcess?.isRunning ?? false
    }

    private func requestMatchesLoadedModel(_ requestedModel: String, descriptor: ModelDescriptor) -> Bool {
        let normalizedRequested = normalizeModelID(requestedModel)
        let candidates = [
            descriptor.id,
            descriptor.huggingFaceRepo,
            descriptor.openrouterId ?? "",
        ]
        .filter { !$0.isEmpty }
        .map(normalizeModelID)

        guard !normalizedRequested.isEmpty else { return false }
        if candidates.contains(normalizedRequested) {
            return true
        }

        let requestedTail = normalizedRequested.split(separator: "/").last.map(String.init) ?? normalizedRequested
        return candidates.contains { candidate in
            let candidateTail = candidate.split(separator: "/").last.map(String.init) ?? candidate
            return candidateTail == requestedTail
        }
    }

    private func normalizeModelID(_ modelID: String) -> String {
        modelID
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "_", with: "-")
    }
}

// MARK: - Errors

public enum LlamaCppError: LocalizedError {
    case binaryNotFound(String)
    case modelNotFound(String)
    case serverStartTimeout
    case serverUnreachable
    case noModelLoaded
    case invalidResponse
    case serverError(String)
    case modelMismatch(expected: String, serving: String)

    public var errorDescription: String? {
        switch self {
        case .modelMismatch(let expected, let serving):
            return "The server on the llama.cpp port is serving '\(serving)', not '\(expected)' (a stale llama-server may still hold the port)."
        case .binaryNotFound(let path):
            return "llama-server binary not found at: \(path). Install llama.cpp or set the binary path."
        case .modelNotFound(let path):
            return "GGUF model file not found: \(path)"
        case .serverStartTimeout:
            return "llama-server failed to start within the timeout period."
        case .serverUnreachable:
            return "llama-server is unreachable (connection failed or no HTTP response)."
        case .noModelLoaded:
            return "No model is loaded in llama-server."
        case .invalidResponse:
            return "llama-server returned an invalid response."
        case .serverError(let message):
            return "llama-server error: \(message)"
        }
    }
}
