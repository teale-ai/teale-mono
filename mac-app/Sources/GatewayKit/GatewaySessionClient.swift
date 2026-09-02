import Foundation

public enum GatewaySessionError: Error, CustomStringConvertible, LocalizedError {
    case http(Int, String)
    case decode(String)
    case network(String)

    public var description: String {
        switch self {
        case .http(let code, let body): return "HTTP \(code): \(body.prefix(200))"
        case .decode(let m): return "decode: \(m)"
        case .network(let m): return "network: \(m)"
        }
    }

    public var errorDescription: String? { description }
}

/// Passwordless email auth against the gateway (`tsess_…` account sessions).
/// No passwords, no Supabase: request a code + magic link over email, verify,
/// hold an opaque session token. See docs/passwordless-auth-migration.md.
///
/// NOTE (phase 2, uncompiled): written without a local Swift toolchain; build
/// on a Mac before merging. API mirrors the gateway endpoints 1:1.
public actor GatewaySessionClient {

    public let baseURL: URL
    private let session: URLSession

    public init(
        baseURL: URL = URL(string: "https://gateway.teale.com")!,
        session: URLSession = .shared
    ) {
        self.baseURL = baseURL
        self.session = session
    }

    // MARK: - Types

    private struct RequestReq: Encodable { let email: String }
    public struct RequestRes: Decodable, Sendable {
        public let email: String
        public let expiresAt: Int64
    }

    private struct VerifyReq: Encodable {
        let email: String
        let code: String
        let deviceId: String?
        let deviceName: String?
    }
    public struct VerifyRes: Decodable, Sendable {
        public let sessionToken: String
        public let expiresAt: Int64
        public let accountUserID: String
        public let email: String
    }

    public struct SessionInfo: Decodable, Sendable {
        public let accountUserID: String
        public let email: String?
        public let sessionId: String
    }

    // MARK: - Flow

    /// POST /v1/auth/email/request — sends one email with a 6-digit code and
    /// a magic link.
    @discardableResult
    public func requestEmailLogin(email: String) async throws -> RequestRes {
        try await postJSON(path: "/v1/auth/email/request", body: RequestReq(email: email))
    }

    /// POST /v1/auth/email/verify — consumes the code, returns a session
    /// token. `deviceID`/`deviceName` bind the session to this install.
    public func verifyEmailLogin(
        email: String,
        code: String,
        deviceID: String? = nil,
        deviceName: String? = nil
    ) async throws -> VerifyRes {
        try await postJSON(
            path: "/v1/auth/email/verify",
            body: VerifyReq(email: email, code: code, deviceId: deviceID, deviceName: deviceName)
        )
    }

    /// GET /v1/auth/session — validates a stored token and returns the
    /// account identity. Also covers magic-link adoption: the deep link
    /// carries only a token, this resolves it to an identity.
    public func fetchSession(token: String) async throws -> SessionInfo {
        try await getJSON(path: "/v1/auth/session", bearerToken: token)
    }

    /// POST /v1/auth/logout — revokes the session server-side.
    public func logout(token: String) async throws {
        var req = URLRequest(url: baseURL.appendingPathComponent("/v1/auth/logout"))
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (_, resp): (Data, URLResponse)
        do { (_, resp) = try await session.data(for: req) }
        catch { throw GatewaySessionError.network(error.localizedDescription) }
        guard let http = resp as? HTTPURLResponse else {
            throw GatewaySessionError.network("non-http response")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw GatewaySessionError.http(http.statusCode, "")
        }
    }

    // MARK: - HTTP helpers

    private func postJSON<Req: Encodable, Res: Decodable>(path: String, body: Req) async throws -> Res {
        var req = URLRequest(url: baseURL.appendingPathComponent(path))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(body)
        return try await roundTrip(req)
    }

    private func getJSON<Res: Decodable>(path: String, bearerToken: String) async throws -> Res {
        var req = URLRequest(url: baseURL.appendingPathComponent(path))
        req.httpMethod = "GET"
        req.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        return try await roundTrip(req)
    }

    private func roundTrip<Res: Decodable>(_ req: URLRequest) async throws -> Res {
        let (data, resp): (Data, URLResponse)
        do { (data, resp) = try await session.data(for: req) }
        catch { throw GatewaySessionError.network(error.localizedDescription) }
        guard let http = resp as? HTTPURLResponse else {
            throw GatewaySessionError.network("non-http response")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw GatewaySessionError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        do { return try JSONDecoder().decode(Res.self, from: data) }
        catch { throw GatewaySessionError.decode("\(error)") }
    }
}
