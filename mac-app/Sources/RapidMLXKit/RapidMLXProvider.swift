import Foundation
import SharedTypes

// MARK: - Rapid-MLX Inference Provider

/// Talks to a Rapid-MLX OpenAI-compatible server. Optionally manages the
/// `rapid-mlx serve` subprocess; otherwise treats the server as externally
/// managed (e.g. `brew services start raullenchai/rapid-mlx/rapid-mlx` or a
/// hand-rolled `nohup rapid-mlx serve …` started by an operator).
public actor RapidMLXProvider: InferenceProvider {
    private var serverProcess: Process?
    private var currentDescriptor: ModelDescriptor?
    private var _status: EngineStatus = .idle
    private var serverPort: Int
    private var host: String
    private var binaryPath: String
    private var modelAlias: String?
    private var manageSubprocess: Bool
    private let session: URLSession

    public init(
        binaryPath: String = "rapid-mlx",
        port: Int = 8000,
        host: String = "127.0.0.1",
        modelAlias: String? = nil,
        manageSubprocess: Bool = false
    ) {
        self.binaryPath = binaryPath
        self.serverPort = port
        self.host = host
        self.modelAlias = modelAlias
        self.manageSubprocess = manageSubprocess

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 600
        self.session = URLSession(configuration: config)
    }

    // MARK: - InferenceProvider

    public var status: EngineStatus { _status }

    public var loadedModel: ModelDescriptor? { currentDescriptor }

    public func loadModel(_ descriptor: ModelDescriptor) async throws {
        let descriptorAlias = aliasFor(descriptor: descriptor)

        if manageSubprocess {
            stopServer()
            _status = .loadingModel(descriptor)
            try await startServer(modelAlias: descriptorAlias)
            if modelAlias == nil || modelAlias?.isEmpty == true {
                modelAlias = descriptorAlias
            }
        } else {
            _status = .loadingModel(descriptor)
            // Connect-only mode — server is externally managed. Confirm it's
            // up; trust the operator's `modelAlias` config to know what's
            // actually being served, and keep the caller's `descriptor`
            // unchanged so WAN advertising preserves any `openrouterId` /
            // catalog metadata the caller selected.
            try await waitForHealth(timeoutSeconds: 30)
            if (modelAlias?.isEmpty ?? true) {
                // No operator pin — fall back to the descriptor's HF repo
                // (which rapid-mlx accepts directly) or the server's own
                // primary served model.
                let serving = try await fetchServingModelIDs()
                modelAlias = serving.first.flatMap { $0.isEmpty ? nil : $0 } ?? descriptorAlias
            }
        }
        currentDescriptor = descriptor
        _status = .ready(descriptor)
    }

    public func unloadModel() async {
        if manageSubprocess {
            stopServer()
        }
        currentDescriptor = nil
        modelAlias = nil
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

    public func updateConfiguration(
        binaryPath: String? = nil,
        port: Int? = nil,
        host: String? = nil,
        modelAlias: String? = nil,
        manageSubprocess: Bool? = nil
    ) {
        if let v = binaryPath { self.binaryPath = v }
        if let v = port { self.serverPort = v }
        if let v = host { self.host = v }
        if let v = modelAlias { self.modelAlias = v }
        if let v = manageSubprocess { self.manageSubprocess = v }
    }

    /// Connect to the running server and discover what model it's serving,
    /// without managing the subprocess. Useful when the server was started
    /// out-of-band (brew services, manual nohup, etc).
    public func refreshFromServer() async throws {
        try await waitForHealth(timeoutSeconds: 5)
        let serving = try await fetchServingModelIDs()
        guard let primary = serving.first(where: { !$0.isEmpty }) else {
            currentDescriptor = nil
            _status = .idle
            return
        }
        let descriptor = makeDescriptor(forServerModelID: primary)
        currentDescriptor = descriptor
        modelAlias = primary
        _status = .ready(descriptor)
    }

    public var isServerRunning: Bool {
        serverProcess?.isRunning ?? false
    }

    // MARK: - Server Lifecycle

    private func startServer(modelAlias: String) async throws {
        let resolvedBinary = resolvedBinaryPath()
        guard FileManager.default.isExecutableFile(atPath: resolvedBinary) else {
            _status = .error("rapid-mlx binary not found at: \(resolvedBinary)")
            throw RapidMLXError.binaryNotFound(resolvedBinary)
        }

        let args = [
            "serve",
            modelAlias,
            "--port", "\(serverPort)",
            "--host", host,
        ]

        let process = Process()
        process.executableURL = URL(fileURLWithPath: resolvedBinary)
        process.arguments = args

        var env = ProcessInfo.processInfo.environment
        // Ensure HOME is set so the rapid-mlx CLI can locate its HF cache + venv.
        if env["HOME"] == nil {
            env["HOME"] = NSHomeDirectory()
        }
        process.environment = env

        let logPath = URL(fileURLWithPath: "/tmp/rapid-mlx.log")
        FileManager.default.createFile(atPath: logPath.path, contents: nil)
        let outputHandle = (try? FileHandle(forWritingTo: logPath)) ?? FileHandle.nullDevice
        process.standardOutput = outputHandle
        process.standardError = outputHandle

        try process.run()
        serverProcess = process

        // Big-model first-load can take 10+ minutes when weights are
        // downloading; mirror llama-server's ceiling.
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
        let url = serverBaseURL.appendingPathComponent("v1/models")
        let deadline = Date().addingTimeInterval(Double(timeoutSeconds))

        let healthConfig = URLSessionConfiguration.default
        healthConfig.timeoutIntervalForRequest = 5
        let healthSession = URLSession(configuration: healthConfig)

        while Date() < deadline {
            if manageSubprocess, let process = serverProcess, !process.isRunning {
                serverProcess = nil
                throw RapidMLXError.serverStartTimeout
            }

            do {
                let (_, response) = try await healthSession.data(from: url)
                if let http = response as? HTTPURLResponse, http.statusCode == 200 {
                    return
                }
            } catch {
                // Connection refused while server warms up — keep polling.
            }
            try await Task.sleep(nanoseconds: 500_000_000)
        }

        if manageSubprocess { stopServer() }
        throw RapidMLXError.serverStartTimeout
    }

    private func fetchServingModelIDs() async throws -> [String] {
        let url = serverBaseURL.appendingPathComponent("v1/models")
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw RapidMLXError.invalidResponse
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dataArray = object["data"] as? [[String: Any]] else {
            return []
        }
        return dataArray.compactMap { $0["id"] as? String }
    }

    // MARK: - Generation

    private func _generate(
        request: ChatCompletionRequest,
        continuation: AsyncThrowingStream<ChatCompletionChunk, Error>.Continuation
    ) async throws {
        guard let descriptor = currentDescriptor else {
            throw RapidMLXError.noModelLoaded
        }

        _status = .generating(descriptor, tokensGenerated: 0)

        let url = serverBaseURL.appendingPathComponent("v1/chat/completions")
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.timeoutInterval = 600

        var proxiedRequest = request
        // Rapid-MLX accepts both alias names (e.g. "qwen3.6-35b") and full
        // HF repo IDs ("mlx-community/Qwen3.6-35B-A3B-4bit"). Forward
        // whichever the server is currently serving.
        if let alias = modelAlias {
            proxiedRequest.model = alias
        } else {
            proxiedRequest.model = descriptor.huggingFaceRepo
        }
        proxiedRequest.stream = true
        urlRequest.httpBody = try JSONEncoder().encode(proxiedRequest)

        do {
            let (bytes, response) = try await session.bytes(for: urlRequest)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw RapidMLXError.invalidResponse
            }
            guard httpResponse.statusCode == 200 else {
                throw RapidMLXError.serverError("HTTP \(httpResponse.statusCode)")
            }

            var tokenCount = 0
            for try await line in bytes.lines {
                guard line.hasPrefix("data: ") else { continue }
                let payload = String(line.dropFirst(6))
                if payload == "[DONE]" { break }
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
        URL(string: "http://\(host == "0.0.0.0" ? "127.0.0.1" : host):\(serverPort)")!
    }

    private func resolvedBinaryPath() -> String {
        if binaryPath.hasPrefix("/") {
            return binaryPath
        }

        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let searchPaths = [
            "/opt/homebrew/opt/rapid-mlx/bin/\(binaryPath)",
            "/opt/homebrew/bin/\(binaryPath)",
            "\(home)/.local/bin/\(binaryPath)",
            "/usr/local/bin/\(binaryPath)",
            Bundle.main.bundlePath + "/Contents/MacOS/\(binaryPath)",
        ]
        for path in searchPaths {
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }

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

    private func aliasFor(descriptor: ModelDescriptor) -> String {
        // If caller already configured an alias (UserDefaults override),
        // honor that. Otherwise fall back to the HF repo, which rapid-mlx
        // accepts directly.
        if let alias = modelAlias, !alias.isEmpty {
            return alias
        }
        return descriptor.huggingFaceRepo
    }

    private func idsMatch(_ a: String, _ b: String) -> Bool {
        let na = a.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let nb = b.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if na == nb { return true }
        let aTail = na.split(separator: "/").last.map(String.init) ?? na
        let bTail = nb.split(separator: "/").last.map(String.init) ?? nb
        return aTail == bTail
    }

    private func makeDescriptor(forServerModelID id: String) -> ModelDescriptor {
        // Lightweight ModelDescriptor synthesis for a server-reported model
        // ID. Mirrors what ExoProvider does for unknown external IDs so the
        // gateway-side heartbeat has a coherent record to publish.
        let token = id.split(separator: "/").last.map(String.init) ?? id
        let lower = id.lowercased()
        let quantization: QuantizationType
        if lower.contains("8bit") || lower.contains("-q8") || lower.contains("_q8") {
            quantization = .q8
        } else if lower.contains("fp16") || lower.contains("bf16") {
            quantization = .fp16
        } else {
            quantization = .q4
        }
        let family = token
            .split(whereSeparator: { $0 == "-" || $0 == "_" || $0 == ":" })
            .first
            .map { String($0).capitalized } ?? "RapidMLX"
        let humanName = token
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .split(separator: " ")
            .map { $0.capitalized }
            .joined(separator: " ")
        return ModelDescriptor(
            id: token.lowercased(),
            name: humanName,
            huggingFaceRepo: id,
            parameterCount: Self.inferParamCount(from: id),
            quantization: quantization,
            estimatedSizeGB: 0,
            requiredRAMGB: 0,
            family: family,
            description: "Served by Rapid-MLX",
            openrouterId: Self.openrouterSlug(forServerOrAlias: id)
        )
    }

    /// Map known rapid-mlx model IDs / aliases to canonical OpenRouter slugs
    /// so the WAN heartbeat advertises supply that the gateway can route to.
    /// Returns `nil` for genuinely unknown models — caller's heartbeat code
    /// will skip advertising those (matches the existing behavior for
    /// non-catalog GGUF supply).
    public static func openrouterSlug(forServerOrAlias id: String) -> String? {
        let lower = id.lowercased()
        // Order: most-specific match first.
        let mapping: [(needle: String, slug: String)] = [
            ("kimi-k2.6", "moonshotai/kimi-k2.6"),
            ("kimi-k2.5", "moonshotai/kimi-k2.5"),
            ("deepseek-v4-flash", "deepseek/deepseek-v4-flash"),
            ("deepseek-v3.2", "deepseek/deepseek-v3.2"),
            ("deepseek-r1", "deepseek/deepseek-r1"),
            ("qwen3.6-35b", "qwen/qwen3.6-35b-a3b"),
            ("qwen3.6-27b", "qwen/qwen3.6-27b"),
            ("qwen3.5-122b", "qwen/qwen3.5-122b-a10b"),
            ("qwen3.5-35b", "qwen/qwen3.5-35b-a3b"),
            ("qwen3.5-27b", "qwen/qwen3.5-27b"),
            ("qwen3.5-9b", "qwen/qwen3.5-9b"),
            ("qwen3.5-4b", "qwen/qwen3.5-4b"),
            ("qwen3-coder-30b", "qwen/qwen3-coder-30b"),
            ("qwen3-vl-30b", "qwen/qwen3-vl-30b-a3b"),
            ("qwen3-vl-8b", "qwen/qwen3-vl-8b"),
            ("qwen3-vl-4b", "qwen/qwen3-vl-4b"),
            ("nemotron-nano", "nvidia/nemotron-3-nano-30b-a3b"),
            ("nemotron-30b", "nvidia/nemotron-3-nano-30b-a3b"),
            ("hermes4-70b", "nousresearch/hermes-4-70b"),
            ("hermes3-8b", "nousresearch/hermes-3-llama-3.1-8b"),
            ("gemma-4-31b", "google/gemma-4-31b"),
            ("gemma-4-26b", "google/gemma-4-26b"),
            ("gemma3-27b", "google/gemma-3-27b"),
            ("gemma3-12b", "google/gemma-3-12b"),
            ("gemma3-1b", "google/gemma-3-1b"),
            ("mistral-24b", "mistralai/mistral-small-3.1-24b"),
            ("ministral-3b", "mistralai/ministral-3-3b"),
            ("phi4-14b", "microsoft/phi-4-mini"),
            ("glm4.5-air", "thudm/glm-4.5-air"),
            ("glm4.7-9b", "thudm/glm-4.7-9b"),
            ("gpt-oss-20b", "openai/gpt-oss-20b"),
            ("devstral-v2-24b", "mistralai/devstral-small-2"),
            ("devstral-24b", "mistralai/devstral-small"),
            ("llama3-3b", "meta-llama/llama-3.2-3b"),
            ("minimax-m2.5", "minimax/minimax-m2.5"),
            ("qwopus-27b", "qwopus/qwopus-27b"),
            ("qwopus-9b", "qwopus/qwopus-9b"),
        ]
        for (needle, slug) in mapping where lower.contains(needle) {
            return slug
        }
        return nil
    }

    private static func inferParamCount(from id: String) -> String {
        let range = NSRange(id.startIndex..<id.endIndex, in: id)
        if let regex = try? NSRegularExpression(pattern: "(\\d+(?:\\.\\d+)?)\\s*[bB]"),
           let match = regex.firstMatch(in: id, options: [], range: range),
           let captureRange = Range(match.range(at: 1), in: id) {
            return "\(id[captureRange].uppercased())B"
        }
        return "?B"
    }
}

// MARK: - Errors

public enum RapidMLXError: LocalizedError {
    case binaryNotFound(String)
    case serverStartTimeout
    case noModelLoaded
    case invalidResponse
    case serverError(String)
    case modelMismatch(requested: String, serving: String)

    public var errorDescription: String? {
        switch self {
        case .binaryNotFound(let path):
            return "rapid-mlx binary not found at: \(path). Install with: brew install raullenchai/rapid-mlx/rapid-mlx"
        case .serverStartTimeout:
            return "rapid-mlx server failed to start within the timeout."
        case .noModelLoaded:
            return "No model loaded in rapid-mlx provider."
        case .invalidResponse:
            return "rapid-mlx returned an invalid response."
        case .serverError(let message):
            return "rapid-mlx error: \(message)"
        case .modelMismatch(let requested, let serving):
            return "rapid-mlx is serving '\(serving)', expected '\(requested)'. Restart rapid-mlx with the correct model or run in subprocess-managed mode."
        }
    }
}
