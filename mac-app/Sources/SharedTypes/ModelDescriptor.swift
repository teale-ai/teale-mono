import Foundation

// MARK: - Quantization

public enum QuantizationType: String, Codable, Sendable {
    case q2 = "2bit"
    case q4 = "4bit"
    case q5 = "5bit"
    case q8 = "8bit"
    case fp16 = "fp16"

    public var displayName: String {
        switch self {
        case .q2: return "2-bit"
        case .q4: return "4-bit"
        case .q5: return "5-bit"
        case .q8: return "8-bit"
        case .fp16: return "FP16"
        }
    }
}

// MARK: - Weight Format / Serving Backend

/// On-disk weight format of a model. Decides which download pipeline and
/// which provider can load it.
public enum ModelFormat: String, Codable, Sendable {
    /// MLX / safetensors snapshot (config.json + *.safetensors + tokenizer),
    /// downloaded through HubApi and loaded by `MLXProvider`.
    case mlx
    /// One GGUF file (or a split set of GGUF shards) loaded by llama.cpp or
    /// ds4-server.
    case gguf
}

/// The backend that actually serves a model on this device. Catalog entries
/// declare it so the app never pushes a GGUF repo through the MLX loader (or
/// an exo-sharded model through a single-node download).
public enum ModelServingBackend: String, Codable, Sendable {
    case mlx
    case llamaCpp = "llama_cpp"
    case ds4
    case rapidMLX = "rapid_mlx"
    /// Multi-node exo cluster. The app does not download these itself.
    case exo

    /// Backend used when a descriptor does not say: GGUF files go to
    /// llama.cpp, everything else to MLX.
    public static func defaultBackend(for format: ModelFormat) -> ModelServingBackend {
        switch format {
        case .gguf: return .llamaCpp
        case .mlx: return .mlx
        }
    }
}

// MARK: - Model Descriptor

public struct ModelDescriptor: Codable, Sendable, Identifiable, Hashable {
    public var id: String                   // unique local identifier, e.g. "llama-3.1-8b-instruct-4bit"
    public var name: String                 // display name
    public var huggingFaceRepo: String      // e.g. "mlx-community/Meta-Llama-3.1-8B-Instruct-4bit"
                                            // or a local filesystem path for a scanned GGUF
    public var parameterCount: String       // e.g. "1B", "8B", "70B"
    public var quantization: QuantizationType
    public var estimatedSizeGB: Double
    public var requiredRAMGB: Double
    public var family: String               // e.g. "Llama", "Gemma", "Qwen"
    public var description: String
    public var popularityRank: Int          // 1 = most popular

    /// Canonical OpenRouter slug advertised to the gateway, e.g.
    /// "meta-llama/llama-3.1-8b-instruct". `nil` means the model is
    /// local-only: it is never advertised to the network. Every non-nil
    /// value set by Teale code comes from `OpenRouterIdResolver` and is a
    /// slug the gateway catalog (`gateway/models.yaml`) knows.
    public var openrouterId: String?

    /// Weight format (MLX snapshot vs GGUF). Defaults to `.mlx`.
    public var format: ModelFormat

    /// Backend that serves this model. Defaults from `format`.
    public var servingBackend: ModelServingBackend

    /// GGUF only: fnmatch-style patterns, relative to the repo root, that
    /// select the file(s) to download (e.g. one quant directory of a split
    /// GGUF). `nil` for MLX models and for scanned local GGUF files.
    public var ggufFiles: [String]?

    public init(
        id: String,
        name: String,
        huggingFaceRepo: String,
        parameterCount: String,
        quantization: QuantizationType,
        estimatedSizeGB: Double,
        requiredRAMGB: Double,
        family: String,
        description: String,
        popularityRank: Int = 999,
        openrouterId: String? = nil,
        format: ModelFormat = .mlx,
        servingBackend: ModelServingBackend? = nil,
        ggufFiles: [String]? = nil
    ) {
        self.id = id
        self.name = name
        self.huggingFaceRepo = huggingFaceRepo
        self.parameterCount = parameterCount
        self.quantization = quantization
        self.estimatedSizeGB = estimatedSizeGB
        self.requiredRAMGB = requiredRAMGB
        self.family = family
        self.description = description
        self.popularityRank = popularityRank
        self.openrouterId = openrouterId
        self.format = format
        self.servingBackend = servingBackend ?? ModelServingBackend.defaultBackend(for: format)
        self.ggufFiles = ggufFiles
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case huggingFaceRepo
        case parameterCount
        case quantization
        case estimatedSizeGB
        case requiredRAMGB
        case family
        case description
        case popularityRank
        case openrouterId
        case format
        case servingBackend
        case ggufFiles
    }

