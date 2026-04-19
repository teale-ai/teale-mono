import Foundation
import Hummingbird
import SharedTypes
import InferenceEngine

// MARK: - Models Route

enum ModelsRoute {
    /// Virtual model ID that tells Teale to automatically select the best model(s).
    /// Clients can send `"model": "teale-auto"` or omit `model` entirely.
    static let autoModelID = "teale-auto"

    static func handle(engine: InferenceEngineManager, peerModelProvider: PeerModelProvider?) async throws -> Response {
        var models: [ModelsListResponse.ModelObject] = []
        var seen: Set<String> = []
        let now = Int(Date().timeIntervalSince1970)

        // teale-auto: let the Compiler pick the best model(s) automatically
        models.append(ModelsListResponse.ModelObject(
            id: autoModelID,
            object: "model",
            created: now,
            ownedBy: "teale"
        ))

        if let loaded = await engine.loadedModel {
            models.append(ModelsListResponse.ModelObject(
                id: loaded.huggingFaceRepo,
                object: "model",
                created: now,
                ownedBy: "local"
            ))
            seen.insert(loaded.huggingFaceRepo)
        }

        // Include models from connected WAN and cluster peers
        if let provider = peerModelProvider {
            let peerModels = await provider()
            for pm in peerModels where !seen.contains(pm.id) {
                models.append(ModelsListResponse.ModelObject(
                    id: pm.id,
                    object: "model",
                    created: now,
                    ownedBy: pm.ownedBy
                ))
                seen.insert(pm.id)
            }
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
