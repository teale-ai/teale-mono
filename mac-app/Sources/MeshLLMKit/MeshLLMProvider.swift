import Foundation
import SharedTypes

// MARK: - Mesh-LLM Inference Provider

/// Provider that talks to a Mesh-LLM cluster (https://github.com/Mesh-LLM/mesh-llm).
///
/// Mesh-LLM is a distributed llama.cpp cluster exposing an OpenAI-compatible HTTP
/// API at (by default) http://localhost:9337/v1. The wire format is identical to
/// llama-server — the only difference worth noting is readiness: Mesh-LLM has no
/// `/health` endpoint, so we probe `GET /v1/models` instead.
///
/// By default this provider runs in **attach** mode: it assumes a `mesh-llm serve`
/// process is already running (typically so the user can also access the web console
/// at :3131). Supplying a `binary` flips it into **spawn** mode, where the provider
/// starts `mesh-llm serve <serveArgs>` as a managed subprocess.
///
/// Gotchas inherited from teale-node's testing:
/// - Two mesh-llm processes on one host must use separate `HOME` dirs (node
///   identity lives at `~/.mesh-llm/key`); else the planner collapses them into one.
/// - `--split` alone does not force sharding when the model fits on a single node;
///   combine with `--max-vram <n>`.
/// - Readiness path is `/v1/models`, not `/health`.
///
/// TODO(follow-up): `LlamaCppProvider` and `ExoProvider` also parse SSE and probe
/// for readiness. Extract a shared `OpenAIStreamClient` with a parameterized
/// `readinessPath` and migrate all three.
public actor MeshLLMProvider: InferenceProvider {
    private var endpoint: String?
    private var port: UInt16
    private var modelID: String?
    private var binary: String?
    private var serveArgs: [String]
    private var currentDescriptor: ModelDescriptor?
    private var _status: EngineStatus = .idle
    private var discoveredModelID: String?
    private var lastStatusMessage: String = "Mesh-LLM not checked yet"
    private var serverProcess: Process?

    private let session: URLSession

    public init(
        endpoint: String? = nil,
        port: UInt16 = 9337,
        modelID: String? = nil,
        binary: String? = nil,
        serveArgs: [String] = []
    ) {
        self.endpoint = Self.normalize(endpoint)
        self.port = port
        self.modelID = Self.normalize(modelID)
        self.binary = Self.normalize(binary)
        self.serveArgs = serveArgs

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 600
        self.session = URLSession(configuration: config)
    }

    // MARK: - InferenceProvider

    public var status: EngineStatus { _status }

    public var loadedModel: ModelDescriptor? { currentDescriptor }

    public var resolvedModelID: String? { discoveredModelID ?? modelID }

    public var connectionSummary: String { lastStatusMessage }

    public func updateConfiguration(
        endpoint: String?,
        port: UInt16,
        modelID: String?,
        binary: String?,
        serveArgs: [String]
    ) {
        self.endpoint = Self.normalize(endpoint)
        self.port = port
        self.modelID = Self.normalize(modelID)
        self.binary = Self.normalize(binary)
        self.serveArgs = serveArgs
    }

    public func loadModel(_ descriptor: ModelDescriptor) async throws {
        _status = .loadingModel(descriptor)

        if let binary = binary, serverProcess == nil {
            try spawnServer(binary: binary)
        }

        do {
            try await waitForReadiness(timeoutSeconds: 120)
        } catch {
            _status = .error(error.localizedDescription)
            lastStatusMessage = error.localizedDescription
            throw error
        }

        let resolved: String
        if let modelID = modelID {
            resolved = modelID
        } else {
            do {
                resolved = try await fetchFirstModelID()
            } catch {
                _status = .error(error.localizedDescription)
                lastStatusMessage = error.localizedDescription
                throw error
            }
        }

        discoveredModelID = resolved
        currentDescriptor = descriptor
        _status = .ready(descriptor)
        lastStatusMessage = "Connected to mesh-llm at \(baseURLString) using \(resolved)"
    }

    public func unloadModel() async {
        stopServer()
        currentDescriptor = nil
        discoveredModelID = nil
        _status = .idle
        lastStatusMessage = "Mesh-LLM model selection cleared"
    }

    /// Refresh without a caller-supplied descriptor. Used by AppState when the
    /// user applies new settings — readiness-probes, auto-discovers the model,
    /// synthesizes a ModelDescriptor from the resolved id.
    public func refresh() async throws {
        if let binary = binary, serverProcess == nil {
            try spawnServer(binary: binary)
        }

        try await waitForReadiness(timeoutSeconds: 120)

        let resolved: String
        if let modelID = modelID {
            resolved = modelID
        } else {
            resolved = try await fetchFirstModelID()
        }

        discoveredModelID = resolved
        let descriptor = MeshLLMProvider.synthesizeDescriptor(fromModelID: resolved)
        currentDescriptor = descriptor
        _status = .ready(descriptor)
        lastStatusMessage = "Connected to mesh-llm at \(baseURLString) using \(resolved)"
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

    // MARK: - Generation

    private func _generate(
        request: ChatCompletionRequest,
        continuation: AsyncThrowingStream<ChatCompletionChunk, Error>.Continuation
    ) async throws {
        if currentDescriptor == nil {
            try await refresh()
        }

        guard let descriptor = currentDescriptor,
              let resolvedID = discoveredModelID ?? modelID else {
            throw MeshLLMProviderError.noModelResolved
        }

        _status = .generating(descriptor, tokensGenerated: 0)

        guard let url = URL(string: baseURLString)?.appendingPathComponent("v1/chat/completions") else {
            throw MeshLLMProviderError.invalidResponse
        }

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.timeoutInterval = 600

        var proxiedRequest = request
        proxiedRequest.model = resolvedID
        proxiedRequest.stream = true
        urlRequest.httpBody = try JSONEncoder().encode(proxiedRequest)

        do {
            let (bytes, response) = try await session.bytes(for: urlRequest)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw MeshLLMProviderError.invalidResponse
            }

            guard httpResponse.statusCode == 200 else {
                throw try await decodeServerError(from: bytes, statusCode: httpResponse.statusCode)
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

    // MARK: - Readiness

    private func waitForReadiness(timeoutSeconds: Int) async throws {
        guard let url = URL(string: baseURLString)?.appendingPathComponent("v1/models") else {
            throw MeshLLMProviderError.invalidResponse
        }

        let deadline = Date().addingTimeInterval(Double(timeoutSeconds))

        let probeConfig = URLSessionConfiguration.default
        probeConfig.timeoutIntervalForRequest = 5
        let probeSession = URLSession(configuration: probeConfig)

        while Date() < deadline {
            if let process = serverProcess, !process.isRunning {
                let code = process.terminationStatus
                serverProcess = nil
                throw MeshLLMProviderError.subprocessDiedDuringStartup(code)
            }

            do {
                let (_, response) = try await probeSession.data(from: url)
                if let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) {
                    return
                }
            } catch {
                // Not ready yet — connection refused is expected.
            }

            try await Task.sleep(nanoseconds: 1_000_000_000) // 1s
        }

        stopServer()
        throw MeshLLMProviderError.readinessTimeout(url, timeoutSeconds)
    }

    // MARK: - Model Discovery

    private func fetchFirstModelID() async throws -> String {
        guard let url = URL(string: baseURLString)?.appendingPathComponent("v1/models") else {
            throw MeshLLMProviderError.invalidResponse
        }

        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse else {
            throw MeshLLMProviderError.invalidResponse
        }
        guard http.statusCode == 200 else {
            if let apiError = try? JSONDecoder().decode(APIErrorResponse.self, from: data) {
                throw MeshLLMProviderError.serverError(apiError.error.message)
            }
            throw MeshLLMProviderError.serverError("HTTP \(http.statusCode)")
        }

        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let array = object["data"] as? [[String: Any]],
              let first = array.first,
              let id = first["id"] as? String,
              !id.isEmpty else {
            throw MeshLLMProviderError.noModelsDiscovered(url)
        }

        return id
    }

    // MARK: - Subprocess lifecycle

    private func spawnServer(binary: String) throws {
        let resolved = resolvedBinaryPath(binary)
        guard FileManager.default.isExecutableFile(atPath: resolved) else {
            throw MeshLLMProviderError.spawnFailed("mesh-llm binary not found or not executable at: \(resolved)")
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: resolved)
        process.arguments = ["serve"] + serveArgs

        let stderrPipe = Pipe()
        let stdoutPipe = Pipe()
        process.standardError = stderrPipe
        process.standardOutput = stdoutPipe

        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            for line in text.split(separator: "\n") where !line.isEmpty {
                FileHandle.standardError.write(Data("[mesh-llm] \(line)\n".utf8))
            }
        }
        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            for line in text.split(separator: "\n") where !line.isEmpty {
                FileHandle.standardOutput.write(Data("[mesh-llm] \(line)\n".utf8))
            }
        }

        do {
            try process.run()
        } catch {
            throw MeshLLMProviderError.spawnFailed("Failed to start mesh-llm at '\(resolved)': \(error.localizedDescription)")
        }

        serverProcess = process
    }

    private func stopServer() {
        guard let process = serverProcess else { return }
        if process.isRunning {
            process.terminate()
            process.waitUntilExit()
        }
        serverProcess = nil
    }

    public var isServerRunning: Bool {
        serverProcess?.isRunning ?? false
    }

    // MARK: - Helpers

    private var baseURLString: String {
        if let endpoint = endpoint, !endpoint.isEmpty {
            return endpoint
        }
        return "http://127.0.0.1:\(port)"
    }

    private func decodeServerError(
        from bytes: URLSession.AsyncBytes,
        statusCode: Int
    ) async throws -> MeshLLMProviderError {
        var text = ""
        for try await line in bytes.lines {
            text += line
        }

        if let data = text.data(using: .utf8),
           let apiError = try? JSONDecoder().decode(APIErrorResponse.self, from: data) {
            return .serverError(apiError.error.message)
        }

        return .serverError("HTTP \(statusCode)")
    }

    private func resolvedBinaryPath(_ binary: String) -> String {
        if binary.hasPrefix("/") {
            return binary
        }

        let searchPaths = [
            "\(FileManager.default.homeDirectoryForCurrentUser.path)/.local/bin/\(binary)",
            "/opt/homebrew/bin/\(binary)",
            "/usr/local/bin/\(binary)",
        ]

        for path in searchPaths where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }

        return binary
    }

    private static func normalize(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let unslashed = trimmed.hasSuffix("/") ? String(trimmed.dropLast()) : trimmed
        return unslashed.isEmpty ? nil : unslashed
    }

    // Lightweight descriptor synthesis for external model IDs discovered from
    // /v1/models. Keeps MeshLLMKit dependency-free (no ModelCatalog).
    private static func synthesizeDescriptor(fromModelID modelID: String) -> ModelDescriptor {
        let token = modelID.split(separator: "/").last.map(String.init) ?? modelID
        let humanName = token
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .split(separator: " ")
            .map { $0.capitalized }
            .joined(separator: " ")

        let quantization: QuantizationType
        let lower = modelID.lowercased()
        if lower.contains("fp16") {
            quantization = .fp16
        } else if lower.contains("q8") {
            quantization = .q8
        } else {
            quantization = .q4
        }

        let slug = slugify(modelID)

        return ModelDescriptor(
            id: slug.isEmpty ? "mesh-llm-model" : slug,
            name: humanName.isEmpty ? modelID : humanName,
            huggingFaceRepo: modelID,
            parameterCount: "?",
            quantization: quantization,
            estimatedSizeGB: 0,
            requiredRAMGB: 0,
            family: "MeshLLM",
            description: "Served by a Mesh-LLM cluster"
        )
    }

    private static func slugify(_ value: String) -> String {
        let mapped = value.lowercased().map { character -> Character in
            if character.isLetter || character.isNumber {
                return character
            }
            return "-"
        }
        return String(mapped)
            .replacingOccurrences(of: "--+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }
}

// MARK: - Errors

public enum MeshLLMProviderError: LocalizedError {
    case readinessTimeout(URL, Int)
    case noModelsDiscovered(URL)
    case noModelResolved
    case serverError(String)
    case invalidResponse
    case spawnFailed(String)
    case subprocessDiedDuringStartup(Int32)

    public var errorDescription: String? {
        switch self {
        case .readinessTimeout(let url, let seconds):
            return "mesh-llm readiness probe at \(url.absoluteString) timed out after \(seconds)s"
        case .noModelsDiscovered(let url):
            return "mesh-llm at \(url.absoluteString) returned no models"
        case .noModelResolved:
            return "mesh-llm has no resolved model. Set a Model ID or confirm /v1/models returns at least one model."
        case .serverError(let message):
            return "mesh-llm error: \(message)"
        case .invalidResponse:
            return "mesh-llm returned an invalid response."
        case .spawnFailed(let message):
            return message
        case .subprocessDiedDuringStartup(let code):
            return "mesh-llm subprocess exited during startup (status \(code))"
        }
    }
}
