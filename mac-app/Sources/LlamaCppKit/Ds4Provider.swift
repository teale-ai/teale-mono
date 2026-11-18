import Foundation
import SharedTypes

/// Manages a ds4-server subprocess and communicates via its OpenAI-compatible API.
public actor Ds4Provider: InferenceProvider {
    private var serverProcess: Process?
    private var currentDescriptor: ModelDescriptor?
    private var _status: EngineStatus = .idle
    private var serverPort: Int
    private var binaryPath: String
    private var contextSize: Int
    private var host: String
    private var kvDiskDir: String?
    private var kvDiskSpaceMB: Int?
    private var threads: Int?
    private var extraArgs: [String]
    private let session: URLSession

    public init(
        binaryPath: String = "ds4-server",
        port: Int = 11438,
        contextSize: Int = 1_000_000,
        host: String = "127.0.0.1",
        kvDiskDir: String? = nil,
        kvDiskSpaceMB: Int? = 8192,
        threads: Int? = nil,
        extraArgs: [String] = []
    ) {
        self.binaryPath = binaryPath
        self.serverPort = port
        self.contextSize = contextSize
        self.host = host
        self.kvDiskDir = kvDiskDir
        self.kvDiskSpaceMB = kvDiskSpaceMB
        self.threads = threads
        self.extraArgs = extraArgs

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 600
        self.session = URLSession(configuration: config)
    }

    public var status: EngineStatus { _status }
    public var loadedModel: ModelDescriptor? { currentDescriptor }

    public func updateConfiguration(
        binaryPath: String? = nil,
        port: Int? = nil,
        contextSize: Int? = nil,
        host: String? = nil,
        kvDiskDir: String? = nil,
        kvDiskSpaceMB: Int? = nil,
        threads: Int? = nil,
        extraArgs: [String]? = nil
    ) {
        if let v = binaryPath { self.binaryPath = v }
        if let v = port { self.serverPort = v }
        if let v = contextSize { self.contextSize = v }
        if let v = host { self.host = v }
        if let v = kvDiskDir { self.kvDiskDir = v }
        if let v = kvDiskSpaceMB { self.kvDiskSpaceMB = v }
        if let v = threads { self.threads = v }
        if let v = extraArgs { self.extraArgs = v }
    }

    public func loadModel(_ descriptor: ModelDescriptor) async throws {
        await stopServer()
        _status = .loadingModel(descriptor)

        // Scanned GGUFs carry their file path in huggingFaceRepo; catalog
        // DS4 entries resolve to the downloaded file under Teale/gguf/<id>.
        guard let modelURL = ModelStorageLayout.localGGUFFile(for: descriptor) else {
            let missing = descriptor.huggingFaceRepo
            _status = .error("DS4 GGUF file not found for \(descriptor.name): \(missing)")
            throw Ds4ProviderError.modelNotFound(missing)
        }

        try await startServer(modelPath: modelURL.path, expectedModelID: backendModelID(for: descriptor))
        currentDescriptor = descriptor
        _status = .ready(descriptor)
    }

    public func unloadModel() async {
        await stopServer()
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
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func startServer(modelPath: String, expectedModelID: String) async throws {
        let resolvedBinary = resolvedBinaryPath()
        guard FileManager.default.isExecutableFile(atPath: resolvedBinary) else {
            _status = .error("ds4-server not found at: \(resolvedBinary)")
            throw Ds4ProviderError.binaryNotFound(resolvedBinary)
        }

        var args = [
            "--model", modelPath,
            "--host", host,
            "--port", "\(serverPort)",
            "--ctx", "\(contextSize)",
        ]

        if let threads {
            args += ["--threads", "\(threads)"]
        }
        if let kvDiskDir, !kvDiskDir.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            args += ["--kv-disk-dir", kvDiskDir]
        }
        if let kvDiskSpaceMB {
            args += ["--kv-disk-space-mb", "\(kvDiskSpaceMB)"]
        }
        args += extraArgs

        let process = Process()
        process.executableURL = URL(fileURLWithPath: resolvedBinary)
        process.arguments = args

        // Private log under ~/Library/Logs/Teale (may contain prompts).
        let outputHandle = ManagedSubprocess.openLogFile(named: "ds4-server.log")
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
        try await waitForModels(timeoutSeconds: 900, expectedModelID: expectedModelID)
    }

    /// SIGTERM, bounded wait, then SIGKILL — without blocking the actor.
    private func stopServer() async {
        guard let process = serverProcess else { return }
        serverProcess = nil
        await ManagedSubprocess.terminate(process, grace: 10)
        ManagedSubprocess.unregister(process)
    }

    private func handleServerExit(_ process: Process, status: Int32) {
        ManagedSubprocess.unregister(process)
        guard serverProcess === process else { return }
        serverProcess = nil
        _status = .error("ds4-server exited unexpectedly (status \(status))")
    }

    private func waitForModels(timeoutSeconds: Int, expectedModelID: String) async throws {
        let url = serverBaseURL.appendingPathComponent("v1/models")
        let deadline = Date().addingTimeInterval(Double(timeoutSeconds))
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 5
        let healthSession = URLSession(configuration: config)
        defer { healthSession.finishTasksAndInvalidate() }

        while Date() < deadline {
            guard let process = serverProcess, process.isRunning else {
                serverProcess = nil
                throw Ds4ProviderError.serverStartTimeout
            }
            do {
                let (data, response) = try await healthSession.data(from: url)
                if let http = response as? HTTPURLResponse, http.statusCode == 200 {
                    // Confirm the answer comes from a ds4-server serving the
                    // expected model, not a stale process on the port.
                    // ds4-server's id format is not pinned, so only reject
                    // when it clearly names the OTHER DeepSeek V4 variant.
                    let served = Self.modelIDs(from: data)
                    let lowered = served.map { $0.lowercased() }
                    let namesExpected = lowered.contains { $0.contains(expectedModelID) }
                    let namesOtherVariant = lowered.contains { $0.contains("v4-flash") || $0.contains("v4-pro") }
                    if namesExpected || !namesOtherVariant {
                        return
                    }
                    await stopServer()
                    throw Ds4ProviderError.modelMismatch(
                        expected: expectedModelID,
                        serving: served.joined(separator: ", ")
                    )
                }
            } catch let error as Ds4ProviderError {
                throw error
            } catch {
                // Server not ready yet.
            }
            try await Task.sleep(nanoseconds: 500_000_000)
        }

        await stopServer()
        throw Ds4ProviderError.serverStartTimeout
    }

    private static func modelIDs(from data: Data) -> [String] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entries = object["data"] as? [[String: Any]] else {
            return []
        }
        return entries.compactMap { $0["id"] as? String }
    }

    private func _generate(
        request: ChatCompletionRequest,
        continuation: AsyncThrowingStream<ChatCompletionChunk, Error>.Continuation
    ) async throws {
        guard let descriptor = currentDescriptor else {
            throw Ds4ProviderError.noModelLoaded
        }

        _status = .generating(descriptor, tokensGenerated: 0)

        let url = serverBaseURL.appendingPathComponent("v1/chat/completions")
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.timeoutInterval = 600

        var proxiedRequest = request
        proxiedRequest.model = backendModelID(for: descriptor)
        proxiedRequest.stream = true
        urlRequest.httpBody = try JSONEncoder().encode(proxiedRequest)

        do {
            let (bytes, response) = try await session.bytes(for: urlRequest)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw Ds4ProviderError.invalidResponse
            }
            guard httpResponse.statusCode == 200 else {
                throw Ds4ProviderError.serverError("HTTP \(httpResponse.statusCode)")
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
            // A client that hangs up is not a backend failure.
            if HTTPProviderCancellation.isCancellation(error) {
                _status = .ready(descriptor)
            } else {
                _status = .error(error.localizedDescription)
            }
            throw error
        }
    }

    private var serverBaseURL: URL {
        URL(string: "http://127.0.0.1:\(serverPort)")!
    }

    private func backendModelID(for descriptor: ModelDescriptor) -> String {
        let identifiers = descriptor.identifiers.map { $0.lowercased() }
        if identifiers.contains(where: { $0.contains("deepseek-v4-pro") || $0.contains("v4-pro") }) {
            return "deepseek-v4-pro"
        }
        return "deepseek-v4-flash"
    }

    private func resolvedBinaryPath() -> String {
        if binaryPath.hasPrefix("/") {
            return binaryPath
        }

        let searchPaths = [
            "\(FileManager.default.homeDirectoryForCurrentUser.path)/.local/bin/\(binaryPath)",
            "\(FileManager.default.homeDirectoryForCurrentUser.path)/.context/ds4-teale/ds4/\(binaryPath)",
            "/opt/homebrew/bin/\(binaryPath)",
            "/usr/local/bin/\(binaryPath)",
            Bundle.main.bundlePath + "/Contents/MacOS/\(binaryPath)",
            Bundle.main.bundlePath + "/Contents/Resources/\(binaryPath)",
        ]

        for path in searchPaths where FileManager.default.isExecutableFile(atPath: path) {
            return path
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
}

public enum Ds4ProviderError: LocalizedError {
    case binaryNotFound(String)
    case modelNotFound(String)
    case serverStartTimeout
    case noModelLoaded
    case invalidResponse
    case serverError(String)
    case modelMismatch(expected: String, serving: String)

    public var errorDescription: String? {
        switch self {
        case .modelMismatch(let expected, let serving):
            return "The server on the ds4 port is serving '\(serving)', not '\(expected)' (a stale ds4-server may still hold the port)."
        case .binaryNotFound(let path):
            return "ds4-server binary not found at: \(path). Install ds4 or set the binary path."
        case .modelNotFound(let path):
            return "DS4 GGUF model file not found: \(path)"
        case .serverStartTimeout:
            return "ds4-server failed to start within the timeout period."
        case .noModelLoaded:
            return "No model is loaded in ds4-server."
        case .invalidResponse:
            return "ds4-server returned an invalid response."
        case .serverError(let message):
            return "ds4-server error: \(message)"
        }
    }
}
