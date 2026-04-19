import Foundation
import SharedTypes

// MARK: - Model Catalog

public struct ModelCatalog: Sendable {
    public init() {}

    /// Curated list of recommended models with popularity rankings.
    /// Rankings reflect network demand — lower rank = more requested by users.
    ///
    /// Each entry's `openrouterId` is the canonical slug advertised to the
    /// gateway. Keep these in sync with `gateway/models.yaml` in the
    /// monorepo root — the gateway's per-model fleet floor only matches
    /// against these canonical ids.
    public static let allModels: [ModelDescriptor] = [
        // Small models — run on any Apple Silicon Mac
        ModelDescriptor(
            id: "llama-3.2-1b-instruct-4bit",
            name: "Llama 3.2 1B Instruct",
            huggingFaceRepo: "mlx-community/Llama-3.2-1B-Instruct-4bit",
            parameterCount: "1B",
            quantization: .q4,
            estimatedSizeGB: 0.7,
            requiredRAMGB: 4.0,
            family: "Llama",
            description: "Fast, lightweight model for basic tasks",
            popularityRank: 5,
            openrouterId: "meta-llama/llama-3.2-1b-instruct"
        ),
        ModelDescriptor(
            id: "llama-3.2-3b-instruct-4bit",
            name: "Llama 3.2 3B Instruct",
            huggingFaceRepo: "mlx-community/Llama-3.2-3B-Instruct-4bit",
            parameterCount: "3B",
            quantization: .q4,
            estimatedSizeGB: 1.8,
            requiredRAMGB: 6.0,
            family: "Llama",
            description: "Good balance of speed and quality for small tasks",
            popularityRank: 4,
            openrouterId: "meta-llama/llama-3.2-3b-instruct"
        ),
        ModelDescriptor(
            id: "gemma-3-4b-it-qat-4bit",
            name: "Gemma 3 4B Instruct",
            huggingFaceRepo: "mlx-community/gemma-3-4b-it-qat-4bit",
            parameterCount: "4B",
            quantization: .q4,
            estimatedSizeGB: 2.5,
            requiredRAMGB: 6.0,
            family: "Gemma",
            description: "Google's efficient small model, great quality for its size",
            popularityRank: 3,
            openrouterId: "google/gemma-3-4b-it"
        ),
        // NOTE: Gemma 4 models require model_type "gemma4" which mlx-swift-lm
        // does not support yet. Re-add when upstream adds Gemma4Model.

        // Medium models — 16GB+ RAM
        ModelDescriptor(
            id: "llama-3.1-8b-instruct-4bit",
            name: "Llama 3.1 8B Instruct",
            huggingFaceRepo: "mlx-community/Meta-Llama-3.1-8B-Instruct-4bit",
            parameterCount: "8B",
            quantization: .q4,
            estimatedSizeGB: 4.5,
            requiredRAMGB: 10.0,
            family: "Llama",
            description: "Strong general-purpose model",
            popularityRank: 1,
            openrouterId: "meta-llama/llama-3.1-8b-instruct"
        ),
        ModelDescriptor(
            id: "qwen3-8b-4bit",
            name: "Qwen 3 8B",
            huggingFaceRepo: "mlx-community/Qwen3-8B-4bit",
            parameterCount: "8B",
            quantization: .q4,
            estimatedSizeGB: 4.5,
            requiredRAMGB: 10.0,
            family: "Qwen",
            description: "Latest Qwen with thinking and non-thinking modes",
            popularityRank: 2,
            openrouterId: "qwen/qwen3-8b"
        ),
        ModelDescriptor(
            id: "mistral-small-24b-instruct-2501-4bit",
            name: "Mistral Small 24B",
            huggingFaceRepo: "mlx-community/Mistral-Small-24B-Instruct-2501-4bit",
            parameterCount: "24B",
            quantization: .q4,
            estimatedSizeGB: 13.0,
            requiredRAMGB: 20.0,
            family: "Mistral",
            description: "Mistral's efficient mid-size model",
            popularityRank: 7,
            openrouterId: "mistralai/mistral-small-24b-instruct-2501"
        ),
        ModelDescriptor(
            id: "phi-4-4bit",
            name: "Phi 4",
            huggingFaceRepo: "mlx-community/phi-4-4bit",
            parameterCount: "14B",
            quantization: .q4,
            estimatedSizeGB: 8.0,
            requiredRAMGB: 14.0,
            family: "Phi",
            description: "Microsoft's strong reasoning model",
            popularityRank: 6,
            openrouterId: "microsoft/phi-4"
        ),

        // Large models — 32GB+ RAM
        ModelDescriptor(
            id: "gemma-3-27b-it-4bit",
            name: "Gemma 3 27B Instruct",
            huggingFaceRepo: "mlx-community/gemma-3-27b-it-qat-4bit",
            parameterCount: "27B",
            quantization: .q4,
            estimatedSizeGB: 15.0,
            requiredRAMGB: 24.0,
            family: "Gemma",
            description: "Google's flagship Gemma 3 model, strong reasoning and coding",
            popularityRank: 8,
            openrouterId: "google/gemma-3-27b-it"
        ),
        ModelDescriptor(
            id: "qwen3-32b-4bit",
            name: "Qwen 3 32B",
            huggingFaceRepo: "mlx-community/Qwen3-32B-4bit",
            parameterCount: "32B",
            quantization: .q4,
            estimatedSizeGB: 18.0,
            requiredRAMGB: 28.0,
            family: "Qwen",
            description: "High-quality model for complex tasks",
            popularityRank: 9,
            openrouterId: "qwen/qwen3-32b"
        ),

        // XL models — 64GB+ RAM
        ModelDescriptor(
            id: "llama-4-scout-17b-16e-instruct-4bit",
            name: "Llama 4 Scout 109B (MoE)",
            huggingFaceRepo: "mlx-community/Llama-4-Scout-17Bx16E-Instruct-4bit",
            parameterCount: "109B",
            quantization: .q4,
            estimatedSizeGB: 56.0,
            requiredRAMGB: 72.0,
            family: "Llama",
            description: "Meta's MoE model — 17B active params, frontier quality",
            popularityRank: 10,
            openrouterId: "meta-llama/llama-4-scout"
        ),
    ]

