import Foundation
import SharedTypes

// MARK: - Task Decomposer

/// Uses a fast LLM call to decompose a complex request into sub-tasks.
/// The decomposer itself runs on a small model (1-3B) — it only needs to
/// understand *what kind of work* each part requires, not perform the work.
public actor TaskDecomposer {

    private let provider: any InferenceProvider

    public init(provider: any InferenceProvider) {
        self.provider = provider
    }

    /// Decompose a request into sub-tasks.
    /// Returns nil if the request can't be meaningfully decomposed.
    public func decompose(
        request: ChatCompletionRequest,
        context: [APIMessage] = []
    ) async throws -> (subTasks: [SubTask], synthesisPrompt: String)? {
        let userMessage = request.messages.last(where: { $0.role == "user" })?.content ?? ""

        let systemPrompt = """
        You are a request compiler. Your job is to decompose a complex user request into \
        independent sub-tasks that can be executed in parallel by different specialized models.

        Analyze the request and output ONLY a JSON object with this structure:
        {
          "subtasks": [
            {
              "prompt": "The full prompt for this sub-task, including all necessary context",
              "category": "code|reasoning|creative|factual|summarization|translation|structured|general",
              "order_index": 0,
              "depends_on": [],
              "estimated_tokens": 500
            }
          ],
          "synthesis_prompt": "Instructions for combining the sub-task outputs into a coherent response"
        }

        Rules:
        - Only decompose if there are genuinely independent parts (2-6 sub-tasks)
        - Each sub-task prompt must be self-contained — the executing model won't see other sub-tasks
        - Set depends_on to the order_index values of sub-tasks that must complete first
        - If the request is simple and shouldn't be decomposed, return: {"subtasks": [], "synthesis_prompt": ""}
        - Category must exactly match one of: code, reasoning, creative, factual, summarization, translation, structured, general
        - Keep prompts concise but complete — include relevant context from the original request
        """

        let decompositionRequest = ChatCompletionRequest(
            messages: [
                APIMessage(role: "system", content: systemPrompt),
                APIMessage(role: "user", content: userMessage),
            ],
            maxTokens: 2000
        )

        let response = try await provider.generateFull(request: decompositionRequest)
        guard let content = response.choices.first?.message.content else {
            return nil
        }

        return try parseDecomposition(content)
    }

    // MARK: - Parsing

    private func parseDecomposition(_ content: String) throws -> (subTasks: [SubTask], synthesisPrompt: String)? {
        // Extract JSON from response (handle markdown code blocks)
        let jsonString = extractJSON(from: content)
        guard let data = jsonString.data(using: .utf8) else { return nil }

        let decoded = try JSONDecoder().decode(DecompositionResponse.self, from: data)

        // If no sub-tasks, signal that decomposition isn't needed
        guard !decoded.subtasks.isEmpty else { return nil }

        // Build UUID mapping for dependency resolution
        var indexToID: [Int: UUID] = [:]
        var subTasks: [SubTask] = []

        // First pass: create IDs
        for st in decoded.subtasks {
            indexToID[st.orderIndex] = UUID()
        }

        // Second pass: resolve dependencies
        for st in decoded.subtasks {
            let id = indexToID[st.orderIndex]!
            let depIDs = st.dependsOn.compactMap { indexToID[$0] }
            let category = TaskCategory(rawValue: st.category) ?? .general

            subTasks.append(SubTask(
                id: id,
                prompt: st.prompt,
                category: category,
                orderIndex: st.orderIndex,
                dependsOn: depIDs,
                estimatedTokens: st.estimatedTokens
            ))
        }

        return (subTasks: subTasks.sorted { $0.orderIndex < $1.orderIndex },
                synthesisPrompt: decoded.synthesisPrompt)
    }

    private func extractJSON(from text: String) -> String {
        // Try to find JSON in code blocks first
        if let range = text.range(of: "```json\n"),
           let endRange = text.range(of: "\n```", range: range.upperBound..<text.endIndex) {
            return String(text[range.upperBound..<endRange.lowerBound])
        }
        if let range = text.range(of: "```\n"),
           let endRange = text.range(of: "\n```", range: range.upperBound..<text.endIndex) {
            return String(text[range.upperBound..<endRange.lowerBound])
        }
        // Try to find raw JSON object
        if let start = text.firstIndex(of: "{"),
           let end = text.lastIndex(of: "}") {
            return String(text[start...end])
        }
        return text
    }
}

// MARK: - Decodable Response

private struct DecompositionResponse: Decodable {
    let subtasks: [DecomposedSubTask]
    let synthesisPrompt: String

    enum CodingKeys: String, CodingKey {
        case subtasks
        case synthesisPrompt = "synthesis_prompt"
    }
}

private struct DecomposedSubTask: Decodable {
    let prompt: String
    let category: String
    let orderIndex: Int
    let dependsOn: [Int]
    let estimatedTokens: Int

    enum CodingKeys: String, CodingKey {
        case prompt, category
        case orderIndex = "order_index"
        case dependsOn = "depends_on"
        case estimatedTokens = "estimated_tokens"
    }
}
