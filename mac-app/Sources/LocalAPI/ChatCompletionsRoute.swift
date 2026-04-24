import Foundation
import Hummingbird
import NIOCore
import SharedTypes
import InferenceEngine

// MARK: - Chat Completions Route

enum ChatCompletionsRoute {
    static func handle(request: Request, engine: InferenceEngineManager, onCompleted: RequestCompletedHandler? = nil) async throws -> Response {
        let body = try await request.body.collect(upTo: 1_048_576)
        var chatRequest = try JSONDecoder().decode(ChatCompletionRequest.self, from: body)

        // "teale-auto" means "let the system pick" — clear the model field
        // so the Compiler's smart routing decides based on quality and speed.
        if chatRequest.model == ModelsRoute.autoModelID {
            chatRequest.model = nil
        }

        let isStreaming = chatRequest.stream ?? false

        // Local-first gateway fallback. If the request names a specific model
        // that this node can't serve locally AND the user has configured a
        // gateway API key, proxy the entire request (streaming or not) to
        // the Teale gateway. This is what makes `http://localhost:11435/v1`
        // a "just works" endpoint for any OpenAI client: the node handles
        // what it can, the fleet handles the rest.
        if let requestedModel = chatRequest.model,
           !requestedModel.isEmpty,
           await !canServeLocally(modelID: requestedModel, engine: engine),
           let fallback = gatewayFallbackConfig() {
            return try await proxyToGateway(
                body: body,
                config: fallback,
                isStreaming: isStreaming
            )
        }

        do {
            if isStreaming {
                return try await handleStreaming(request: chatRequest, engine: engine, onCompleted: onCompleted)
            } else {
                return try await handleNonStreaming(request: chatRequest, engine: engine, onCompleted: onCompleted)
            }
        } catch {
            if isModelError(error) {
                let errorResponse = APIErrorResponse(
                    message: error.localizedDescription,
                    type: "invalid_request_error"
                )
                let data = try JSONEncoder().encode(errorResponse)
                return Response(
                    status: .badRequest,
                    headers: [.contentType: "application/json"],
                    body: .init(byteBuffer: .init(data: data))
                )
            }
            throw error
        }
    }

    private static func handleNonStreaming(
        request: ChatCompletionRequest,
        engine: InferenceEngineManager,
        onCompleted: RequestCompletedHandler?
    ) async throws -> Response {
        let response = try await engine.generateFull(request: request)
        let tokenCount = (response.choices.first?.message.content.count ?? 0) / 4
        await onCompleted?(tokenCount)
        let data = try JSONEncoder().encode(response)
        return Response(
            status: .ok,
            headers: [.contentType: "application/json"],
            body: .init(byteBuffer: .init(data: data))
        )
    }

    private static func handleStreaming(
        request: ChatCompletionRequest,
        engine: InferenceEngineManager,
        onCompleted: RequestCompletedHandler?
    ) async throws -> Response {
        let stream = engine.generate(request: request)
        let encoder = JSONEncoder()
        let completedHandler = onCompleted

        let responseBody = ResponseBody(contentLength: nil) { writer in
            var tokenCount = 0
            do {
                for try await chunk in stream {
                    tokenCount += 1
                    let data = try encoder.encode(chunk)
                    if let str = String(data: data, encoding: .utf8) {
                        try await writer.write(.init(string: "data: \(str)\n\n"))
                    }
                }
                try await writer.write(.init(string: "data: [DONE]\n\n"))
                await completedHandler?(tokenCount)
            } catch {
                let errorMsg = "data: {\"error\": \"\(error.localizedDescription)\"}\n\n"
                try await writer.write(.init(string: errorMsg))
            }
        }

        return Response(
            status: .ok,
            headers: [
                .contentType: "text/event-stream",
                .cacheControl: "no-cache",
                .connection: "keep-alive",
            ],
            body: responseBody
        )
    }

    private static func isModelError(_ error: Error) -> Bool {
        let message: String
        if let localizedError = error as? LocalizedError,
           let description = localizedError.errorDescription {
            message = description
        } else {
            message = error.localizedDescription
        }

        return message.localizedCaseInsensitiveContains("no model")
            || message.localizedCaseInsensitiveContains("no wan peer")
            || message.localizedCaseInsensitiveContains("not available")
    }

    // MARK: - Local-first gateway fallback

    private struct GatewayFallbackConfig {
        let url: URL
        let apiKey: String
    }

    /// Read the gateway-fallback settings from UserDefaults. Returns nil if
    /// the API key is empty (fallback disabled) or the URL is malformed.
    private static func gatewayFallbackConfig() -> GatewayFallbackConfig? {
        let apiKey = UserDefaults.standard.string(forKey: "teale.gateway_api_key") ?? ""
        guard !apiKey.isEmpty else { return nil }
        let urlString = UserDefaults.standard.string(forKey: "teale.gateway_fallback_url") ?? "https://gateway.teale.com"
        guard let url = URL(string: urlString) else { return nil }
        return GatewayFallbackConfig(url: url, apiKey: apiKey)
    }

    /// Does this node have a loaded model that matches the requested id?
    /// Matches against the descriptor's local id, huggingFaceRepo, and
    /// openrouterId fields — same set of aliases the heartbeat advertises.
    private static func canServeLocally(modelID: String, engine: InferenceEngineManager) async -> Bool {
        guard let loaded = await engine.loadedModel else { return false }
        return loaded.matchesIdentifier(modelID)
    }

    /// Forward the original request body to the configured gateway. For
    /// streaming requests we pipe the upstream SSE lines back to the local
    /// client; for non-streaming we return the upstream JSON as-is.
    private static func proxyToGateway(
        body: ByteBuffer,
        config: GatewayFallbackConfig,
        isStreaming: Bool
    ) async throws -> Response {
        var urlRequest = URLRequest(url: config.url.appending(path: "v1/chat/completions"))
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        urlRequest.httpBody = Data(buffer: body)

        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.timeoutIntervalForRequest = 30
        sessionConfig.timeoutIntervalForResource = 600
        sessionConfig.httpAdditionalHeaders = ["Accept": isStreaming ? "text/event-stream" : "application/json"]
        let session = URLSession(configuration: sessionConfig)

        if !isStreaming {
            let (data, response) = try await session.data(for: urlRequest)
            let status = HTTPResponse.Status(code: (response as? HTTPURLResponse)?.statusCode ?? 502)
            return Response(
                status: status,
                headers: [.contentType: "application/json"],
                body: .init(byteBuffer: .init(bytes: Array(data)))
            )
        }

        let (bytes, response) = try await session.bytes(for: urlRequest)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            var errorBody = Data()
            for try await byte in bytes {
                errorBody.append(byte)
                if errorBody.count > 64_000 { break }
            }
            return Response(
                status: HTTPResponse.Status(code: http.statusCode),
                headers: [.contentType: "application/json"],
                body: .init(byteBuffer: .init(bytes: Array(errorBody)))
            )
        }

        let responseBody = ResponseBody(contentLength: nil) { writer in
            do {
                for try await line in bytes.lines {
                    try await writer.write(.init(string: "\(line)\n"))
                }
            } catch {
                let errorMsg = "data: {\"error\": \"gateway stream failed: \(error.localizedDescription)\"}\n\n"
                try await writer.write(.init(string: errorMsg))
            }
        }

        return Response(
            status: .ok,
            headers: [
                .contentType: "text/event-stream",
                .cacheControl: "no-cache",
                .connection: "keep-alive",
            ],
            body: responseBody
        )
    }
}
