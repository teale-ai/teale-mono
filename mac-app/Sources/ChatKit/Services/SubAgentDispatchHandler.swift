import Foundation
import SharedTypes

// MARK: - Sub-Agent Dispatch Handler

/// Lets the orchestrator delegate a focused sub-task to a specialist persona.
/// Re-enters inference with a narrow system prompt ("You are a {role}…") and returns
/// the full text response as the tool result. Bounded by the orchestrator's iteration
/// cap in `AIParticipant`, which prevents infinite nesting even if a specialist re-calls
/// the same tool.
public final class SubAgentDispatchHandler: ToolHandler {
    public let schema = ToolSchema(
        name: "dispatch_specialist",
        description: "Delegate a focused sub-task to a specialist persona and receive its full answer.",
        parametersJSON: #"{"role":"string (e.g. code-reviewer, planner, summarizer)","task":"string (the specific question or instruction)"}"#
    )

    public typealias InferenceStream = @Sendable (ChatCompletionRequest) -> AsyncThrowingStream<String, Error>
    private let inferenceStream: InferenceStream

    public init(inferenceStream: @escaping InferenceStream) {
        self.inferenceStream = inferenceStream
    }

    public func run(params: [String: String]) async throws -> String {
        let role = params["role"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "specialist"
        let task = params["task"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        guard !task.isEmpty else {
            throw DispatchError.missingTask
        }

        let systemPrompt = "You are a \(role). Answer the task below concisely and directly. Respond with plain text only — do not emit any tool calls."
        let request = ChatCompletionRequest(
            model: nil,
            messages: [
                APIMessage(role: "system", content: systemPrompt),
                APIMessage(role: "user", content: task),
            ],
            stream: true
        )

        var result = ""
        for try await token in inferenceStream(request) {
            result += token
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    enum DispatchError: LocalizedError {
        case missingTask
        var errorDescription: String? {
            switch self {
            case .missingTask: return "dispatch_specialist requires a non-empty 'task' parameter."
            }
        }
    }
}
