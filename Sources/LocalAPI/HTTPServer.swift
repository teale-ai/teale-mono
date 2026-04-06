import Foundation
import Hummingbird
import SharedTypes
import InferenceEngine

// MARK: - HTTP Server

public actor LocalHTTPServer {
    private let engine: InferenceEngineManager
    public let port: Int
    private let apiKeyStore: APIKeyStore
    private let allowNetworkAccess: Bool

    public init(engine: InferenceEngineManager, port: Int = 11435, apiKeyStore: APIKeyStore = APIKeyStore(), allowNetworkAccess: Bool = false) {
        self.engine = engine
        self.port = port
        self.apiKeyStore = apiKeyStore
        self.allowNetworkAccess = allowNetworkAccess
    }

    public func start() async throws {
        let engine = self.engine
        let keyStore = self.apiKeyStore
        let requireAuth = self.allowNetworkAccess

        let router = Router()

        // CORS
        router.addMiddleware {
            CORSMiddleware(
                allowOrigin: .originBased,
                allowHeaders: [.contentType, .authorization],
                allowMethods: [.get, .post, .options]
            )
        }

        // Auth (require key when network access is enabled)
        router.addMiddleware {
            AuthMiddleware(keyStore: keyStore, requireAuth: requireAuth)
        }

        // Health check (no auth needed — middleware passes through if not required)
        router.get("/health") { _, _ in
            return "{\"status\":\"ok\"}"
        }

        // Models endpoint
        router.get("/v1/models") { _, _ -> Response in
            return try await ModelsRoute.handle(engine: engine)
        }

        // Chat completions endpoint
        router.post("/v1/chat/completions") { request, _ -> Response in
            return try await ChatCompletionsRoute.handle(request: request, engine: engine)
        }

        let bindAddress = allowNetworkAccess ? "0.0.0.0" : "127.0.0.1"
        let app = Application(
            router: router,
            configuration: .init(address: .hostname(bindAddress, port: port))
        )
        try await app.run()
    }
}
