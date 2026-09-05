import Foundation
import GatewayKit
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
            return errorResponse(error)
        }
    }

    static func setSupplyEnabled(
        request: Request,
        controller: (any DesktopCompanionControlling)?
    ) async throws -> Response {
        guard let controller else { return errorResponse(message: RemoteControlError.unsupported.localizedDescription) }
        struct Payload: Decodable { let enabled: Bool }
        do {
            let body = try await request.body.collect(upTo: 1_048_576)
            let payload = try JSONDecoder().decode(Payload.self, from: body)
            return try jsonResponse(try await controller.desktop_set_supply_enabled(payload.enabled))
        } catch {
            return errorResponse(error)
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
            return errorResponse(error)
        }
    }

    static func networkModels(controller: (any DesktopCompanionControlling)?) async throws -> Response {
        guard let controller else { return errorResponse(message: RemoteControlError.unsupported.localizedDescription) }
        do {
            return try jsonResponse(try await controller.desktop_network_models())
        } catch {
            return errorResponse(error)
        }
    }

    static func networkStats(controller: (any DesktopCompanionControlling)?) async throws -> Response {
        guard let controller else { return errorResponse(message: RemoteControlError.unsupported.localizedDescription) }
        do {
            return try jsonResponse(try await controller.desktop_network_stats())
        } catch {
            return errorResponse(error)
        }
    }

    static func accountSummary(controller: (any DesktopCompanionControlling)?) async throws -> Response {
        guard let controller else { return errorResponse(message: RemoteControlError.unsupported.localizedDescription) }
        do {
            return try jsonResponse(try await controller.desktop_account_summary())
        } catch {
            return errorResponse(error)
        }
    }

    static func accountAPIKeys(controller: (any DesktopCompanionControlling)?) async throws -> Response {
        guard let controller else { return errorResponse(message: RemoteControlError.unsupported.localizedDescription) }
        do {
            return try jsonResponse(try await controller.desktop_account_api_keys())
        } catch {
            return errorResponse(error)
        }
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
            return errorResponse(error)
        }
    }

    static func requestEmailCode(
        request: Request,
        controller: (any DesktopCompanionControlling)?
    ) async throws -> Response {
        guard let controller else { return errorResponse(message: RemoteControlError.unsupported.localizedDescription) }
        do {
            let body = try await request.body.collect(upTo: 1_048_576)
            let payload = try JSONDecoder().decode(DesktopCompanionEmailCodeRequest.self, from: body)
            return try jsonResponse(try await controller.desktop_request_email_code(payload))
        } catch {
            return errorResponse(error)
        }
    }

    static func verifyEmailCode(
        request: Request,
        controller: (any DesktopCompanionControlling)?
    ) async throws -> Response {
        guard let controller else { return errorResponse(message: RemoteControlError.unsupported.localizedDescription) }
        do {
            let body = try await request.body.collect(upTo: 1_048_576)
            let payload = try JSONDecoder().decode(DesktopCompanionEmailCodeVerifyRequest.self, from: body)
            return try jsonResponse(try await controller.desktop_verify_email_code(payload))
        } catch {
            return errorResponse(error)
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
            return errorResponse(error)
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
            return errorResponse(error)
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
            return errorResponse(error)
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
            return errorResponse(error)
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
            return errorResponse(error)
        }
    }

    static func requestWithdrawal(
        request: Request,
        controller: (any DesktopCompanionControlling)?
    ) async throws -> Response {
        guard let controller else { return errorResponse(message: RemoteControlError.unsupported.localizedDescription) }
        do {
            let body = try await request.body.collect(upTo: 1_048_576)
            let payload = try JSONDecoder().decode(DesktopCompanionWithdrawalRequest.self, from: body)
            return try jsonResponse(try await controller.desktop_request_withdrawal(payload))
        } catch {
            return errorResponse(error)
        }
    }

    static func accountWithdrawals(controller: (any DesktopCompanionControlling)?) async throws -> Response {
        guard let controller else { return errorResponse(message: RemoteControlError.unsupported.localizedDescription) }
        do {
            return try jsonResponse(try await controller.desktop_account_withdrawals())
        } catch {
            return errorResponse(error)
        }
    }

    static func depositInfo(controller: (any DesktopCompanionControlling)?) async throws -> Response {
        guard let controller else { return errorResponse(message: RemoteControlError.unsupported.localizedDescription) }
        do {
            return try jsonResponse(try await controller.desktop_deposit_info())
        } catch {
            return errorResponse(error)
        }
    }

    static func refreshWallet(
        controller: (any DesktopCompanionControlling)?
    ) async throws -> Response {
        guard let controller else { return errorResponse(message: RemoteControlError.unsupported.localizedDescription) }
        do {
            return try jsonResponse(try await controller.desktop_refresh_wallet())
        } catch {
            return errorResponse(error)
        }
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
            return errorResponse(error)
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

    /// Gateway failures carry the upstream status and body in
    /// GatewayAuthError.http - surface the gateway's own error message and
    /// answer 502 so the UI shows the real cause (e.g. "gateway email sender
    /// is not configured") instead of a generic 400.
    private static func errorResponse(_ error: Error) -> Response {
        if case let GatewayAuthError.http(status, body) = error {
            struct UpstreamError: Decodable {
                struct Detail: Decodable { let message: String? }
                let error: Detail?
            }
            let upstream = (try? JSONDecoder().decode(UpstreamError.self, from: Data(body.utf8)))?.error?.message
            let detail = upstream ?? String(body.prefix(200))
            return errorResponse(message: "Gateway error (HTTP \(status)): \(detail)", status: .badGateway)
        }
        return errorResponse(error)
    }

    private static func errorResponse(message: String, status: HTTPResponse.Status = .badRequest) -> Response {
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
            status: status,
            headers: [.contentType: "application/json"],
            body: .init(byteBuffer: .init(data: data))
        )
    }
}
