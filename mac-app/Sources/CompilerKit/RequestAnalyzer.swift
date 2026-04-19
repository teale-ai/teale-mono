import Foundation
import SharedTypes

// MARK: - Request Analyzer

/// Heuristic analyzer that decides whether a request should be compiled.
/// No LLM call needed — uses structural cues to detect compound requests.
public struct RequestAnalyzer: Sendable {

    public init() {}

    /// Analyze a request and decide on compilation strategy.
    public func analyze(
        request: ChatCompletionRequest,
        availableModels: [ModelOnNetwork]
    ) -> CompilationPlan {
        // No models → passthrough to whatever fallback exists
        guard !availableModels.isEmpty else { return .passthrough }

        // Only one model available → no benefit from compilation
        let uniqueModels = Set(availableModels.map(\.model))
        guard uniqueModels.count > 1 else { return .passthrough }

        let userMessage = lastUserMessage(from: request)
        guard let message = userMessage, !message.isEmpty else { return .passthrough }

        let score = complexityScore(for: message)

        // Low complexity → passthrough
        if score < 3 { return .passthrough }

        // High complexity → needs LLM decomposition (return a signal to the caller)
        // We return passthrough here because actual decomposition requires an LLM call,
        // which the TaskDecomposer handles. The Compiler orchestrator checks the score
        // and decides whether to invoke decomposition.
        return .passthrough
    }

    /// Compute a complexity score (0-10) for a user message.
    /// Higher scores indicate the request is more likely to benefit from decomposition.
    public func complexityScore(for message: String) -> Int {
        var score = 0

        // Length signals
        let wordCount = message.split(separator: " ").count
        if wordCount > 100 { score += 2 }
        else if wordCount > 50 { score += 1 }

        // Structural cues: numbered lists, bullet points
        let lines = message.components(separatedBy: .newlines)
        let numberedLines = lines.filter { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return trimmed.range(of: #"^\d+[\.\)]\s"#, options: .regularExpression) != nil
        }
        if numberedLines.count >= 3 { score += 2 }
        else if numberedLines.count >= 2 { score += 1 }

        let bulletLines = lines.filter { $0.trimmingCharacters(in: .whitespaces).hasPrefix("- ") }
        if bulletLines.count >= 3 { score += 1 }

        // Multiple distinct task signals
        let taskKeywords: [(pattern: String, weight: Int)] = [
            ("write.*code", 1),
            ("explain", 1),
            ("summarize", 1),
            ("translate", 1),
            ("compare", 1),
            ("analyze", 1),
            ("create.*table", 1),
            ("generate", 1),
            ("review", 1),
            ("section", 1),
            ("part \\d", 1),
            ("first.*then.*finally", 2),
            ("include.*and.*also", 1),
        ]

        let lowered = message.lowercased()
        var taskTypeCount = 0
        for keyword in taskKeywords {
            if lowered.range(of: keyword.pattern, options: .regularExpression) != nil {
                taskTypeCount += keyword.weight
            }
        }
        if taskTypeCount >= 4 { score += 3 }
        else if taskTypeCount >= 2 { score += 2 }
        else if taskTypeCount >= 1 { score += 1 }

        // Section-like structure
        let sectionPatterns = ["## ", "### ", "section", "part:", "chapter"]
        let sectionHits = sectionPatterns.filter { lowered.contains($0) }
        if sectionHits.count >= 2 { score += 1 }

        return min(score, 10)
    }

    /// Whether a request is worth compiling based on complexity score.
    public func shouldCompile(request: ChatCompletionRequest, availableModelCount: Int) -> Bool {
        guard availableModelCount > 1 else { return false }
        guard let message = lastUserMessage(from: request) else { return false }
        return complexityScore(for: message) >= 3
    }

    // MARK: - Private

    private func lastUserMessage(from request: ChatCompletionRequest) -> String? {
        request.messages.last(where: { $0.role == "user" })?.content
    }
}
