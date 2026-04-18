import Foundation
import Hummingbird
import SharedTypes

enum RemoteControlRoute {
    static func snapshot(controller: (any LocalAppControlling)?) async throws -> Response {
        guard let controller else {
            return errorResponse(message: RemoteControlError.unsupported.localizedDescription)
        }
        return try jsonResponse(await controller.remoteSnapshot())
    }

    static func updateSettings(
        request: Request,
        controller: (any LocalAppControlling)?
    ) async throws -> Response {
        guard let controller else {
            return errorResponse(message: RemoteControlError.unsupported.localizedDescription)
        }

        do {
            let body = try await request.body.collect(upTo: 1_048_576)
            let update = try JSONDecoder().decode(RemoteSettingsUpdate.self, from: body)
            return try jsonResponse(try await controller.remoteUpdateSettings(update))
        } catch let error as DecodingError {
            return errorResponse(message: "Invalid settings payload: \(error.localizedDescription)")
        } catch {
            return errorResponse(message: error.localizedDescription)
        }
    }

    static func loadModel(
        request: Request,
        controller: (any LocalAppControlling)?
    ) async throws -> Response {
        try await modelAction(request: request, controller: controller) { controller, payload in
            try await controller.remoteLoadModel(payload)
        }
    }

    static func downloadModel(
        request: Request,
        controller: (any LocalAppControlling)?
    ) async throws -> Response {
        try await modelAction(request: request, controller: controller) { controller, payload in
            try await controller.remoteDownloadModel(payload)
        }
    }

    static func unloadModel(controller: (any LocalAppControlling)?) async throws -> Response {
        guard let controller else {
            return errorResponse(message: RemoteControlError.unsupported.localizedDescription)
        }
        return try jsonResponse(await controller.remoteUnloadModel())
    }

    private static func modelAction(
        request: Request,
        controller: (any LocalAppControlling)?,
        action: @escaping (any LocalAppControlling, RemoteModelControlRequest) async throws -> RemoteAppSnapshot
    ) async throws -> Response {
        guard let controller else {
            return errorResponse(message: RemoteControlError.unsupported.localizedDescription)
        }

        do {
            let body = try await request.body.collect(upTo: 1_048_576)
            let payload = try JSONDecoder().decode(RemoteModelControlRequest.self, from: body)
            return try jsonResponse(try await action(controller, payload))
        } catch let error as DecodingError {
            return errorResponse(message: "Invalid model payload: \(error.localizedDescription)")
        } catch {
            return errorResponse(message: error.localizedDescription)
        }
    }

    private static func jsonResponse<T: Encodable>(_ value: T) throws -> Response {
        let data = try JSONEncoder().encode(value)
        return Response(
            status: .ok,
            headers: [.contentType: "application/json"],
            body: .init(byteBuffer: .init(data: data))
        )
    }

    private static func errorResponse(message: String) -> Response {
        let error = APIErrorResponse(message: message)
        let data = (try? JSONEncoder().encode(error)) ?? Data("{\"error\":{\"message\":\"\(message)\",\"type\":\"invalid_request_error\"}}".utf8)
        return Response(
            status: .badRequest,
            headers: [.contentType: "application/json"],
            body: .init(byteBuffer: .init(data: data))
        )
    }
}
