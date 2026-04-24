import Foundation

// MARK: - Quantization

public enum QuantizationType: String, Codable, Sendable {
    case q4 = "4bit"
    case q8 = "8bit"
    case fp16 = "fp16"

    public var displayName: String {
        switch self {
        case .q4: return "4-bit"
        case .q8: return "8-bit"
        case .fp16: return "FP16"
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
    /// "meta-llama/llama-3.1-8b-instruct". Optional — `nil` means this
    /// device-local model doesn't map to any OpenRouter-canonical id, and
    /// callers should fall back to `huggingFaceRepo` for advertisement.
    public var openrouterId: String?

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
        openrouterId: String? = nil
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
    }

    /// The id to advertise on the wire to the gateway/relay: the
    /// canonical OpenRouter slug if we resolved one, else `nil`. We
    /// deliberately do NOT fall back to `huggingFaceRepo` — for scanned
    /// local GGUFs that would leak a filesystem path, and for catalog
    /// entries the huggingFaceRepo (e.g. `mlx-community/...-4bit`) is
    /// not a canonical slug OpenRouter clients can match.
    public var advertisedId: String? {
        openrouterId
    }
}

/// Resolve a canonical OpenRouter slug from a GGUF filename. Lives in
/// SharedTypes so both ModelManager's `ModelCatalog` and LlamaCppKit's
/// `GGUFScanner` can populate `ModelDescriptor.openrouterId` without
/// ModelManager becoming a dependency of LlamaCppKit.
///
/// Keep this table in sync with `gateway/models.yaml`; an entry here is
/// a claim that a file matching `needle` actually serves the model
/// identified by the slug, and the gateway will route OpenRouter
/// demand to that slug to any node that advertises it.
public enum OpenRouterIdResolver {
    /// Substring heuristics against a normalized GGUF filename.
    /// Keys MUST use the same `-` separator convention as the normalized
    /// filename (see `normalize(_:)`), so dotted forms like `3.1` are
    /// written as `3-1`.
    private static let heuristics: [(needle: String, slug: String)] = [
        ("hermes-3-llama-3-1-8b", "nousresearch/hermes-3-llama-3.1-8b"),
        ("hermes-3-llama-3-1-70b", "nousresearch/hermes-3-llama-3.1-70b"),
        ("llama-3-3-70b-instruct", "meta-llama/llama-3.3-70b-instruct"),
        ("llama-3-1-70b-instruct", "meta-llama/llama-3.1-70b-instruct"),
        ("llama-3-1-8b-instruct", "meta-llama/llama-3.1-8b-instruct"),
        ("deepseek-v3-2", "deepseek/deepseek-v3.2"),
        ("qwen3-6-27b", "qwen/qwen3.6-27b"),
        ("qwen3-6-35b-a3b", "qwen/qwen3.6-35b-a3b"),
        ("qwen3-30b-a3b", "qwen/qwen3-30b-a3b-instruct-2507"),
        ("qwen3-32b", "qwen/qwen3-32b"),
        ("qwen3-8b", "qwen/qwen3-8b"),
        ("gpt-oss-120b", "openai/gpt-oss-120b"),
        ("gpt-oss-20b", "openai/gpt-oss-20b"),
        ("mistral-small-3-2-24b", "mistralai/mistral-small-3.2-24b-instruct"),
        ("gemma-3-27b-it", "google/gemma-3-27b-it"),
        ("glm-5-1", "zai/glm-5.1"),
        // Covers both MLX repo name ("Kimi-K2.6" → "kimi-k2-6") and GGUF
        // filenames like "Kimi-K2.6-UD-Q8_K_XL-00001-of-00014.gguf".
        ("kimi-k2-6", "moonshotai/kimi-k2.6"),
    ]

    public static func resolve(filename: String) -> String? {
        let norm = normalize(filename)
        for (needle, slug) in heuristics where norm.contains(needle) {
            return slug
        }
        return nil
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
