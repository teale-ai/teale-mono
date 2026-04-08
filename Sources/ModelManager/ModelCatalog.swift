import Foundation
import SharedTypes

// MARK: - Model Catalog

public struct ModelCatalog: Sendable {
    public init() {}

    /// Curated list of recommended models with popularity rankings.
    /// Rankings reflect network demand — lower rank = more requested by users.
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
            popularityRank: 5
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
            popularityRank: 4
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
            popularityRank: 3
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
            popularityRank: 1
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
            popularityRank: 2
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
            popularityRank: 7
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
            popularityRank: 6
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
            popularityRank: 8
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
            popularityRank: 9
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
            popularityRank: 10
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
}