    /// Filter models that can run on the given hardware
    public func availableModels(for hardware: HardwareCapability) -> [ModelDescriptor] {
        ModelCatalog.allModels.filter { model in
            hardware.availableRAMForModelsGB >= model.requiredRAMGB
        }
    }

    /// Top models by popularity that can run on this hardware
    public func topModels(for hardware: HardwareCapability, limit: Int = 3) -> [ModelDescriptor] {
        Array(availableModels(for: hardware).sorted { $0.popularityRank < $1.popularityRank }.prefix(limit))
    }

    /// Resolve an OpenRouter-canonical id from a local filename. Used by
    /// `LocalModelScanner` when it finds a GGUF on disk and needs to know
    /// which OR slug to advertise. Matches are fuzzy — case-insensitive
    /// substring check against known canonical slugs.
    public static func openrouterIdForFilename(_ filename: String) -> String? {
        // Strip extension, normalize separators.
        let norm = filename
            .lowercased()
            .replacingOccurrences(of: ".gguf", with: "")
            .replacingOccurrences(of: "_", with: "-")
            .replacingOccurrences(of: ".", with: "-")

        // Look up against catalog — match by each entry's tail (post-slash).
        for model in allModels {
            guard let or = model.openrouterId else { continue }
            let tail = or.split(separator: "/").last.map(String.init) ?? or
            if norm.contains(tail.lowercased()) {
                return or
            }
        }

        // Extended heuristics for popular non-catalog variants we still
        // want to route to catalog models. Keep narrow — adding entries
        // here lies to the gateway about what we can serve.
        let heuristics: [(String, String)] = [
            ("hermes-3-llama-3.1-8b", "nousresearch/hermes-3-llama-3.1-8b"),
            ("hermes-3-llama-3.1-70b", "nousresearch/hermes-3-llama-3.1-70b"),
            ("llama-3.3-70b-instruct", "meta-llama/llama-3.3-70b-instruct"),
            ("llama-3.1-70b-instruct", "meta-llama/llama-3.1-70b-instruct"),
            ("qwen3-30b-a3b", "qwen/qwen3-30b-a3b-instruct-2507"),
            ("gpt-oss-120b", "openai/gpt-oss-120b"),
            ("gpt-oss-20b", "openai/gpt-oss-20b"),
        ]
        for (needle, or) in heuristics {
            if norm.contains(needle) {
                return or
            }
        }
        return nil
    }
}
