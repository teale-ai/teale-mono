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

    // MARK: - PTN Routes

    static func listPTNs(controller: (any LocalAppControlling)?) async throws -> Response {
        guard let controller else {
            return errorResponse(message: RemoteControlError.unsupported.localizedDescription)
        }
        return try jsonResponse(await controller.remoteListPTNs())
    }

    static func createPTN(request: Request, controller: (any LocalAppControlling)?) async throws -> Response {
        guard let controller else {
            return errorResponse(message: RemoteControlError.unsupported.localizedDescription)
        }
        do {
            let body = try await request.body.collect(upTo: 1_048_576)
            struct CreateRequest: Decodable { var name: String }
            let payload = try JSONDecoder().decode(CreateRequest.self, from: body)
            let ptn = try await controller.remoteCreatePTN(name: payload.name)
            return try jsonResponse(ptn)
        } catch {
            return errorResponse(message: error.localizedDescription)
        }
    }

    static func generatePTNInvite(request: Request, controller: (any LocalAppControlling)?) async throws -> Response {
        guard let controller else {
            return errorResponse(message: RemoteControlError.unsupported.localizedDescription)
        }
        do {
            let body = try await request.body.collect(upTo: 1_048_576)
            struct InviteRequest: Decodable { var ptn_id: String }
            let payload = try JSONDecoder().decode(InviteRequest.self, from: body)
            let code = try await controller.remoteGeneratePTNInvite(ptnID: payload.ptn_id)
            struct InviteResponse: Encodable { var invite_code: String }
            return try jsonResponse(InviteResponse(invite_code: code))
        } catch {
            return errorResponse(message: error.localizedDescription)
        }
    }

    static func issuePTNCert(request: Request, controller: (any LocalAppControlling)?) async throws -> Response {
        guard let controller else {
            return errorResponse(message: RemoteControlError.unsupported.localizedDescription)
        }
        do {
            let body = try await request.body.collect(upTo: 1_048_576)
            struct IssueCertRequest: Decodable {
                var ptn_id: String
                var node_id: String
                var role: String?
            }
            let payload = try JSONDecoder().decode(IssueCertRequest.self, from: body)
            let certData = try await controller.remoteIssuePTNCert(
                ptnID: payload.ptn_id,
                nodeID: payload.node_id,
                role: payload.role ?? "provider"
            )
            return Response(
                status: .ok,
                headers: [.contentType: "application/json"],
                body: .init(byteBuffer: .init(data: certData))
            )
        } catch {
            return errorResponse(message: error.localizedDescription)
        }
    }

    static func joinPTNWithCert(request: Request, controller: (any LocalAppControlling)?) async throws -> Response {
        guard let controller else {
            return errorResponse(message: RemoteControlError.unsupported.localizedDescription)
        }
        do {
            let body = try await request.body.collect(upTo: 1_048_576)
            let ptn = try await controller.remoteJoinPTNWithCert(certData: Data(buffer: body))
            return try jsonResponse(ptn)
        } catch {
            return errorResponse(message: error.localizedDescription)
        }
    }

    // MARK: - PTN Leave

    static func leavePTN(request: Request, controller: (any LocalAppControlling)?) async throws -> Response {
        guard let controller else {
            return errorResponse(message: RemoteControlError.unsupported.localizedDescription)
        }
        do {
            let body = try await request.body.collect(upTo: 1_048_576)
            struct LeaveRequest: Decodable { var ptn_id: String }
            let payload = try JSONDecoder().decode(LeaveRequest.self, from: body)
            try await controller.remoteLeavePTN(ptnID: payload.ptn_id)
            struct OKResponse: Encodable { var ok: Bool }
            return try jsonResponse(OKResponse(ok: true))
        } catch {
            return errorResponse(message: error.localizedDescription)
        }
    }

    // MARK: - PTN Admin Management

    static func promoteAdmin(request: Request, controller: (any LocalAppControlling)?) async throws -> Response {
        guard let controller else { return errorResponse(message: RemoteControlError.unsupported.localizedDescription) }
        do {
            let body = try await request.body.collect(upTo: 1_048_576)
            struct PromoteRequest: Decodable { var ptn_id: String; var node_id: String }
            let payload = try JSONDecoder().decode(PromoteRequest.self, from: body)
            let data = try await controller.remotePromoteAdmin(ptnID: payload.ptn_id, targetNodeID: payload.node_id)
            // Returns JSON with cert + ca_key_hex for the target to import
            return Response(status: .ok, headers: [.contentType: "application/json"], body: .init(byteBuffer: .init(data: data)))
        } catch { return errorResponse(message: error.localizedDescription) }
    }

    static func importCAKey(request: Request, controller: (any LocalAppControlling)?) async throws -> Response {
        guard let controller else { return errorResponse(message: RemoteControlError.unsupported.localizedDescription) }
        do {
            let body = try await request.body.collect(upTo: 1_048_576)
            struct ImportRequest: Decodable { var ptn_id: String; var ca_key_hex: String }
            let payload = try JSONDecoder().decode(ImportRequest.self, from: body)
            let ptn = try await controller.remoteImportCAKey(ptnID: payload.ptn_id, caKeyHex: payload.ca_key_hex)
            return try jsonResponse(ptn)
        } catch { return errorResponse(message: error.localizedDescription) }
    }

    static func recoverPTN(request: Request, controller: (any LocalAppControlling)?) async throws -> Response {
        guard let controller else { return errorResponse(message: RemoteControlError.unsupported.localizedDescription) }
        do {
            let body = try await request.body.collect(upTo: 1_048_576)
            struct RecoverRequest: Decodable { var ptn_id: String }
            let payload = try JSONDecoder().decode(RecoverRequest.self, from: body)
            let ptn = try await controller.remoteRecoverPTN(oldPTNID: payload.ptn_id)
            return try jsonResponse(ptn)
        } catch { return errorResponse(message: error.localizedDescription) }
    }

    // MARK: - API Key Routes

    static func listAPIKeys(controller: (any LocalAppControlling)?) async throws -> Response {
        guard let controller else {
            return errorResponse(message: RemoteControlError.unsupported.localizedDescription)
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let keys = await controller.remoteListAPIKeys()
        let data = try encoder.encode(keys)
        return Response(
            status: .ok,
            headers: [.contentType: "application/json"],
            body: .init(byteBuffer: .init(data: data))
        )
    }

    static func generateAPIKey(request: Request, controller: (any LocalAppControlling)?) async throws -> Response {
        guard let controller else {
            return errorResponse(message: RemoteControlError.unsupported.localizedDescription)
        }
        do {
            let body = try await request.body.collect(upTo: 1_048_576)
            struct GenerateRequest: Decodable { var name: String }
            let payload = try JSONDecoder().decode(GenerateRequest.self, from: body)
            let key = await controller.remoteGenerateAPIKey(name: payload.name)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(key)
            return Response(
                status: .ok,
                headers: [.contentType: "application/json"],
                body: .init(byteBuffer: .init(data: data))
            )
        } catch {
            return errorResponse(message: error.localizedDescription)
        }
    }

    static func revokeAPIKey(request: Request, controller: (any LocalAppControlling)?) async throws -> Response {
        guard let controller else {
            return errorResponse(message: RemoteControlError.unsupported.localizedDescription)
        }
        do {
            let body = try await request.body.collect(upTo: 1_048_576)
            struct RevokeRequest: Decodable { var id: UUID }
            let payload = try JSONDecoder().decode(RevokeRequest.self, from: body)
            await controller.remoteRevokeAPIKey(id: payload.id)
            struct OKResponse: Encodable { var ok: Bool }
            return try jsonResponse(OKResponse(ok: true))
        } catch {
            return errorResponse(message: error.localizedDescription)
        }
    }

    // MARK: - Wallet Routes

    static func walletBalance(controller: (any LocalAppControlling)?) async throws -> Response {
        guard let controller else {
            return errorResponse(message: RemoteControlError.unsupported.localizedDescription)
        }
        return try jsonResponse(await controller.remoteWalletBalance())
    }

    static func walletTransactions(request: Request, controller: (any LocalAppControlling)?) async throws -> Response {
        guard let controller else {
            return errorResponse(message: RemoteControlError.unsupported.localizedDescription)
        }
        let limit = request.uri.queryParameters["limit"].flatMap { Int($0) } ?? 20
        let transactions = await controller.remoteWalletTransactions(limit: limit)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(transactions)
        return Response(
            status: .ok,
            headers: [.contentType: "application/json"],
            body: .init(byteBuffer: .init(data: data))
        )
    }

    static func walletSend(request: Request, controller: (any LocalAppControlling)?) async throws -> Response {
        guard let controller else {
            return errorResponse(message: RemoteControlError.unsupported.localizedDescription)
        }
        do {
            let body = try await request.body.collect(upTo: 1_048_576)
            struct SendRequest: Decodable { var amount: Double; var peer_id: String; var memo: String? }
            let payload = try JSONDecoder().decode(SendRequest.self, from: body)
            let success = try await controller.remoteWalletSend(amount: payload.amount, toPeer: payload.peer_id, memo: payload.memo)
            struct SendResponse: Encodable { var success: Bool }
            return try jsonResponse(SendResponse(success: success))
        } catch {
            return errorResponse(message: error.localizedDescription)
        }
    }

    static func solanaStatus(controller: (any LocalAppControlling)?) async throws -> Response {
        guard let controller else {
            return errorResponse(message: RemoteControlError.unsupported.localizedDescription)
        }
        return try jsonResponse(await controller.remoteSolanaStatus())
    }

    // MARK: - Peers Routes

    static func listPeers(controller: (any LocalAppControlling)?) async throws -> Response {
        guard let controller else {
            return errorResponse(message: RemoteControlError.unsupported.localizedDescription)
        }
        return try jsonResponse(await controller.remoteListPeers())
    }

    // MARK: - Agent Routes

    static func agentProfile(controller: (any LocalAppControlling)?) async throws -> Response {
        guard let controller else {
            return errorResponse(message: RemoteControlError.unsupported.localizedDescription)
        }
        if let profile = await controller.remoteAgentProfile() {
            return try jsonResponse(profile)
        }
        return errorResponse(message: "No agent profile configured")
    }

    static func agentDirectory(controller: (any LocalAppControlling)?) async throws -> Response {
        guard let controller else {
            return errorResponse(message: RemoteControlError.unsupported.localizedDescription)
        }
        return try jsonResponse(await controller.remoteAgentDirectory())
    }

    static func agentConversations(controller: (any LocalAppControlling)?) async throws -> Response {
        guard let controller else {
            return errorResponse(message: RemoteControlError.unsupported.localizedDescription)
        }
        let conversations = await controller.remoteAgentConversations()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(conversations)
        return Response(
            status: .ok,
            headers: [.contentType: "application/json"],
            body: .init(byteBuffer: .init(data: data))
        )
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