    /// Decodes descriptors written by older builds (no `format` /
    /// `servingBackend` / `ggufFiles`) and tolerates unknown enum values
    /// from newer peers.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        huggingFaceRepo = try container.decode(String.self, forKey: .huggingFaceRepo)
        parameterCount = try container.decode(String.self, forKey: .parameterCount)
        quantization = try container.decode(QuantizationType.self, forKey: .quantization)
        estimatedSizeGB = try container.decode(Double.self, forKey: .estimatedSizeGB)
        requiredRAMGB = try container.decode(Double.self, forKey: .requiredRAMGB)
        family = try container.decode(String.self, forKey: .family)
        description = try container.decode(String.self, forKey: .description)
        popularityRank = try container.decodeIfPresent(Int.self, forKey: .popularityRank) ?? 999
        openrouterId = try container.decodeIfPresent(String.self, forKey: .openrouterId)
        let rawFormat = try container.decodeIfPresent(String.self, forKey: .format)
        format = rawFormat.flatMap(ModelFormat.init(rawValue:)) ?? .mlx
        let rawBackend = try container.decodeIfPresent(String.self, forKey: .servingBackend)
        servingBackend = rawBackend.flatMap(ModelServingBackend.init(rawValue:))
            ?? ModelServingBackend.defaultBackend(for: format)
        ggufFiles = try container.decodeIfPresent([String].self, forKey: .ggufFiles)
    }

    /// The id to advertise on the wire to the gateway/relay: the
    /// canonical OpenRouter slug, but only when the gateway catalog knows
    /// it (`OpenRouterIdResolver.isGatewaySlug`). We deliberately do NOT
    /// fall back to `huggingFaceRepo` — for scanned local GGUFs that would
    /// leak a filesystem path, and for catalog entries the huggingFaceRepo
    /// (e.g. `mlx-community/...-4bit`) is not a canonical slug OpenRouter
    /// clients can match.
    public var advertisedId: String? {
        guard let openrouterId, OpenRouterIdResolver.isGatewaySlug(openrouterId) else {
            return nil
        }
        return openrouterId
    }

    /// All stable identifiers that may be used to reference this model.
    public var identifiers: [String] {
        [id, huggingFaceRepo, openrouterId, name]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// Returns true when `requested` matches any known identifier for this model.
    public func matchesIdentifier(_ requested: String) -> Bool {
        identifiers.contains { ModelIdentifierMatcher.matches($0, requested) }
    }
}

public enum ModelIdentifierMatcher {
    public static func matches(_ lhs: String, _ rhs: String) -> Bool {
        !canonicalForms(for: lhs).isDisjoint(with: canonicalForms(for: rhs))
    }

    public static func canonicalForms(for value: String) -> Set<String> {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        let lowercased = trimmed.lowercased()
        let lastComponent = lowercased.split(separator: "/").last.map(String.init) ?? lowercased
        let slugified = slugify(lowercased)
        let slugifiedTail = slugify(lastComponent)

        return Set([
            lowercased,
            lastComponent,
            slugified,
            slugifiedTail,
        ].filter { !$0.isEmpty })
    }

