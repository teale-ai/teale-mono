import Foundation
import SharedTypes
import ModelManager

// MARK: - Exo Inference Provider

public actor ExoProvider: InferenceProvider {
    private var baseURL: URL
    private var preferredModelID: String?
    private var currentDescriptor: ModelDescriptor?
    private var _status: EngineStatus = .idle
    private var availableModels: [String] = []
    private var runningModels: [String] = []
    private var lastStatusMessage: String = "Exo not checked yet"

    private let session: URLSession

    public init(baseURLString: String = "http://localhost:52415", preferredModelID: String? = nil) {
        self.baseURL = Self.normalizedBaseURL(from: baseURLString)
        self.preferredModelID = Self.normalizedModelID(preferredModelID)

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 300
        self.session = URLSession(configuration: config)
    }

    public var status: EngineStatus {
        _status
    }

    public var loadedModel: ModelDescriptor? {
        currentDescriptor
    }

    public var availableModelIDs: [String] {
        availableModels
    }

    public var runningModelIDs: [String] {
        runningModels
    }

    public var connectionSummary: String {
        lastStatusMessage
    }

    public func updateConfiguration(baseURLString: String, preferredModelID: String?) {
        baseURL = Self.normalizedBaseURL(from: baseURLString)
        self.preferredModelID = Self.normalizedModelID(preferredModelID)
    }

    public func loadModel(_ descriptor: ModelDescriptor) async throws {
        preferredModelID = descriptor.huggingFaceRepo
        try await refreshSelection()
    }

    public func unloadModel() async {
        preferredModelID = nil
        currentDescriptor = nil
        _status = .idle
        lastStatusMessage = "Exo model selection cleared"
    }

    public nonisolated func generate(request: ChatCompletionRequest) -> AsyncThrowingStream<ChatCompletionChunk, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await self._generate(request: request, continuation: continuation)
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    public func refreshSelection() async throws {
        do {
            availableModels = try await fetchAvailableModels()
        } catch {
            availableModels = []
        }

        runningModels = try await fetchRunningModels()

        if let preferredModelID {
            guard let runningModelID = firstMatchingModelID(for: preferredModelID, in: runningModels) else {
                currentDescriptor = nil
                _status = .error("Preferred Exo model is not running: \(preferredModelID)")
                if availableModels.contains(where: { modelIdentifiersMatch($0, preferredModelID) }) {
                    lastStatusMessage = "Exo is reachable, but \(preferredModelID) is not running."
                } else {
                    lastStatusMessage = "Exo is reachable, but \(preferredModelID) was not found."
                }
                return
            }

            let descriptor = modelDescriptorForExternalID(runningModelID)
            currentDescriptor = descriptor
            _status = .ready(descriptor)
            lastStatusMessage = "Connected to Exo at \(baseURL.absoluteString) using \(runningModelID)"
            return
        }

        if runningModels.count == 1, let runningModelID = runningModels.first {
            let descriptor = modelDescriptorForExternalID(runningModelID)
            currentDescriptor = descriptor
            _status = .ready(descriptor)
            lastStatusMessage = "Connected to Exo at \(baseURL.absoluteString) using \(runningModelID)"
            return
        }

        currentDescriptor = nil

        if runningModels.isEmpty {
            _status = .idle
            lastStatusMessage = "Connected to Exo, but no running models were detected."
        } else {
            _status = .idle
            lastStatusMessage = "Connected to Exo. Multiple running models detected; set a preferred model."
        }
    }

    private func _generate(
        request: ChatCompletionRequest,
        continuation: AsyncThrowingStream<ChatCompletionChunk, Error>.Continuation
    ) async throws {
        // Make sure we have an up-to-date view of exo's running models. The
        // single-descriptor `currentDescriptor` path still works for
        // preferredModelID / single-model setups, but when multiple exo
        // instances are live the resolution has to come from request.model.
        if currentDescriptor == nil || runningModels.isEmpty {
            try await refreshSelection()
        }

        let descriptor = try resolveDescriptor(for: request.model)

        _status = .generating(descriptor, tokensGenerated: 0)

        let url = baseURL.appending(path: "v1/chat/completions")
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var proxiedRequest = request
        // Forward with exo's internal HF-repo ID. This is the ID exo knows
        // (e.g., "mlx-community/DeepSeek-V3.2-8bit"), distinct from the
        // canonical OpenRouter slug the gateway sent (e.g., "deepseek/
        // deepseek-v3.2"). resolveDescriptor(for:) did the mapping.
        proxiedRequest.model = descriptor.huggingFaceRepo
        proxiedRequest.stream = true
        urlRequest.httpBody = try JSONEncoder().encode(proxiedRequest)

        do {
            let (bytes, response) = try await session.bytes(for: urlRequest)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw ExoProviderError.invalidResponse
            }

            guard httpResponse.statusCode == 200 else {
                throw try await decodeServerError(from: bytes, statusCode: httpResponse.statusCode)
            }

            var tokenCount = 0
            for try await line in bytes.lines {
                guard line.hasPrefix("data: ") else { continue }
                let payload = String(line.dropFirst(6))

                if payload == "[DONE]" {
                    break
                }

                guard let data = payload.data(using: .utf8) else { continue }
                let chunk = try JSONDecoder().decode(ChatCompletionChunk.self, from: data)
                if let content = chunk.choices.first?.delta.content, !content.isEmpty {
                    tokenCount += 1
                    _status = .generating(descriptor, tokensGenerated: tokenCount)
                }
                continuation.yield(chunk)
            }

            _status = .ready(descriptor)
            continuation.finish()
        } catch {
            _status = .error(error.localizedDescription)
            throw error
        }
    }

    private func fetchAvailableModels() async throws -> [String] {
        do {
            let data = try await fetchData(path: "v1/models")
            return parseModelIDs(from: data)
        } catch {
            let data = try await fetchData(path: "models")
            return parseModelIDs(from: data)
        }
    }

    private func fetchRunningModels() async throws -> [String] {
        do {
            let data = try await fetchData(path: "ollama/api/ps")
            return parseModelIDs(from: data)
        } catch {
            let data = try await fetchData(path: "state")
            return parseStateModelIDs(from: data)
        }
    }

    /// Find the exo-running model whose descriptor best matches the incoming
    /// request's `model` field. Accepts canonical OpenRouter slugs
    /// ("deepseek/deepseek-v3.2"), HF repo IDs
    /// ("mlx-community/DeepSeek-V3.2-8bit"), and local catalog IDs.
    ///
    /// Falls back in order: explicit request.model → preferredModelID →
    /// single-running auto-pick → noModelSelected error. This is the path
    /// that makes a multi-model exo cluster correctly routable when the
    /// Teale gateway dispatches one request per canonical slug.
    private func resolveDescriptor(for requestedModel: String?) throws -> ModelDescriptor {
        if let requestedModel = requestedModel, !requestedModel.isEmpty {
            if let exoID = findRunningExoID(matching: requestedModel) {
                return modelDescriptorForExternalID(exoID)
            }
            // Fall through only if the request didn't pin a specific model.
            // If it did and we can't match, surface the error — never
            // silently substitute another model.
            throw ExoProviderError.serverError(
                "no running exo model matches '\(requestedModel)' (running: \(runningModels.joined(separator: ", ")))"
            )
        }

        if let preferred = preferredModelID, !preferred.isEmpty,
           let exoID = firstMatchingModelID(for: preferred, in: runningModels) {
            return modelDescriptorForExternalID(exoID)
        }

        if runningModels.count == 1, let only = runningModels.first {
            return modelDescriptorForExternalID(only)
        }

        throw ExoProviderError.noModelSelected
    }

    /// Map a requested model ID (canonical slug, HF repo, or local id) to
    /// one of exo's currently-running model IDs. Prefers direct normalized
    /// matches; falls back to descriptor-resolved aliases.
    private func findRunningExoID(matching requested: String) -> String? {
        if let direct = firstMatchingModelID(for: requested, in: runningModels) {
            return direct
        }
        for exoID in runningModels {
            let desc = modelDescriptorForExternalID(exoID)
            if let slug = desc.openrouterId, modelIdentifiersMatch(slug, requested) {
                return exoID
            }
            if modelIdentifiersMatch(desc.huggingFaceRepo, requested) {
                return exoID
            }
            if modelIdentifiersMatch(desc.id, requested) {
                return exoID
            }
        }
        return nil
    }

    private func fetchData(path: String) async throws -> Data {
        let url = baseURL.appending(path: path)
        let (data, response) = try await session.data(from: url)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw ExoProviderError.invalidResponse
        }

        guard httpResponse.statusCode == 200 else {
            if let apiError = try? JSONDecoder().decode(APIErrorResponse.self, from: data) {
                throw ExoProviderError.serverError(apiError.error.message)
            }
            throw ExoProviderError.serverError("HTTP \(httpResponse.statusCode)")
        }

        return data
    }

    private func decodeServerError(
        from bytes: URLSession.AsyncBytes,
        statusCode: Int
    ) async throws -> ExoProviderError {
        var text = ""
        for try await line in bytes.lines {
            text += line
        }

        if let data = text.data(using: .utf8),
           let apiError = try? JSONDecoder().decode(APIErrorResponse.self, from: data) {
            return .serverError(apiError.error.message)
        }

        return .serverError("HTTP \(statusCode)")
    }

    private func parseModelIDs(from data: Data) -> [String] {
        guard let object = try? JSONSerialization.jsonObject(with: data) else {
            return []
        }

        if let dictionary = object as? [String: Any] {
            if let dataArray = dictionary["data"] as? [[String: Any]] {
                return extractModelIDs(from: dataArray)
            }
            if let modelsArray = dictionary["models"] as? [[String: Any]] {
                return extractModelIDs(from: modelsArray)
            }
        }

        if let array = object as? [[String: Any]] {
            return extractModelIDs(from: array)
        }

        return []
    }

    private func parseStateModelIDs(from data: Data) -> [String] {
        guard let object = try? JSONSerialization.jsonObject(with: data) else {
            return []
        }
        var identifiers: Set<String> = []
        collectModelIDs(from: object, into: &identifiers)
        return Array(identifiers).sorted()
    }

    private func extractModelIDs(from rows: [[String: Any]]) -> [String] {
        rows.compactMap { row in
            (row["id"] as? String)
            ?? (row["model"] as? String)
            ?? (row["model_id"] as? String)
            ?? (row["name"] as? String)
        }
    }

    private func collectModelIDs(from object: Any, into identifiers: inout Set<String>) {
        if let dictionary = object as? [String: Any] {
            if let value = dictionary["model_id"] as? String {
                identifiers.insert(value)
            } else if let value = dictionary["model"] as? String {
                identifiers.insert(value)
            } else if let value = dictionary["id"] as? String,
                      dictionary.keys.contains("placement") {
                identifiers.insert(value)
            }

            for value in dictionary.values {
                collectModelIDs(from: value, into: &identifiers)
            }
            return
        }

        if let array = object as? [Any] {
            for value in array {
                collectModelIDs(from: value, into: &identifiers)
            }
        }
    }

    private func firstMatchingModelID(for preferredModelID: String, in candidates: [String]) -> String? {
        candidates.first(where: { modelIdentifiersMatch($0, preferredModelID) })
    }

    private static func normalizedBaseURL(from string: String) -> URL {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidate = trimmed.isEmpty ? "http://localhost:52415" : trimmed
        let normalized = candidate.hasSuffix("/") ? String(candidate.dropLast()) : candidate
        return URL(string: normalized) ?? URL(string: "http://localhost:52415")!
    }

    private static func normalizedModelID(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

enum ExoProviderError: LocalizedError {
    case noModelSelected
    case invalidResponse
    case serverError(String)

    var errorDescription: String? {
        switch self {
        case .noModelSelected:
            return "No Exo model is selected. Start a model in Exo or set a preferred model."
        case .invalidResponse:
            return "Exo returned an invalid response."
        case .serverError(let message):
            return "Exo error: \(message)"
        }
    }
}

func modelDescriptorForExternalID(_ modelID: String) -> ModelDescriptor {
    if let known = ModelCatalog.allModels.first(where: {
        modelIdentifiersMatch($0.id, modelID)
        || modelIdentifiersMatch($0.huggingFaceRepo, modelID)
        || modelIdentifiersMatch($0.name, modelID)
    }) {
        return known
    }

    let quantization: QuantizationType
    let lowercasedID = modelID.lowercased()
    if lowercasedID.contains("fp16") {
        quantization = .fp16
    } else if lowercasedID.contains("8bit") || lowercasedID.contains("-q8") || lowercasedID.contains("_q8") {
        quantization = .q8
    } else {
        quantization = .q4
    }

    let parameterCount = inferredParameterCount(from: modelID)
    let numericParameterCount = Double(parameterCount.dropLast()) ?? 8
    let sizeMultiplier: Double
    switch quantization {
    case .q4:
        sizeMultiplier = 0.55
    case .q8:
        sizeMultiplier = 1.1
    case .fp16:
        sizeMultiplier = 2.2
    }

    let estimatedSizeGB = max(0.5, numericParameterCount * sizeMultiplier)
    let requiredRAMGB = max(4.0, estimatedSizeGB * 1.6)
    let token = modelID.split(separator: "/").last.map(String.init) ?? modelID
    let family = token
        .split(whereSeparator: { $0 == "-" || $0 == "_" || $0 == ":" })
        .first
        .map { String($0).capitalized } ?? "External"

    return ModelDescriptor(
        id: slugifiedModelID(modelID),
        name: humanReadableModelName(modelID),
        huggingFaceRepo: modelID,
        parameterCount: parameterCount,
        quantization: quantization,
        estimatedSizeGB: estimatedSizeGB,
        requiredRAMGB: requiredRAMGB,
        family: family,
        description: "Served by an external Exo backend"
    )
}

func modelIdentifiersMatch(_ lhs: String, _ rhs: String) -> Bool {
    !canonicalModelIdentifiers(for: lhs).isDisjoint(with: canonicalModelIdentifiers(for: rhs))
}

private func canonicalModelIdentifiers(for value: String) -> Set<String> {
    let lowercased = value.lowercased()
    let lastComponent = lowercased.split(separator: "/").last.map(String.init) ?? lowercased
    return [
        lowercased,
        lastComponent,
        slugifiedModelID(lowercased),
        slugifiedModelID(lastComponent),
    ]
}

private func slugifiedModelID(_ value: String) -> String {
    let mapped = value.lowercased().map { character -> Character in
        if character.isLetter || character.isNumber {
            return character
        }
        return "-"
    }
    let slug = String(mapped)
        .replacingOccurrences(of: "--+", with: "-", options: .regularExpression)
        .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    return slug
}

private func humanReadableModelName(_ modelID: String) -> String {
    let token = modelID.split(separator: "/").last.map(String.init) ?? modelID
    return token
        .replacingOccurrences(of: "_", with: " ")
        .replacingOccurrences(of: "-", with: " ")
        .split(separator: " ")
        .map { $0.capitalized }
        .joined(separator: " ")
}

private func inferredParameterCount(from modelID: String) -> String {
    let range = NSRange(modelID.startIndex..<modelID.endIndex, in: modelID)
    let pattern = "(\\d+(?:\\.\\d+)?)\\s*[bB]"
    let regex = try? NSRegularExpression(pattern: pattern)

    if let match = regex?.firstMatch(in: modelID, options: [], range: range),
       let captureRange = Range(match.range(at: 1), in: modelID) {
        return "\(modelID[captureRange].uppercased())B"
    }

    return "8B"
}
