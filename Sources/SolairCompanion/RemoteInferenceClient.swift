import Foundation
import SharedTypes

// MARK: - Server Connection

struct ServerConnection: Sendable {
    var host: String
    var port: UInt16
    var isConnected: Bool
    var latency: TimeInterval?

    var baseURL: String {
        "http://\(host):\(port)"
    }
}

// MARK: - Client Errors

enum RemoteInferenceError: LocalizedError {
    case notConnected
    case invalidResponse
    case serverError(String)
    case networkError(Error)
    case timeout

    var errorDescription: String? {
        switch self {
        case .notConnected: return "Not connected to any node"
        case .invalidResponse: return "Invalid response from server"
        case .serverError(let msg): return "Server error: \(msg)"
        case .networkError(let err): return "Network error: \(err.localizedDescription)"
        case .timeout: return "Request timed out"
        }
    }
}

// MARK: - Remote Inference Client

final class RemoteInferenceClient: Sendable {
    private let session: URLSession

    private let _connection = LockedBox<ServerConnection?>(nil)
    var connection: ServerConnection? { _connection.value }

    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 300
        self.session = URLSession(configuration: config)
    }

    func configure(host: String, port: UInt16) {
        _connection.value = ServerConnection(host: host, port: port, isConnected: false, latency: nil)
    }

    func disconnect() {
        _connection.value = nil
    }

    // MARK: - Fetch Models

    func fetchModels() async throws -> [String] {
        guard let conn = connection else { throw RemoteInferenceError.notConnected }

        let url = URL(string: "\(conn.baseURL)/v1/models")!
        let (data, response) = try await session.data(from: url)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw RemoteInferenceError.invalidResponse
        }

        let modelsResponse = try JSONDecoder().decode(ModelsListResponse.self, from: data)
        _connection.value?.isConnected = true
        return modelsResponse.data.map(\.id)
    }

    // MARK: - Non-Streaming Completion

    func completion(request: ChatCompletionRequest) async throws -> ChatCompletionResponse {
        guard let conn = connection else { throw RemoteInferenceError.notConnected }

        let url = URL(string: "\(conn.baseURL)/v1/chat/completions")!
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var nonStreamingRequest = request
        nonStreamingRequest.stream = false
        urlRequest.httpBody = try JSONEncoder().encode(nonStreamingRequest)

        let (data, response) = try await session.data(for: urlRequest)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw RemoteInferenceError.invalidResponse
        }

        if httpResponse.statusCode != 200 {
            if let errorResp = try? JSONDecoder().decode(APIErrorResponse.self, from: data) {
                throw RemoteInferenceError.serverError(errorResp.error.message)
            }
            throw RemoteInferenceError.serverError("HTTP \(httpResponse.statusCode)")
        }

        return try JSONDecoder().decode(ChatCompletionResponse.self, from: data)
    }

    // MARK: - Streaming Completion (SSE)

    func streamCompletion(request: ChatCompletionRequest) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    guard let conn = self.connection else {
                        continuation.finish(throwing: RemoteInferenceError.notConnected)
                        return
                    }

                    let url = URL(string: "\(conn.baseURL)/v1/chat/completions")!
                    var urlRequest = URLRequest(url: url)
                    urlRequest.httpMethod = "POST"
                    urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")

                    var streamingRequest = request
                    streamingRequest.stream = true
                    urlRequest.httpBody = try JSONEncoder().encode(streamingRequest)

                    let (bytes, response) = try await self.session.bytes(for: urlRequest)

                    guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                        continuation.finish(throwing: RemoteInferenceError.invalidResponse)
                        return
                    }

                    for try await line in bytes.lines {
                        // SSE format: "data: {json}" or "data: [DONE]"
                        guard line.hasPrefix("data: ") else { continue }
                        let payload = String(line.dropFirst(6))

                        if payload == "[DONE]" {
                            break
                        }

                        guard let chunkData = payload.data(using: .utf8) else { continue }
                        let chunk = try JSONDecoder().decode(ChatCompletionChunk.self, from: chunkData)

                        if let content = chunk.choices.first?.delta.content {
                            continuation.yield(content)
                        }

                        if chunk.choices.first?.finishReason != nil {
                            break
                        }
                    }

                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }
}

// MARK: - Thread-safe box for Sendable compliance

private final class LockedBox<T>: @unchecked Sendable {
    private var _value: T
    private let lock = NSLock()

    init(_ value: T) {
        _value = value
    }

    var value: T {
        get { lock.withLock { _value } }
        set { lock.withLock { _value = newValue } }
    }
}
