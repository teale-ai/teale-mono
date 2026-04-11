import Foundation
import LocalAPI

/// HTTP client for talking to a running Teale node (GUI app or `teale serve`).
struct TealeClient {
    let baseURL: URL
    let apiKey: String?

    init(port: Int, apiKey: String? = nil) {
        self.baseURL = URL(string: "http://127.0.0.1:\(port)")!
        self.apiKey = apiKey
    }

    // MARK: - App Snapshot

    func snapshot() async throws -> RemoteAppSnapshot {
        try await get("/v1/app")
    }

    // MARK: - Model Control

    func loadModel(_ model: String, downloadIfNeeded: Bool = false) async throws -> RemoteAppSnapshot {
        let body = RemoteModelControlRequest(model: model, downloadIfNeeded: downloadIfNeeded)
        return try await post("/v1/app/models/load", body: body)
    }

    func downloadModel(_ model: String) async throws -> RemoteAppSnapshot {
        let body = RemoteModelControlRequest(model: model)
        return try await post("/v1/app/models/download", body: body)
    }

    func unloadModel() async throws -> RemoteAppSnapshot {
        try await post("/v1/app/models/unload")
    }

    // MARK: - Chat

    func chatStream(prompt: String, model: String?) async throws -> URLSession.AsyncBytes {
        let url = baseURL.appending(path: "/v1/chat/completions")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let apiKey {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }

        struct ChatBody: Encodable {
            let model: String?
            let messages: [[String: String]]
            let stream: Bool
        }

        let body = ChatBody(
            model: model,
            messages: [["role": "user", "content": prompt]],
            stream: true
        )
        request.httpBody = try JSONEncoder().encode(body)

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let http = response as? HTTPURLResponse
            throw TealeClientError.httpError(http?.statusCode ?? 0)
        }
        return bytes
    }

    // MARK: - Helpers

    private func get<T: Decodable>(_ path: String) async throws -> T {
        var request = URLRequest(url: baseURL.appending(path: path))
        if let apiKey {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        try checkHTTP(response)
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func post<T: Decodable>(_ path: String) async throws -> T {
        var request = URLRequest(url: baseURL.appending(path: path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let apiKey {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        try checkHTTP(response)
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func post<B: Encodable, T: Decodable>(_ path: String, body: B) async throws -> T {
        var request = URLRequest(url: baseURL.appending(path: path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let apiKey {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONEncoder().encode(body)
        let (data, response) = try await URLSession.shared.data(for: request)
        try checkHTTP(response)
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func checkHTTP(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else {
            throw TealeClientError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw TealeClientError.httpError(http.statusCode)
        }
    }
}

enum TealeClientError: LocalizedError {
    case connectionRefused
    case httpError(Int)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .connectionRefused:
            return "Cannot connect to Teale node. Is `teale serve` or the Teale app running?"
        case .httpError(let code):
            return "HTTP error \(code)"
        case .invalidResponse:
            return "Invalid response from Teale node"
        }
    }
}
