import Foundation
import Hummingbird
import NIOCore
import SharedTypes
import InferenceEngine
import PrivacyFilterKit

// MARK: - Chat Completions Route

enum ChatCompletionsRoute {
    static func handle(
        request: Request,
        engine: InferenceEngineManager,
        peerModelProvider: PeerModelProvider? = nil,
        onCompleted: RequestCompletedHandler? = nil
    ) async throws -> Response {
        let body = try await request.body.collect(upTo: 1_048_576)
        var chatRequest = try JSONDecoder().decode(ChatCompletionRequest.self, from: body)

        // "teale-auto" means "let the system pick" — clear the model field
        // so the Compiler's smart routing decides based on quality and speed.
        if chatRequest.model == ModelsRoute.autoModelID {
            chatRequest.model = nil
        }

        let isStreaming = chatRequest.stream ?? false
        let privacyMode = PrivacyFilterMode.storedDefault()

        // Local-first gateway fallback. If the request names a specific model
        // that this node can't serve locally AND the user has configured a
        // gateway API key, proxy the entire request (streaming or not) to
        // the Teale gateway. This is what makes `http://localhost:11435/v1`
        // a "just works" endpoint for any OpenAI client: the node handles
        // what it can, the fleet handles the rest.
        if let requestedModel = chatRequest.model,
           !requestedModel.isEmpty,
           await !canServeLocally(modelID: requestedModel, engine: engine),
           await !canServeViaPeers(modelID: requestedModel, peerModelProvider: peerModelProvider),
           let fallback = gatewayFallbackConfig() {
            let prepared = try await preparedRequest(
                from: chatRequest,
                shouldFilter: privacyMode != .off
            )
            return try await proxyToGateway(
                prepared: prepared,
                config: fallback,
                isStreaming: isStreaming
            )
        }

        do {
            let prepared = try await preparedRequest(
                from: chatRequest,
                shouldFilter: privacyMode == .always
            )
            if isStreaming {
                return try await handleStreaming(
                    prepared: prepared,
                    engine: engine,
                    onCompleted: onCompleted
                )
            } else {
                return try await handleNonStreaming(
                    prepared: prepared,
                    engine: engine,
                    onCompleted: onCompleted
                )
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
            if error is DesktopPrivacyFilterError {
                let errorResponse = APIErrorResponse(
                    message: error.localizedDescription,
                    type: "service_unavailable"
                )
                let data = try JSONEncoder().encode(errorResponse)
                return Response(
                    status: .serviceUnavailable,
                    headers: [.contentType: "application/json"],
                    body: .init(byteBuffer: .init(data: data))
                )
            }
            throw error
        }
    }

    private static func handleNonStreaming(
        prepared: PreparedPrivacyFilteredRequest,
        engine: InferenceEngineManager,
        onCompleted: RequestCompletedHandler?
    ) async throws -> Response {
        let response = try await engine.generateFull(request: prepared.request)
        let restored = prepared.restoreResponse(response)
        let tokenCount = (restored.choices.first?.message.content.count ?? 0) / 4
        await onCompleted?(tokenCount)
        let data = try JSONEncoder().encode(restored)
        return Response(
            status: .ok,
            headers: [.contentType: "application/json"],
            body: .init(byteBuffer: .init(data: data))
        )
    }

    private static func handleStreaming(
        prepared: PreparedPrivacyFilteredRequest,
        engine: InferenceEngineManager,
        onCompleted: RequestCompletedHandler?
    ) async throws -> Response {
        let stream = engine.generate(request: prepared.request)
        let encoder = JSONEncoder()
        let completedHandler = onCompleted
        let restorer = prepared.makeStreamingRestorer()

        let responseBody = ResponseBody(contentLength: nil) { writer in
            var tokenCount = 0
            var lastChunk: ChatCompletionChunk?
            do {
                for try await chunk in stream {
                    tokenCount += 1
                    var chunk = chunk
                    if let restorer {
                        let terminal = chunk.choices.first?.finishReason != nil
                        let restoredText = restorer.consume(
                            chunk.choices.first?.delta.content ?? "",
                            terminal: terminal
                        )
                        if !chunk.choices.isEmpty {
                            chunk.choices[0].delta.content = restoredText.isEmpty ? nil : restoredText
                        }
                    }
                    guard shouldEmit(chunk: chunk) else { continue }
                    lastChunk = chunk
                    let data = try encoder.encode(chunk)
                    if let str = String(data: data, encoding: .utf8) {
                        try await writer.write(.init(string: "data: \(str)\n\n"))
                    }
                }
                if let restorer,
                   let trailing = trailingChunk(from: restorer, template: lastChunk) {
                    let data = try encoder.encode(trailing)
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
        return ModelsRoute.advertisedModelIDs(for: loaded).contains { advertised in
            ModelsRoute.modelIDMatches(advertised, requested: modelID)
        }
    }

    private static func canServeViaPeers(modelID: String, peerModelProvider: PeerModelProvider?) async -> Bool {
        guard let peerModelProvider else { return false }
        let peerModels = await peerModelProvider()
        return peerModels.contains { ModelsRoute.modelIDMatches($0.id, requested: modelID) }
    }

    /// Forward the original request body to the configured gateway. For
    /// streaming requests we pipe the upstream SSE lines back to the local
    /// client; for non-streaming we return the upstream JSON as-is.
    private static func proxyToGateway(
        prepared: PreparedPrivacyFilteredRequest,
        config: GatewayFallbackConfig,
        isStreaming: Bool
    ) async throws -> Response {
        var urlRequest = URLRequest(url: config.url.appending(path: "v1/chat/completions"))
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        if prepared.isFiltered {
            urlRequest.setValue("1", forHTTPHeaderField: "X-Teale-Privacy-Filtered")
        }
        urlRequest.httpBody = try JSONEncoder().encode(prepared.request)

        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.timeoutIntervalForRequest = 30
        sessionConfig.timeoutIntervalForResource = 600
        sessionConfig.httpAdditionalHeaders = ["Accept": isStreaming ? "text/event-stream" : "application/json"]
        let session = URLSession(configuration: sessionConfig)

        if !isStreaming {
            let (data, response) = try await session.data(for: urlRequest)
            let status = HTTPResponse.Status(code: (response as? HTTPURLResponse)?.statusCode ?? 502)
            let responseData: Data
            if prepared.isFiltered,
               let decoded = try? JSONDecoder().decode(ChatCompletionResponse.self, from: data) {
                responseData = try JSONEncoder().encode(prepared.restoreResponse(decoded))
            } else {
                responseData = data
            }
            return Response(
                status: status,
                headers: [.contentType: "application/json"],
                body: .init(byteBuffer: .init(bytes: Array(responseData)))
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

        let restorer = prepared.makeStreamingRestorer()
        let responseBody = ResponseBody(contentLength: nil) { writer in
            do {
                var lastChunk: ChatCompletionChunk?
                for try await line in bytes.lines {
                    guard line.hasPrefix("data: ") else {
                        try await writer.write(.init(string: "\(line)\n"))
                        continue
                    }

                    let payload = String(line.dropFirst(6))
                    if payload == "[DONE]" {
                        if let restorer,
                           let trailing = trailingChunk(from: restorer, template: lastChunk) {
                            let data = try JSONEncoder().encode(trailing)
                            if let str = String(data: data, encoding: .utf8) {
                                try await writer.write(.init(string: "data: \(str)\n\n"))
                            }
                        }
                        try await writer.write(.init(string: "data: [DONE]\n"))
                        continue
                    }

                    guard let restorer,
                          var chunk = try? JSONDecoder().decode(ChatCompletionChunk.self, from: Data(payload.utf8)) else {
                        try await writer.write(.init(string: "\(line)\n"))
                        continue
                    }

                    let terminal = chunk.choices.first?.finishReason != nil
                    let restoredText = restorer.consume(
                        chunk.choices.first?.delta.content ?? "",
                        terminal: terminal
                    )
                    if !chunk.choices.isEmpty {
                        chunk.choices[0].delta.content = restoredText.isEmpty ? nil : restoredText
                    }
                    guard shouldEmit(chunk: chunk) else { continue }
                    lastChunk = chunk
                    let data = try JSONEncoder().encode(chunk)
                    if let str = String(data: data, encoding: .utf8) {
                        try await writer.write(.init(string: "data: \(str)\n"))
                    }
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

    private static func preparedRequest(
        from request: ChatCompletionRequest,
        shouldFilter: Bool
    ) async throws -> PreparedPrivacyFilteredRequest {
        guard shouldFilter else {
            return PreparedPrivacyFilteredRequest(request: request, placeholderMap: [:])
        }
        return try await DesktopPrivacyFilter.shared.prepare(request: request)
    }

    private static func shouldEmit(chunk: ChatCompletionChunk) -> Bool {
        if chunk.usage != nil { return true }
        if chunk.choices.first?.finishReason != nil { return true }
        let content = chunk.choices.first?.delta.content ?? ""
        return !content.isEmpty
    }

    private static func trailingChunk(
        from restorer: StreamingPlaceholderRestorer,
        template: ChatCompletionChunk?
    ) -> ChatCompletionChunk? {
        let trailing = restorer.finish()
        guard !trailing.isEmpty, var chunk = template else { return nil }
        if chunk.choices.isEmpty {
            chunk.choices = [.init(index: 0, delta: .init(role: nil, content: trailing), finishReason: nil)]
        } else {
            chunk.choices[0].delta.content = trailing
            chunk.choices[0].finishReason = nil
        }
        chunk.usage = nil
        return chunk
    }
}
