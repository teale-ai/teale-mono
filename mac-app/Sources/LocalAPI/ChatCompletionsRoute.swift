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
}
