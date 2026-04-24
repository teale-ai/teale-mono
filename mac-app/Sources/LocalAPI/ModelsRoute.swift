import Foundation
import Hummingbird
import SharedTypes
import InferenceEngine

// MARK: - Models Route

enum ModelsRoute {
    /// Virtual model ID that tells Teale to automatically select the best model(s).
    /// Clients can send `"model": "teale-auto"` or omit `model` entirely.
    static let autoModelID = "teale-auto"

    static func advertisedModelIDs(for descriptor: ModelDescriptor) -> [String] {
        [descriptor.openrouterId, descriptor.huggingFaceRepo, descriptor.id]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    static func advertisedModelID(for descriptor: ModelDescriptor) -> String {
        advertisedModelIDs(for: descriptor).first ?? descriptor.huggingFaceRepo
    }

    static func modelIDMatches(_ availableModelID: String, requested: String) -> Bool {
        let normalizedAvailable = normalizeModelID(availableModelID)
        let normalizedRequested = normalizeModelID(requested)
        guard !normalizedAvailable.isEmpty, !normalizedRequested.isEmpty else { return false }
        if normalizedAvailable == normalizedRequested { return true }

        let availableTail = normalizedAvailable.split(separator: "/").last.map(String.init) ?? normalizedAvailable
        let requestedTail = normalizedRequested.split(separator: "/").last.map(String.init) ?? normalizedRequested
        return availableTail == requestedTail
    }

    private static func normalizeModelID(_ value: String) -> String {
        value.lowercased().replacingOccurrences(of: "_", with: "-")
    }

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
                id: advertisedModelID(for: loaded),
                object: "model",
                created: now,
                ownedBy: "local"
            ))
            seen.insert(advertisedModelID(for: loaded))
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

        for gatewayModelID in await gatewayModelIDs() where !seen.contains(gatewayModelID) {
            models.append(ModelsListResponse.ModelObject(
                id: gatewayModelID,
                object: "model",
                created: now,
                ownedBy: "gateway"
            ))
            seen.insert(gatewayModelID)
        }

        let response = ModelsListResponse(data: models)
        let data = try JSONEncoder().encode(response)

        return Response(
            status: .ok,
            headers: [.contentType: "application/json"],
            body: .init(byteBuffer: .init(data: data))
        )
    }

    private struct GatewayModelsEnvelope: Decodable {
        let data: [GatewayModelEntry]
    }

    private struct GatewayModelEntry: Decodable {
        let id: String
        let loadedDeviceCount: Int?
    }

    private static func gatewayModelIDs() async -> [String] {
        let url = gatewayBaseURL().appending(path: "v1/models")
        var request = URLRequest(url: url)
        request.timeoutInterval = 4

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 4
        config.timeoutIntervalForResource = 4
        let session = URLSession(configuration: config)

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode) else {
                return []
            }
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            let envelope = try decoder.decode(GatewayModelsEnvelope.self, from: data)
            return envelope.data
                .filter { ($0.loadedDeviceCount ?? 0) > 0 && !$0.id.hasPrefix("teale/") }
                .map(\.id)
        } catch {
            return []
        }
    }

    private static func gatewayBaseURL() -> URL {
        let fallback = URL(string: "https://gateway.teale.com")!
        let raw = UserDefaults.standard.string(forKey: "teale.gateway_fallback_url") ?? fallback.absoluteString
        guard var components = URLComponents(string: raw) else {
            return fallback
        }

        if components.scheme == "wss" {
            components.scheme = "https"
        } else if components.scheme == "ws" {
            components.scheme = "http"
        }

        if let host = components.host, host.hasPrefix("relay.") {
            components.host = host.replacingOccurrences(of: "relay.", with: "gateway.", options: .anchored)
        }

        components.path = ""
        components.query = nil
        components.fragment = nil
        return components.url ?? fallback
    }
}
