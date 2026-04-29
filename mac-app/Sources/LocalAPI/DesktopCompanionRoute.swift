import Foundation
import Hummingbird
import PrivacyFilterKit

enum DesktopCompanionRoute {
    static func snapshot(controller: (any DesktopCompanionControlling)?) async throws -> Response {
        guard let controller else { return errorResponse(message: RemoteControlError.unsupported.localizedDescription) }
        return try jsonResponse(try await controller.desktop_snapshot())
    }

    static func setPrivacyFilterMode(
        request: Request,
        controller: (any DesktopCompanionControlling)?
    ) async throws -> Response {
        guard let controller else { return errorResponse(message: RemoteControlError.unsupported.localizedDescription) }
        struct Payload: Decodable { let mode: PrivacyFilterMode }
        do {
            let body = try await request.body.collect(upTo: 1_048_576)
            let payload = try JSONDecoder().decode(Payload.self, from: body)
            return try jsonResponse(try await controller.desktop_set_privacy_filter_mode(payload.mode))
        } catch {
            return errorResponse(message: error.localizedDescription)
        }
    }

    static func authSession(
        request: Request,
        controller: (any DesktopCompanionControlling)?
    ) async throws -> Response {
        guard let controller else { return errorResponse(message: RemoteControlError.unsupported.localizedDescription) }
        struct Payload: Decodable { let accessToken: String }
        do {
            let body = try await request.body.collect(upTo: 1_048_576)
            let payload = try JSONDecoder().decode(Payload.self, from: body)
            return try jsonResponse(try await controller.desktop_auth_session(access_token: payload.accessToken))
        } catch {
            return errorResponse(message: error.localizedDescription)
        }
    }

    static func networkModels(controller: (any DesktopCompanionControlling)?) async throws -> Response {
        guard let controller else { return errorResponse(message: RemoteControlError.unsupported.localizedDescription) }
        return try jsonResponse(try await controller.desktop_network_models())
    }

    static func networkStats(controller: (any DesktopCompanionControlling)?) async throws -> Response {
        guard let controller else { return errorResponse(message: RemoteControlError.unsupported.localizedDescription) }
        return try jsonResponse(try await controller.desktop_network_stats())
    }

    static func accountSummary(controller: (any DesktopCompanionControlling)?) async throws -> Response {
        guard let controller else { return errorResponse(message: RemoteControlError.unsupported.localizedDescription) }
        return try jsonResponse(try await controller.desktop_account_summary())
    }

    static func accountAPIKeys(controller: (any DesktopCompanionControlling)?) async throws -> Response {
        guard let controller else { return errorResponse(message: RemoteControlError.unsupported.localizedDescription) }
        return try jsonResponse(try await controller.desktop_account_api_keys())
    }

    static func linkAccount(
        request: Request,
        controller: (any DesktopCompanionControlling)?
    ) async throws -> Response {
        guard let controller else { return errorResponse(message: RemoteControlError.unsupported.localizedDescription) }
        do {
            let body = try await request.body.collect(upTo: 1_048_576)
            let payload = try JSONDecoder().decode(DesktopCompanionAccountLinkRequest.self, from: body)
            return try jsonResponse(try await controller.desktop_link_account(payload))
        } catch {
            return errorResponse(message: error.localizedDescription)
        }
    }

    static func createAccountAPIKey(
        request: Request,
        controller: (any DesktopCompanionControlling)?
    ) async throws -> Response {
        guard let controller else { return errorResponse(message: RemoteControlError.unsupported.localizedDescription) }
        struct Payload: Decodable { let label: String? }
        do {
            let body = try await request.body.collect(upTo: 1_048_576)
            let payload = try JSONDecoder().decode(Payload.self, from: body)
            return try jsonResponse(try await controller.desktop_create_account_api_key(label: payload.label))
        } catch {
            return errorResponse(message: error.localizedDescription)
        }
    }

    static func revokeAccountAPIKey(
        request: Request,
        controller: (any DesktopCompanionControlling)?
    ) async throws -> Response {
        guard let controller else { return errorResponse(message: RemoteControlError.unsupported.localizedDescription) }
        struct Payload: Decodable { let keyID: String }
        do {
            let body = try await request.body.collect(upTo: 1_048_576)
            let payload = try JSONDecoder().decode(Payload.self, from: body)
            return try jsonResponse(try await controller.desktop_revoke_account_api_key(key_id: payload.keyID))
        } catch {
            return errorResponse(message: error.localizedDescription)
        }
    }

    static func sweepAccountDevice(
        request: Request,
        controller: (any DesktopCompanionControlling)?
    ) async throws -> Response {
        guard let controller else { return errorResponse(message: RemoteControlError.unsupported.localizedDescription) }
        struct Payload: Decodable { let deviceID: String }
        do {
            let body = try await request.body.collect(upTo: 1_048_576)
            let payload = try JSONDecoder().decode(Payload.self, from: body)
            return try jsonResponse(try await controller.desktop_sweep_account_device(device_id: payload.deviceID))
        } catch {
            return errorResponse(message: error.localizedDescription)
        }
    }

    static func removeAccountDevice(
        request: Request,
        controller: (any DesktopCompanionControlling)?
    ) async throws -> Response {
        guard let controller else { return errorResponse(message: RemoteControlError.unsupported.localizedDescription) }
        struct Payload: Decodable { let deviceID: String }
        do {
            let body = try await request.body.collect(upTo: 1_048_576)
            let payload = try JSONDecoder().decode(Payload.self, from: body)
            return try jsonResponse(try await controller.desktop_remove_account_device(device_id: payload.deviceID))
        } catch {
            return errorResponse(message: error.localizedDescription)
        }
    }

    static func sendAccountWallet(
        request: Request,
        controller: (any DesktopCompanionControlling)?
    ) async throws -> Response {
        guard let controller else { return errorResponse(message: RemoteControlError.unsupported.localizedDescription) }
        do {
            let body = try await request.body.collect(upTo: 1_048_576)
            let payload = try JSONDecoder().decode(DesktopCompanionWalletSendRequest.self, from: body)
            return try jsonResponse(try await controller.desktop_send_account_wallet(payload))
        } catch {
            return errorResponse(message: error.localizedDescription)
        }
    }

    static func refreshWallet(
        controller: (any DesktopCompanionControlling)?
    ) async throws -> Response {
        guard let controller else { return errorResponse(message: RemoteControlError.unsupported.localizedDescription) }
        return try jsonResponse(try await controller.desktop_refresh_wallet())
    }

    static func sendDeviceWallet(
        request: Request,
        controller: (any DesktopCompanionControlling)?
    ) async throws -> Response {
        guard let controller else { return errorResponse(message: RemoteControlError.unsupported.localizedDescription) }
        do {
            let body = try await request.body.collect(upTo: 1_048_576)
            let payload = try JSONDecoder().decode(DesktopCompanionWalletSendRequest.self, from: body)
            return try jsonResponse(try await controller.desktop_send_device_wallet(payload))
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
        struct ErrorEnvelope: Encodable {
            struct ErrorPayload: Encodable {
                let message: String
                let type: String
            }

            let error: ErrorPayload
        }
        let error = ErrorEnvelope(error: .init(message: message, type: "invalid_request_error"))
        let data = (try? JSONEncoder().encode(error))
            ?? Data("{\"error\":{\"message\":\"\(message)\",\"type\":\"invalid_request_error\"}}".utf8)
        return Response(
            status: .badRequest,
            headers: [.contentType: "application/json"],
            body: .init(byteBuffer: .init(data: data))
        )
    }
}
