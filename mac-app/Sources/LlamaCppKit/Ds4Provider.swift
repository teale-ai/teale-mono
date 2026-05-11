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
    private let backendModelID = "deepseek-v4-flash"

    public init(
        binaryPath: String = "ds4-server",
        port: Int = 11438,
        contextSize: Int = 100000,
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
        stopServer()
        _status = .loadingModel(descriptor)

        let modelPath = descriptor.huggingFaceRepo
        guard FileManager.default.fileExists(atPath: modelPath) else {
            _status = .error("DS4 GGUF file not found: \(modelPath)")
            throw Ds4ProviderError.modelNotFound(modelPath)
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
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func startServer(modelPath: String) async throws {
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

        let logPath = URL(fileURLWithPath: "/tmp/ds4-server.log")
        FileManager.default.createFile(atPath: logPath.path, contents: nil)
        let outputHandle = (try? FileHandle(forWritingTo: logPath)) ?? FileHandle.nullDevice
        process.standardOutput = outputHandle
        process.standardError = outputHandle

        try process.run()
        serverProcess = process
        try await waitForModels(timeoutSeconds: 900)
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

    private func waitForModels(timeoutSeconds: Int) async throws {
        let url = serverBaseURL.appendingPathComponent("v1/models")
        let deadline = Date().addingTimeInterval(Double(timeoutSeconds))
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 5
        let healthSession = URLSession(configuration: config)

        while Date() < deadline {
            if let process = serverProcess, !process.isRunning {
                serverProcess = nil
                throw Ds4ProviderError.serverStartTimeout
            }
            do {
                let (_, response) = try await healthSession.data(from: url)
                if let http = response as? HTTPURLResponse, http.statusCode == 200 {
                    return
                }
            } catch {
                // Server not ready yet.
            }
            try await Task.sleep(nanoseconds: 500_000_000)
        }

        stopServer()
        throw Ds4ProviderError.serverStartTimeout
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
        proxiedRequest.model = backendModelID
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
            _status = .error(error.localizedDescription)
            throw error
        }
    }

    private var serverBaseURL: URL {
        URL(string: "http://127.0.0.1:\(serverPort)")!
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

    public var errorDescription: String? {
        switch self {
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
