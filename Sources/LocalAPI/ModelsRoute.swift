import Foundation
import Hummingbird
import SharedTypes
import InferenceEngine

// MARK: - Models Route

enum ModelsRoute {
    static func handle(engine: InferenceEngineManager) async throws -> Response {
        var models: [ModelsListResponse.ModelObject] = []

        if let loaded = await engine.loadedModel {
            models.append(ModelsListResponse.ModelObject(
                id: loaded.huggingFaceRepo,
                object: "model",
                created: Int(Date().timeIntervalSince1970),
                ownedBy: "local"
            ))
        }

        let response = ModelsListResponse(data: models)
        let data = try JSONEncoder().encode(response)

        return Response(
            status: .ok,
            headers: [.contentType: "application/json"],
            body: .init(byteBuffer: .init(data: data))
        )
    }
}
