import Foundation
import Hummingbird
import HTTPTypes

// MARK: - Local origin policy

/// Who may talk to the local control API from a browser context.
///
/// The API binds 127.0.0.1 and (in the default localhost mode) needs no API
/// key, so any web page the user visits could otherwise drive it with
/// `fetch("http://127.0.0.1:11435/...")` - send credits, create API keys,
/// change settings. Shared contract with the Rust node (status_server.rs):
///
/// - Requests WITHOUT an `Origin` header (CLI, menu bar, curl) pass.
/// - Requests WITH an `Origin` pass only for the bundled companion UI
///   (`teale://localhost`, plus the `teale.localhost` forms wry uses on
///   Windows) and the exact https origin of `TEALE_DESKTOP_WEB_URL`.
///   Anything else is a 403, including the CORS preflight.
/// - The `Host` header must name the loopback interface on our port
///   (DNS-rebinding guard) while the server is bound to loopback.
public enum LocalOriginPolicy {
    public static let bundledOrigins: Set<String> = [
        "teale://localhost",
        "http://teale.localhost",
        "https://teale.localhost",
    ]

    public static let desktopWebOverrideEnvironmentKey = "TEALE_DESKTOP_WEB_URL"

    /// The dev-only remote desktop UI override. Only https URLs are honored;
    /// an http (or otherwise malformed) value is ignored entirely.
    public static func desktopWebOverrideURL(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL? {
        guard let raw = environment[desktopWebOverrideEnvironmentKey]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !raw.isEmpty,
            let url = URL(string: raw),
            url.scheme?.lowercased() == "https",
            url.host?.isEmpty == false
        else { return nil }
        return url
    }

    /// The serialized origin (`scheme://host[:port]`) of a URL, as a browser
    /// would send it in the `Origin` header (default ports omitted).
    public static func origin(of url: URL) -> String? {
        guard let scheme = url.scheme?.lowercased(), let host = url.host?.lowercased(), !host.isEmpty else {
            return nil
        }
        let hostPart = host.contains(":") ? "[\(host)]" : host
        if let port = url.port,
           !((scheme == "https" && port == 443) || (scheme == "http" && port == 80)) {
            return "\(scheme)://\(hostPart):\(port)"
        }
        return "\(scheme)://\(hostPart)"
    }

    /// All origins allowed to call the local API from a browser context.
    public static func allowedOrigins(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Set<String> {
        var origins = bundledOrigins
        if let override = desktopWebOverrideURL(environment: environment),
           let overrideOrigin = origin(of: override) {
            origins.insert(overrideOrigin)
        }
        return origins
    }

    /// Returns the origin to echo back when `origin` is allowed, else nil.
    public static func matchedOrigin(_ origin: String, allowed: Set<String>) -> String? {
        let normalized = origin.trimmingCharacters(in: .whitespaces).lowercased()
        return allowed.contains(normalized) ? normalized : nil
    }

    /// DNS-rebinding guard: the `Host` (HTTP/1) / `:authority` (HTTP/2)
    /// value must be a loopback name with our exact port. A missing value
    /// (HTTP/1.0 without Host) is not a browser request and passes.
    public static func isAllowedHost(_ authority: String?, port: Int) -> Bool {
        guard let authority else { return true }
        let value = authority.trimmingCharacters(in: .whitespaces).lowercased()
        return value == "127.0.0.1:\(port)"
            || value == "localhost:\(port)"
            || value == "[::1]:\(port)"
    }
}

// MARK: - Middleware

struct LocalOriginGuardMiddleware<Context: RequestContext>: RouterMiddleware {
    let port: Int
    /// When the server is bound to 0.0.0.0 (network access enabled) LAN
    /// clients legitimately use other Host values; every request then needs
    /// an API key anyway (AuthMiddleware), so the Host check is skipped.
    let enforceLoopbackHost: Bool
    let allowedOrigins: Set<String>

    init(port: Int, enforceLoopbackHost: Bool, allowedOrigins: Set<String> = LocalOriginPolicy.allowedOrigins()) {
        self.port = port
        self.enforceLoopbackHost = enforceLoopbackHost
        self.allowedOrigins = allowedOrigins
    }

    func handle(
        _ request: Request,
        context: Context,
        next: (Request, Context) async throws -> Response
    ) async throws -> Response {
        // NIOHTTPTypes maps the HTTP/1 Host header to `authority`; fall back
        // to a literal Host field in case a codec leaves it in the headers.
        let authority = request.head.authority ?? Self.hostHeaderName.flatMap { request.headers[$0] }
        if enforceLoopbackHost, !LocalOriginPolicy.isAllowedHost(authority, port: port) {
            return Self.forbidden("Host not allowed")
        }

        guard let origin = request.headers[.origin] else {
            // Native clients (CLI, menu bar, curl) send no Origin.
            return try await next(request, context)
        }
        guard let allowed = LocalOriginPolicy.matchedOrigin(origin, allowed: allowedOrigins) else {
            return Self.forbidden("Origin not allowed")
        }

        if request.method == .options {
            var headers = HTTPFields()
            Self.applyCORS(to: &headers, origin: allowed)
            headers[.accessControlAllowMethods] = "GET, POST, PUT, PATCH, DELETE, OPTIONS"
            headers[.accessControlAllowHeaders] = "Content-Type, Accept, Authorization"
            headers[.accessControlMaxAge] = "600"
            return Response(status: .noContent, headers: headers)
        }

        var response = try await next(request, context)
        Self.applyCORS(to: &response.headers, origin: allowed)
        return response
    }

    private static var hostHeaderName: HTTPField.Name? { HTTPField.Name("Host") }

    private static func applyCORS(to headers: inout HTTPFields, origin: String) {
        headers[.accessControlAllowOrigin] = origin
        headers[.vary] = "Origin"
    }

    private static func forbidden(_ message: String) -> Response {
        let body = "{\"error\":{\"message\":\"\(message)\",\"type\":\"forbidden\",\"code\":\"origin_not_allowed\"}}"
        return Response(
            status: .forbidden,
            headers: [.contentType: "application/json"],
            body: .init(byteBuffer: .init(string: body))
        )
    }
}
