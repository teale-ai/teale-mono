import Foundation
import SharedTypes

// MARK: - Model Catalog

public struct ModelCatalog: Sendable {
    public init() {}

    /// Curated list of recommended models with unique popularity rankings.
    /// Rankings reflect network demand — lower rank = more requested by users.
    ///
    /// `openrouterId` is the canonical slug advertised to the gateway and is
    /// set only for models the gateway catalog (`gateway/models.yaml`) knows;
    /// it must equal `OpenRouterIdResolver.resolve(identifier: huggingFaceRepo)`
    /// (both enforced by `ModelManagerTests`). Entries with `openrouterId: nil`
    /// are local-only: they can be downloaded and used on this Mac but are
    /// never advertised to the network.
    ///
    /// `format` / `servingBackend` say which pipeline downloads the weights
    /// and which provider serves them. GGUF entries list the exact files to
    /// fetch in `ggufFiles`.
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
            popularityRank: 7,
            openrouterId: nil  // not in the gateway catalog: local-only
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
            popularityRank: 5,
            openrouterId: nil  // not in the gateway catalog: local-only
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
            openrouterId: nil  // not in the gateway catalog: local-only
        ),
        // NOTE: Gemma 4 models require model_type "gemma4" which mlx-swift-lm
        // does not support yet. Re-add when upstream adds Gemma4Model.

        // Medium models — 16GB+ RAM
        ModelDescriptor(
            id: "qwen3.5-9b-4bit",
            name: "Qwen 3.5 9B",
            huggingFaceRepo: "mlx-community/Qwen3.5-9B-MLX-4bit",
            parameterCount: "9B",
            quantization: .q4,
            estimatedSizeGB: 5.2,
            requiredRAMGB: 11.0,
            family: "Qwen",
            description: "Recommended starter for 16GB Macs — Qwen3.5 hybrid (Gated Delta + sparse MoE), 201 languages",
            popularityRank: 1,
            openrouterId: "qwen/qwen3.5-9b"
        ),
        // The gateway lists this slug with quantization Q5_K_M (GGUF supply);
        // Mac supply serves the same model as 4-bit MLX. Both advertise the
        // one canonical slug.
        ModelDescriptor(
            id: "hermes-3-llama-3.1-8b-4bit",
            name: "Hermes 3 8B",
            huggingFaceRepo: "mlx-community/Hermes-3-Llama-3.1-8B-4bit",
            parameterCount: "8B",
            quantization: .q4,
            estimatedSizeGB: 4.6,
            requiredRAMGB: 10.0,
            family: "Llama",
            description: "OpenClaw-compatible Hermes; fallback for hosts that can't fit Qwen3.5-9B",
            popularityRank: 2,
            openrouterId: "nousresearch/hermes-3-llama-3.1-8b"
        ),
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
            popularityRank: 4,
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
            description: "Predecessor to Qwen3.5; kept for hosts already running it",
            popularityRank: 6,
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
            popularityRank: 10,
            // The gateway lists mistral-small-3.2 only; 2501 weights are a
            // different release, so this stays local-only.
            openrouterId: nil
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
            popularityRank: 9,
            openrouterId: nil  // not in the gateway catalog: local-only
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
            popularityRank: 11,
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
            popularityRank: 12,
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
            popularityRank: 13,
            openrouterId: nil  // not in the gateway catalog: local-only
        ),
        ModelDescriptor(
            id: "qwen3.6-27b-8bit",
            name: "Qwen 3.6 27B (Dense, Coding)",
            huggingFaceRepo: "unsloth/Qwen3.6-27B-MLX-8bit",
            parameterCount: "27B",
            quantization: .q8,
            estimatedSizeGB: 34.7,
            requiredRAMGB: 42.0,
            family: "Qwen",
            description: "Qwen 3.6 27B dense — flagship-level coding & agentic perf, 256K ctx. 8-bit MLX.",
            popularityRank: 8,
            openrouterId: "qwen/qwen3.6-27b"
        ),
        ModelDescriptor(
            id: "qwen3.6-35b-a3b-bf16",
            name: "Qwen 3.6 35B A3B (MoE, VLM)",
            huggingFaceRepo: "mlx-community/Qwen3.6-35B-A3B-bf16",
            parameterCount: "35B",
            quantization: .fp16,
            estimatedSizeGB: 70.0,
            requiredRAMGB: 90.0,
            family: "Qwen",
            description: "Qwen 3.6 35B/3B-active MoE with vision, bf16. 128GB+ unified RAM.",
            popularityRank: 14,
            openrouterId: "qwen/qwen3.6-35b-a3b"
        ),

        // XXL models — multi-node exo cluster required
        ModelDescriptor(
            id: "deepseek-v3.2-8bit",
            name: "DeepSeek V3.2 (MoE)",
            huggingFaceRepo: "mlx-community/DeepSeek-V3.2-8bit",
            parameterCount: "671B",
            quantization: .q8,
            estimatedSizeGB: 704.0,
            requiredRAMGB: 768.0,
            family: "DeepSeek",
            description: "DeepSeek V3.2 MoE (671B total, ~37B active) at 8-bit. Requires multi-Ultra exo cluster.",
            popularityRank: 15,
            openrouterId: "deepseek/deepseek-v3.2",
            format: .mlx,
            servingBackend: .exo
        ),
        // GLM-5.1 — Unsloth Dynamic Q4_K_XL, split into 11 GGUF shards;
        // llama-server is started with the first shard.
        ModelDescriptor(
            id: "glm-5.1-ud-q4-k-xl",
            name: "GLM-5.1 (MoE)",
            huggingFaceRepo: "unsloth/GLM-5.1-GGUF",
            parameterCount: "754B",
            quantization: .q4,
            estimatedSizeGB: 434.0,
            requiredRAMGB: 480.0,
            family: "GLM",
            description: "Z.ai GLM-5.1 — 754B MoE at Unsloth Dynamic Q4_K_XL (GGUF, llama.cpp). Single-Mac only on a 512 GB Studio with a raised GPU wired limit.",
            popularityRank: 16,
            openrouterId: "zai/glm-5.1",
            format: .gguf,
            servingBackend: .llamaCpp,
            ggufFiles: ["UD-Q4_K_XL/GLM-5.1-UD-Q4_K_XL-*.gguf"]
        ),
        // Kimi K2.6 — 1T MoE, natively int4 safetensors (unsloth/Kimi-K2.6
        // is the original compressed-tensors upload, not a GGUF). 554 GB, so
        // it is served by exo sharding across 2× 512 GB Ultras; Teale never
        // downloads or loads it itself.
        ModelDescriptor(
            id: "kimi-k2.6",
            name: "Kimi K2.6 (1T MoE)",
            huggingFaceRepo: "unsloth/Kimi-K2.6",
            parameterCount: "1T",
            quantization: .q4,
            estimatedSizeGB: 554.0,
            requiredRAMGB: 640.0,
            family: "Kimi",
            description: "Moonshot Kimi K2.6 — 1T MoE (32B active), native int4, multimodal (MoonViT), 256K context. Requires 2× 512 GB Ultra exo cluster over TB5.",
            popularityRank: 19,
            openrouterId: "moonshotai/kimi-k2.6",
            format: .mlx,
            servingBackend: .exo
        ),
        // DeepSeek V4 Flash — 284B-A13B MoE, served via ds4-server GGUF on
        // a single 512 GB Mac Studio Ultra. Frontier-class with 1M context.
        ModelDescriptor(
            id: "deepseek-v4-flash",
            name: "DeepSeek V4 Flash (DS4 Q4)",
            huggingFaceRepo: "antirez/deepseek-v4-gguf",
            parameterCount: "284B",
            quantization: .q4,
            estimatedSizeGB: 180.0,
            requiredRAMGB: 256.0,
            family: "DeepSeek",
            description: "DeepSeek V4 Flash — DS4 Q4 GGUF, 13B active, 1M context. Candidate for one 512 GB Mac Studio Ultra.",
            popularityRank: 17,
            openrouterId: "deepseek-ai/deepseek-v4-flash",
            format: .gguf,
            servingBackend: .ds4,
            ggufFiles: ["DeepSeek-V4-Flash-Q4KExperts-F16HC-F16Compressor-F16Indexer-Q8Attn-Q8Shared-Q8Out-chat-v2.gguf"]
        ),
        // DeepSeek V4 Pro — quality-max DS4 candidate for the second 512 GB
        // machine. Same HF repo as Flash, different file; the GGUF cache is
        // keyed by model id so the two never share a directory. Not in the
        // gateway catalog yet, so local-only.
        ModelDescriptor(
            id: "deepseek-v4-pro",
            name: "DeepSeek V4 Pro (DS4 Q2)",
            huggingFaceRepo: "antirez/deepseek-v4-gguf",
            parameterCount: "1.6T",
            quantization: .q2,
            estimatedSizeGB: 430.0,
            requiredRAMGB: 500.0,
            family: "DeepSeek",
            description: "DeepSeek V4 Pro — DS4 Q2 imatrix GGUF, 1M context. Candidate for one 512 GB Mac Studio Ultra quality lane.",
            popularityRank: 18,
            openrouterId: nil,
            format: .gguf,
            servingBackend: .ds4,
            ggufFiles: ["DeepSeek-V4-Pro-IQ2XXS-w2Q2K-AProjQ8-SExpQ8-OutQ8-Instruct-imatrix.gguf"]
        ),
    ]

    /// Models that fit this hardware under the single `ModelFit` rule.
    public func availableModels(for hardware: HardwareCapability) -> [ModelDescriptor] {
        ModelCatalog.allModels.filter { model in
            ModelFit.fits(model, totalRAMGB: hardware.totalRAMGB)
        }
    }

    /// Top models by popularity that can run on this hardware
    public func topModels(for hardware: HardwareCapability, limit: Int = 3) -> [ModelDescriptor] {
        Array(availableModels(for: hardware).sorted { $0.popularityRank < $1.popularityRank }.prefix(limit))
    }

    /// Resolve an OpenRouter-canonical id from a local filename or repo id.
    /// Thin wrapper over `OpenRouterIdResolver`, the one slug table; kept
    /// for existing callers.
    public static func openrouterIdForFilename(_ filename: String) -> String? {
        OpenRouterIdResolver.resolve(filename: filename)
    }
}