    private static func slugify(_ value: String) -> String {
        let mapped = value.map { character -> Character in
            switch character {
            case "a"..."z", "0"..."9":
                return character
            default:
                return "-"
            }
        }

        return String(mapped)
            .replacingOccurrences(of: "-+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }
}

// MARK: - OpenRouter slug resolver

/// The single place that maps a local model name (GGUF filename, HF repo,
/// rapid-mlx alias, catalog id) to the canonical OpenRouter slug Teale
/// advertises to the gateway. `ModelCatalog`, `LocalModelScanner`,
/// `GGUFScanner`, `RapidMLXProvider` and `ModelDescriptor.advertisedId`
/// all go through it.
///
/// Invariant (enforced by `OpenRouterIdResolverTests`, which parses
/// `gateway/models.yaml`): every slug in `gatewaySlugs`, and therefore
/// every slug `resolve` can return, exists as an `id` or alias in the
/// gateway catalog. Advertising a slug the gateway does not know is a
/// promise it can never route, so models outside that catalog stay
/// local-only. Do NOT add a slug here without adding it to
/// `gateway/models.yaml` first.
public enum OpenRouterIdResolver {
    /// Gateway-catalog slugs a Mac may advertise. Mirror of the `id`s in
    /// `gateway/models.yaml` that Mac supply can serve.
    public static let gatewaySlugs: Set<String> = [
        "meta-llama/llama-3.1-8b-instruct",
        "meta-llama/llama-3.3-70b-instruct",
        "qwen/qwen3.5-9b",
        "qwen/qwen3-8b",
        "qwen/qwen3-32b",
        "qwen/qwen3-30b-a3b-instruct-2507",
        "qwen/qwen3-coder-30b-a3b-instruct",
        "qwen/qwen3-coder-next-80b-a3b-instruct",
        "qwen/qwen3.6-27b",
        "qwen/qwen3.6-35b-a3b",
        "qwen/qwen2.5-0.5b-instruct",
        "qwen/qwen2.5-1.5b-instruct",
        "qwen/qwen2.5-3b-instruct",
        "mistralai/mistral-small-3.2-24b-instruct",
        "openai/gpt-oss-120b",
        "minimax/minimax-m2.7",
        "google/gemma-3-27b-it",
        "google/gemma-3-1b-it",
        "google/gemma-4-26b-a4b-it",
        "google/gemma-4-1b-it",
        "nousresearch/hermes-3-llama-3.1-8b",
        "deepseek/deepseek-v3.2",
        "deepseek-ai/deepseek-v4-flash",
        "zai/glm-5.1",
        "moonshotai/kimi-k2.6",
    ]

    /// Substring heuristics against a normalized name (see `normalize`).
    /// Order matters: the most specific needle must come first. Needles use
    /// the normalized `-` separator, so `3.1` is written `3-1`.
    static let heuristics: [(needle: String, slug: String)] = [
        ("hermes-3-llama-3-1-8b", "nousresearch/hermes-3-llama-3.1-8b"),
        ("hermes3-8b", "nousresearch/hermes-3-llama-3.1-8b"),
        ("hermes-3-8b", "nousresearch/hermes-3-llama-3.1-8b"),
        ("llama-3-3-70b-instruct", "meta-llama/llama-3.3-70b-instruct"),
        ("llama-3-1-8b-instruct", "meta-llama/llama-3.1-8b-instruct"),
        ("deepseek-v3-2", "deepseek/deepseek-v3.2"),
        ("deepseek-v4-flash", "deepseek-ai/deepseek-v4-flash"),
        ("minimax-m2-7", "minimax/minimax-m2.7"),
        ("qwen3-6-35b", "qwen/qwen3.6-35b-a3b"),
        ("qwen3-6-27b", "qwen/qwen3.6-27b"),
        ("qwen3-5-9b", "qwen/qwen3.5-9b"),
        ("qwen3-coder-next", "qwen/qwen3-coder-next-80b-a3b-instruct"),
        ("qwen3-coder-30b", "qwen/qwen3-coder-30b-a3b-instruct"),
        ("qwen3-30b-a3b", "qwen/qwen3-30b-a3b-instruct-2507"),
        ("qwen3-32b", "qwen/qwen3-32b"),
        ("qwen3-8b", "qwen/qwen3-8b"),
        ("qwen2-5-0-5b-instruct", "qwen/qwen2.5-0.5b-instruct"),
        ("qwen2-5-1-5b-instruct", "qwen/qwen2.5-1.5b-instruct"),
        ("qwen2-5-3b-instruct", "qwen/qwen2.5-3b-instruct"),
        ("gpt-oss-120b", "openai/gpt-oss-120b"),
        ("mistral-small-3-2-24b", "mistralai/mistral-small-3.2-24b-instruct"),
        ("gemma-4-26b", "google/gemma-4-26b-a4b-it"),
        ("gemma-4-1b", "google/gemma-4-1b-it"),
        ("gemma-3-27b-it", "google/gemma-3-27b-it"),
        ("gemma3-27b", "google/gemma-3-27b-it"),
        ("gemma-3-1b-it", "google/gemma-3-1b-it"),
        ("gemma3-1b", "google/gemma-3-1b-it"),
        ("glm-5-1", "zai/glm-5.1"),
        // Covers both repo names ("Kimi-K2.6" -> "kimi-k2-6") and GGUF
        // filenames like "Kimi-K2.6-UD-Q8_K_XL-00001-of-00014.gguf".
        ("kimi-k2-6", "moonshotai/kimi-k2.6"),
    ]

    /// Resolve a canonical, gateway-routable slug from any local name
    /// (GGUF filename, HF repo id, rapid-mlx alias). `nil` = local-only.
    public static func resolve(filename: String) -> String? {
        let trimmed = filename.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        // An already-canonical slug (or a gateway alias spelled the same
        // way) resolves to itself.
        let lower = trimmed.lowercased()
        if gatewaySlugs.contains(lower) {
            return lower
        }
        let norm = normalize(trimmed)
        for (needle, slug) in heuristics where norm.contains(needle) {
            return isGatewaySlug(slug) ? slug : nil
        }
        return nil
    }

    /// Same as `resolve(filename:)`; reads better at call sites that pass a
    /// repo id or server alias.
    public static func resolve(identifier: String) -> String? {
        resolve(filename: identifier)
    }

    /// True when `slug` is in the gateway catalog mirror.
    public static func isGatewaySlug(_ slug: String) -> Bool {
        gatewaySlugs.contains(slug.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }

    public static func normalize(_ s: String) -> String {
        s.lowercased()
            .replacingOccurrences(of: ".gguf", with: "")
            .replacingOccurrences(of: "_", with: "-")
            .replacingOccurrences(of: ".", with: "-")
    }
}

// MARK: - Model State

public enum ModelState: Sendable {
    case notDownloaded
    case downloading(progress: Double)
    case downloaded
    case loading
    case loaded
    case error(String)

    public var isReady: Bool {
        if case .loaded = self { return true }
        return false
    }
}
