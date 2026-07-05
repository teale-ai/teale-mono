import Foundation
import Hummingbird

// MARK: - Private Inference Networks (PIN) local API
// Same contract as the Rust node's /v1/app/pins routes so the shared
// companion web UI runs unmodified on macOS. Management calls proxy to the
// gateway with this device's bearer; local state is served directly.

/// The slice of app control PIN routes need. Implemented by
/// RemoteControlBridge in AppCore.
public protocol PINControlling: Sendable {
    /// Full overview JSON: {networks, staff, deviceId, wgPubkey, settings, pendingUsageBatches}
    func pinOverview() async throws -> Data
    func pinJoin(code: String, displayName: String?) async throws
    func pinLocalSettings() async throws -> Data
    func pinUpdateLocalSettings(_ body: Data) async throws -> Data
    /// Authenticated passthrough to gateway /v1/pins/<subpath>.
    func pinProxy(method: String, subpath: String, body: Data?) async throws -> (Int, Data)
}

private struct PINJoinRequestBody: Decodable {
    var code: String?
    var joinCode: String?
    var displayName: String?
}

enum PINRoute {

    static func register(_ router: Router<some RequestContext>, controller: (any PINControlling)?) {
        router.get("/v1/app/pins") { _, _ -> Response in
            guard let controller else { return Self.unavailable() }
            return Self.json(try await controller.pinOverview())
        }
        router.post("/v1/app/pins/join") { request, _ -> Response in
            guard let controller else { return Self.unavailable() }
            let body = try await request.body.collect(upTo: 1_048_576)
            let payload = try JSONDecoder().decode(PINJoinRequestBody.self, from: body)
            guard let code = payload.code ?? payload.joinCode, !code.isEmpty else {
                return Self.error(400, "`code` is required")
            }
            try await controller.pinJoin(code: code, displayName: payload.displayName)
            return Self.json(Data(#"{"status":"submitted"}"#.utf8), status: .accepted)
        }
        router.post("/v1/app/pins/create") { request, _ -> Response in
            guard let controller else { return Self.unavailable() }
            let body = try await request.body.collect(upTo: 1_048_576)
            let (status, data) = try await controller.pinProxy(
                method: "POST", subpath: "", body: Data(buffer: body))
            return Self.json(data, status: Self.mapStatus(status))
        }
        router.get("/v1/app/pins/settings/local") { _, _ -> Response in
            guard let controller else { return Self.unavailable() }
            return Self.json(try await controller.pinLocalSettings())
        }
        router.post("/v1/app/pins/settings/local") { request, _ -> Response in
            guard let controller else { return Self.unavailable() }
            let body = try await request.body.collect(upTo: 1_048_576)
            return Self.json(try await controller.pinUpdateLocalSettings(Data(buffer: body)))
        }
        // Scoped passthrough for everything else (network detail, members,
        // approve/deny, codes, models, usage, leave).
        for method in [HTTPRequest.Method.get, .post, .put, .patch, .delete] {
            router.on("/v1/app/pins/**", method: method) { request, _ -> Response in
                guard let controller else { return Self.unavailable() }
                let path = request.uri.path
                guard let range = path.range(of: "/v1/app/pins") else {
                    return Self.error(404, "unknown pin route")
                }
                var subpath = String(path[range.upperBound...])
                if let query = request.uri.query, !query.isEmpty {
                    subpath += "?\(query)"
                }
                let collected = try await request.body.collect(upTo: 1_048_576)
                let body = collected.readableBytes > 0 ? Data(buffer: collected) : nil
                let (status, data) = try await controller.pinProxy(
                    method: method.rawValue, subpath: subpath, body: body)
                return Self.json(data, status: Self.mapStatus(status))
            }
        }
    }

    private static func mapStatus(_ code: Int) -> HTTPResponse.Status {
        switch code {
        case 200..<300: return .ok
        case 403: return .forbidden
        case 404: return .notFound
        case 409: return .conflict
        default: return .badGateway
        }
    }

    private static func json(_ data: Data, status: HTTPResponse.Status = .ok) -> Response {
        Response(
            status: status,
            headers: [.contentType: "application/json"],
            body: .init(byteBuffer: ByteBuffer(data: data))
        )
    }

    private static func error(_ code: Int, _ message: String) -> Response {
        json(
            Data(#"{"error":"\#(message)"}"#.utf8),
            status: HTTPResponse.Status(code: code)
        )
    }

    private static func unavailable() -> Response {
        error(409, "no private network runtime")
    }
}
