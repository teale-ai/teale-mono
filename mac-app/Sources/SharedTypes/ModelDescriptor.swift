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

    /// The id to advertise on the wire to the gateway/relay. Prefers
    /// `openrouterId` when set (canonical slug), falls back to the
    /// HuggingFace repo id, which in turn may be a local filesystem
    /// path for devices running scanned GGUFs.
    public var advertisedId: String {
        openrouterId ?? huggingFaceRepo
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
