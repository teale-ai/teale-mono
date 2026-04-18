import Foundation
import Hummingbird
import SharedTypes

// MARK: - Auth Middleware

public struct AuthMiddleware<Context: RequestContext>: RouterMiddleware {
    let keyStore: APIKeyStore
    let requireAuth: Bool

    public init(keyStore: APIKeyStore, requireAuth: Bool = false) {
        self.keyStore = keyStore
        self.requireAuth = requireAuth
    }

    public func handle(
        _ request: Request,
        context: Context,
        next: (Request, Context) async throws -> Response
    ) async throws -> Response {
        // Check for Authorization header
        if let authHeader = request.headers[.authorization] {
            let token = authHeader.hasPrefix("Bearer ")
                ? String(authHeader.dropFirst(7))
                : authHeader

            guard await keyStore.validate(token) else {
                return unauthorizedResponse(message: "Invalid API key")
            }

            await keyStore.markUsed(key: token)
            return try await next(request, context)
        }

        // No auth header present
        if requireAuth {
            return unauthorizedResponse(message: "API key required. Set Authorization: Bearer sk-teale-...")
        }

        // No auth required (localhost mode) — pass through
        return try await next(request, context)
    }

    private func unauthorizedResponse(message: String) -> Response {
        let body = "{\"error\":{\"message\":\"\(message)\",\"type\":\"authentication_error\",\"code\":\"invalid_api_key\"}}"
        return Response(
            status: .unauthorized,
            headers: [.contentType: "application/json"],
            body: .init(byteBuffer: .init(string: body))
        )
    }
}
