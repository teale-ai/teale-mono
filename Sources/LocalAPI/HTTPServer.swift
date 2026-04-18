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
    private let controller: (any LocalAppControlling)?

    public init(
        engine: InferenceEngineManager,
        port: Int = 11435,
        apiKeyStore: APIKeyStore = APIKeyStore(),
        allowNetworkAccess: Bool = false,
        controller: (any LocalAppControlling)? = nil
    ) {
        self.engine = engine
        self.port = port
        self.apiKeyStore = apiKeyStore
        self.allowNetworkAccess = allowNetworkAccess
        self.controller = controller
    }

    public func start() async throws {
        let engine = self.engine
        let keyStore = self.apiKeyStore
        let requireAuth = self.allowNetworkAccess
        let controller = self.controller

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

        // Remote control endpoints
        router.get("/v1/app") { _, _ -> Response in
            return try await RemoteControlRoute.snapshot(controller: controller)
        }

        router.patch("/v1/app/settings") { request, _ -> Response in
            return try await RemoteControlRoute.updateSettings(request: request, controller: controller)
        }

        router.post("/v1/app/models/load") { request, _ -> Response in
            return try await RemoteControlRoute.loadModel(request: request, controller: controller)
        }

        router.post("/v1/app/models/download") { request, _ -> Response in
            return try await RemoteControlRoute.downloadModel(request: request, controller: controller)
        }

        router.post("/v1/app/models/unload") { _, _ -> Response in
            return try await RemoteControlRoute.unloadModel(controller: controller)
        }

        let bindAddress = allowNetworkAccess ? "0.0.0.0" : "127.0.0.1"
        let app = Application(
            router: router,
            configuration: .init(address: .hostname(bindAddress, port: port))
        )
        try await app.run()
    }
}
