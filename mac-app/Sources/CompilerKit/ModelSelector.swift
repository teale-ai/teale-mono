import Foundation

// MARK: - Model Selector

/// Selects the best available model for a given sub-task based on
/// task-type affinity, model size, and current device load.
/// The user never picks a model — the compiler optimizes for outcome quality.
public struct ModelSelector: Sendable {

    /// Default task-type affinity scores for known model families.
    /// These are empirical estimates; refine with benchmarking over time.
    public static let defaultAffinities: [ModelAffinity] = [
        ModelAffinity(family: "Qwen", scores: [
            .code: 0.90, .reasoning: 0.85, .creative: 0.70,
            .factual: 0.75, .summarization: 0.75, .translation: 0.80,
            .structured: 0.90, .general: 0.80,
        ]),
        ModelAffinity(family: "Llama", scores: [
            .code: 0.80, .reasoning: 0.80, .creative: 0.85,
            .factual: 0.80, .summarization: 0.80, .translation: 0.75,
            .structured: 0.75, .general: 0.85,
        ]),
        ModelAffinity(family: "Gemma", scores: [
            .code: 0.75, .reasoning: 0.80, .creative: 0.70,
            .factual: 0.85, .summarization: 0.85, .translation: 0.80,
            .structured: 0.75, .general: 0.75,
        ]),
        ModelAffinity(family: "Phi", scores: [
            .code: 0.85, .reasoning: 0.75, .creative: 0.50,
            .factual: 0.80, .summarization: 0.70, .translation: 0.60,
            .structured: 0.85, .general: 0.65,
        ]),
        ModelAffinity(family: "Mistral", scores: [
            .code: 0.80, .reasoning: 0.85, .creative: 0.75,
            .factual: 0.75, .summarization: 0.80, .translation: 0.75,
            .structured: 0.80, .general: 0.80,
        ]),
    ]

    private let affinities: [ModelAffinity]

    public init(affinities: [ModelAffinity] = ModelSelector.defaultAffinities) {
        self.affinities = affinities
    }

    /// Select the best model for a sub-task from available models on the network.
    public func select(
        for subTask: SubTask,
        from available: [ModelOnNetwork]
    ) -> ModelOnNetwork? {
        guard !available.isEmpty else { return nil }

        let scored = available.map { model -> (model: ModelOnNetwork, score: Double) in
            let score = self.score(model: model, for: subTask)
            return (model, score)
        }

        return scored.max(by: { $0.score < $1.score })?.model
    }

    /// Select the best model for each sub-task, avoiding overloading any single device.
    public func assign(
        subTasks: [SubTask],
        available: [ModelOnNetwork]
    ) -> [UUID: ModelOnNetwork] {
        var assignments: [UUID: ModelOnNetwork] = [:]
        var loadTracker: [String: Int] = [:]  // model ID → assigned count

        // Sort sub-tasks by complexity (estimated tokens, descending) so the
        // hardest tasks get the best model assignments first.
        let sorted = subTasks.sorted { $0.estimatedTokens > $1.estimatedTokens }

        for subTask in sorted {
            // Adjust available models' effective load with our pending assignments
            let adjusted = available.map { model -> ModelOnNetwork in
                let extraLoad = loadTracker[model.id] ?? 0
                return ModelOnNetwork(
                    model: model.model,
                    modelFamily: model.modelFamily,
                    parameterBillions: model.parameterBillions,
                    deviceID: model.deviceID,
                    currentLoad: model.currentLoad + extraLoad,
                    estimatedToksPerSec: model.estimatedToksPerSec
                )
            }

            if let best = select(for: subTask, from: adjusted) {
                // Find the original (non-adjusted) model to store
                let original = available.first { $0.id == best.id } ?? best
                assignments[subTask.id] = original
                loadTracker[original.id, default: 0] += 1
            }
        }

        return assignments
    }

    // MARK: - Scoring

    /// Score a model for a specific sub-task. Higher is better.
    func score(model: ModelOnNetwork, for subTask: SubTask) -> Double {
        let affinity = affinityScore(family: model.modelFamily, category: subTask.category)
        let sizeScore = sizeScore(paramBillions: model.parameterBillions, subTask: subTask)
        let loadPenalty = loadPenalty(currentLoad: model.currentLoad)
        let speedBonus = min(model.estimatedToksPerSec / 100.0, 1.0)

        // Weighted combination:
        // - Affinity is most important (how good is this model at this task type?)
        // - Size matters for complex tasks, less for simple ones
        // - Load penalty prevents overloading one device
        // - Speed is a tiebreaker
        return (affinity * 0.45) + (sizeScore * 0.25) + (loadPenalty * 0.20) + (speedBonus * 0.10)
    }

    private func affinityScore(family: String, category: TaskCategory) -> Double {
        // Case-insensitive match against known families
        let lowered = family.lowercased()
        for aff in affinities {
            if lowered.contains(aff.family.lowercased()) {
                return aff.score(for: category)
            }
        }
        // Unknown model family — assume average
        return 0.6
    }

    private func sizeScore(paramBillions: Double, subTask: SubTask) -> Double {
        // For complex tasks (code, reasoning), bigger models score higher.
        // For simple tasks (factual, summarization), smaller models are fine.
        let complexityMultiplier: Double
        switch subTask.category {
        case .code, .reasoning:
            complexityMultiplier = 1.0  // Reward size
        case .creative, .structured:
            complexityMultiplier = 0.7
        case .general, .translation:
            complexityMultiplier = 0.5
        case .factual, .summarization:
            complexityMultiplier = 0.3  // Size doesn't matter much
        }

        // Normalize: 1B=0.1, 8B=0.5, 32B=0.8, 70B=0.95, 235B=1.0
        let normalized = min(log2(max(paramBillions, 1.0)) / log2(235.0), 1.0)
        return normalized * complexityMultiplier
    }

    private func loadPenalty(currentLoad: Int) -> Double {
        // 0 load = 1.0, 1 load = 0.7, 2 = 0.5, 3+ = 0.3
        switch currentLoad {
        case 0: return 1.0
        case 1: return 0.7
        case 2: return 0.5
        default: return 0.3
        }
    }
}
