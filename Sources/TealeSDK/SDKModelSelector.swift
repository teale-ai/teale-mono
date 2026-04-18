import Foundation
import SharedTypes
import HardwareProfile

// MARK: - SDK Model Selector

/// Selects the best model for a device to serve based on hardware capability and SDK constraints.
struct SDKModelSelector {

    /// Curated models suitable for SDK contribution (small, efficient, Q4 quantized)
    static let sdkModels: [ModelDescriptor] = [
        ModelDescriptor(
            id: "llama-3.2-1b-instruct-4bit",
            name: "Llama 3.2 1B Instruct",
            huggingFaceRepo: "mlx-community/Llama-3.2-1B-Instruct-4bit",
            parameterCount: "1B",
            quantization: .q4,
            estimatedSizeGB: 0.7,
            requiredRAMGB: 4.0,
            family: "Llama",
            description: "Fast, lightweight model for basic tasks"
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
            description: "Good balance of speed and quality"
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
            description: "Google's efficient small model"
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
            description: "Strong general-purpose model"
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
            description: "Latest Qwen with thinking and non-thinking modes"
        ),
    ]

    /// Select the best model for the given hardware and SDK constraints.
    /// Picks the largest model that fits within the RAM budget and allowed families.
    static func selectModel(
        hardware: HardwareCapability,
        maxRAMGB: Double,
        allowedFamilies: [String]?
    ) -> ModelDescriptor? {
        let candidates = sdkModels
            .filter { $0.requiredRAMGB <= maxRAMGB }
            .filter { model in
                guard let families = allowedFamilies else { return true }
                return families.contains(model.family)
            }
            .sorted { $0.requiredRAMGB > $1.requiredRAMGB }  // Prefer larger (more capable) models

        return candidates.first
    }
}
