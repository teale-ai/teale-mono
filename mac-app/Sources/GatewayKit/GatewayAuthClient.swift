import Foundation

public enum GatewayAuthError: Error, CustomStringConvertible {
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
}

/// Handles the ed25519 challenge → sign → exchange dance with
/// `gateway.teale.com`. Works on both macOS and iOS.
public actor GatewayAuthClient {

    public let baseURL: URL
    private let identity: GatewayIdentity
    private let session: URLSession

    private var cachedToken: String?
    private var expiresAt: TimeInterval = 0

    public init(
        baseURL: URL = URL(string: "https://gateway.teale.com")!,
        identity: GatewayIdentity = .shared,
        session: URLSession = .shared
    ) {
        self.baseURL = baseURL
        self.identity = identity
        self.session = session
    }

    public var deviceID: String { identity.deviceID }

    /// Returns a valid device bearer token, running challenge + exchange
    /// as needed. Refreshes when the token has fewer than 60 s remaining.
    public func bearer() async throws -> String {
        let now = Date().timeIntervalSince1970
        if let t = cachedToken, expiresAt - now > 60 { return t }
        return try await exchange()
    }

    public func invalidate() { cachedToken = nil; expiresAt = 0 }

    // MARK: - Flow

    private struct ChallengeReq: Encodable { let deviceID: String }
    private struct ChallengeRes: Decodable { let nonce: String; let expiresAt: Int64 }
    private struct ExchangeReq: Encodable { let deviceID: String; let nonce: String; let signature: String }
    public struct ExchangeRes: Decodable { public let token: String; public let expiresAt: Int64; public let welcomeBonus: Int64? }

    /// Runs one full challenge + sign + exchange cycle and caches the result.
    @discardableResult
    public func exchange() async throws -> String {
        let did = identity.deviceID
        let ch: ChallengeRes = try await postJSON(
            path: "/v1/auth/device/challenge",
            body: ChallengeReq(deviceID: did)
        )
        guard let nonceBytes = Data(base64Encoded: ch.nonce) else {
            throw GatewayAuthError.decode("nonce not base64")
        }
        let sigHex = hexLower(identity.sign(nonceBytes))
        let ex: ExchangeRes = try await postJSON(
            path: "/v1/auth/device/exchange",
            body: ExchangeReq(deviceID: did, nonce: ch.nonce, signature: sigHex)
        )
        cachedToken = ex.token
        expiresAt = TimeInterval(ex.expiresAt)
        return ex.token
    }

    // MARK: - HTTP helpers

    public func postJSON<Req: Encodable, Res: Decodable>(
        path: String, body: Req, bearerToken: String? = nil
    ) async throws -> Res {
        var req = URLRequest(url: baseURL.appendingPathComponent(path))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token = bearerToken {
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        req.httpBody = try JSONEncoder().encode(body)
        return try await roundTrip(req)
    }

    public func patchJSON<Req: Encodable, Res: Decodable>(
        path: String, body: Req, bearerToken: String
    ) async throws -> Res {
        var req = URLRequest(url: baseURL.appendingPathComponent(path))
        req.httpMethod = "PATCH"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        req.httpBody = try JSONEncoder().encode(body)
        return try await roundTrip(req)
    }

    public func getJSON<Res: Decodable>(path: String, bearerToken: String) async throws -> Res {
        var req = URLRequest(url: baseURL.appendingPathComponent(path))
        req.httpMethod = "GET"
        req.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        return try await roundTrip(req)
    }

    public func deleteJSON<Res: Decodable>(path: String, bearerToken: String) async throws -> Res {
        var req = URLRequest(url: baseURL.appendingPathComponent(path))
        req.httpMethod = "DELETE"
        req.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        return try await roundTrip(req)
    }

    private func roundTrip<Res: Decodable>(_ req: URLRequest) async throws -> Res {
        let (data, resp): (Data, URLResponse)
        do { (data, resp) = try await session.data(for: req) }
        catch { throw GatewayAuthError.network(error.localizedDescription) }
        guard let http = resp as? HTTPURLResponse else {
            throw GatewayAuthError.network("non-http response")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw GatewayAuthError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        do { return try JSONDecoder().decode(Res.self, from: data) }
        catch { throw GatewayAuthError.decode("\(error)") }
    }

    // Exposed for subordinate clients that want to post/get with auth
    // but reuse this actor's URLSession + baseURL.
    public func makeAuthedRequest(
        method: String, path: String, body: Data? = nil
    ) async throws -> URLRequest {
        let token = try await bearer()
        var req = URLRequest(url: baseURL.appendingPathComponent(path))
        req.httpMethod = method
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if body != nil {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = body
        }
        return req
    }

    nonisolated public var urlSession: URLSession { session }
    nonisolated public var base: URL { baseURL }
}
