import Foundation
import SharedTypes

// MARK: - LlamaCpp Inference Provider

/// Manages a llama-server subprocess and communicates via its OpenAI-compatible HTTP API.
public actor LlamaCppProvider: InferenceProvider {
    private var serverProcess: Process?
    private var currentDescriptor: ModelDescriptor?
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
        stopServer()

        _status = .loadingModel(descriptor)

        // Resolve model path — huggingFaceRepo holds the local file path for GGUF models
        let modelPath = descriptor.huggingFaceRepo
        guard FileManager.default.fileExists(atPath: modelPath) else {
            _status = .error("GGUF file not found: \(modelPath)")
            throw LlamaCppError.modelNotFound(modelPath)
        }

        try await startServer(modelPath: modelPath)

        currentDescriptor = descriptor
        _status = .ready(descriptor)
    }

    public func unloadModel() async {
        stopServer()
        currentDescriptor = nil
        _status = .idle
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

        // Log server output for debugging
        let logPath = URL(fileURLWithPath: "/tmp/llama-server.log")
        FileManager.default.createFile(atPath: logPath.path, contents: nil)
        let outputHandle = (try? FileHandle(forWritingTo: logPath)) ?? FileHandle.nullDevice
        process.standardOutput = outputHandle
        process.standardError = outputHandle

        try process.run()
        serverProcess = process

        // Wait for the server to become healthy
        // Large models (100B+) can take 10+ minutes to load into memory
        try await waitForHealth(timeoutSeconds: 900)
    }

    private func stopServer() {
        guard let process = serverProcess, process.isRunning else {
            serverProcess = nil
            return
        }
        process.terminate()
        process.waitUntilExit()
        serverProcess = nil
    }

    private func waitForHealth(timeoutSeconds: Int) async throws {
        let url = serverBaseURL.appendingPathComponent("health")
        let deadline = Date().addingTimeInterval(Double(timeoutSeconds))

        let healthSession: URLSession
        let healthConfig = URLSessionConfiguration.default
        healthConfig.timeoutIntervalForRequest = 5
        healthSession = URLSession(configuration: healthConfig)

        while Date() < deadline {
            // Check if the process died
            if let process = serverProcess, !process.isRunning {
                serverProcess = nil
                throw LlamaCppError.serverStartTimeout
            }

            do {
                let (_, response) = try await healthSession.data(from: url)
                if let http = response as? HTTPURLResponse, http.statusCode == 200 {
                    return
                }
            } catch {
                // Server not ready yet — connection refused is expected
            }
            try await Task.sleep(nanoseconds: 500_000_000) // 0.5s
        }

        // Timed out — kill the server
        stopServer()
        throw LlamaCppError.serverStartTimeout
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
        urlRequest.timeoutInterval = 600

        var proxiedRequest = request
        if let requestedModel = proxiedRequest.model,
           requestMatchesLoadedModel(requestedModel, descriptor: descriptor) {
            // llama-server is serving exactly one GGUF at a time. Normalize
            // canonical slugs and other aliases back to the loaded file path
            // so explicit remote-model routing works for GGUF suppliers too.
            proxiedRequest.model = descriptor.huggingFaceRepo
        }
        proxiedRequest.stream = true
        urlRequest.httpBody = try JSONEncoder().encode(proxiedRequest)

        do {
            let (bytes, response) = try await session.bytes(for: urlRequest)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw LlamaCppError.invalidResponse
            }

            guard httpResponse.statusCode == 200 else {
                throw LlamaCppError.serverError("HTTP \(httpResponse.statusCode)")
            }

            var tokenCount = 0
            for try await line in bytes.lines {
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

            _status = .ready(descriptor)
            continuation.finish()
        } catch {
            _status = .error(error.localizedDescription)
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
    case noModelLoaded
    case invalidResponse
    case serverError(String)

    public var errorDescription: String? {
        switch self {
        case .binaryNotFound(let path):
            return "llama-server binary not found at: \(path). Install llama.cpp or set the binary path."
        case .modelNotFound(let path):
            return "GGUF model file not found: \(path)"
        case .serverStartTimeout:
            return "llama-server failed to start within the timeout period."
        case .noModelLoaded:
            return "No model is loaded in llama-server."
        case .invalidResponse:
            return "llama-server returned an invalid response."
        case .serverError(let message):
            return "llama-server error: \(message)"
        }
    }
}
