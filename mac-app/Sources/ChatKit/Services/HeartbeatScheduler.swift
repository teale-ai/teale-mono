import Foundation
import SharedTypes

// MARK: - Heartbeat Scheduler

/// Runs a periodic "should I nudge the group?" pass for each conversation
/// where proactive check-ins are enabled. If the AI decides there's something
/// worth raising (upcoming birthday, stale plan, unanswered question, a
/// running thread worth summarizing), it posts an AI message unprompted.
///
/// Only one device per group should run this concurrently — in a proper
/// multi-device group we'd want to elect a single heartbeat node. For now we
/// just let every device run it independently; duplicate nudges are possible
/// but rare because the prompt is conservative and the cadence is slow.
@MainActor
public final class HeartbeatScheduler {
    private weak var chatService: ChatService?
    /// Seconds between scheduler passes. Intentionally slow so the AI only
    /// posts when something genuinely changed (we can tighten later).
    public var interval: TimeInterval = 30 * 60

    private var task: Task<Void, Never>?
    private var lastNudgeAt: [UUID: Date] = [:]
    /// Minimum spacing between nudges for the same conversation, to avoid
    /// the AI talking to itself when no humans are around.
    public var minSpacing: TimeInterval = 4 * 60 * 60

    public init(chatService: ChatService) {
        self.chatService = chatService
    }

    public func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(self?.interval ?? 1800))
                await self?.runPass()
            }
        }
    }

    public func stop() {
        task?.cancel()
        task = nil
    }

    // MARK: - One scheduler pass

    private func runPass() async {
        guard let chatService else { return }

        for conversation in chatService.conversations where conversation.heartbeatsEnabled {
            await evaluate(conversation: conversation, chatService: chatService)
        }
    }

    private func evaluate(conversation: Conversation, chatService: ChatService) async {
        if let last = lastNudgeAt[conversation.id],
           Date().timeIntervalSince(last) < minSpacing {
            return
        }

        // Open the conversation so activeMessages / memory are loaded.
        await chatService.openConversation(conversation)

        // Ask the AI directly: should you post something right now? If yes,
        // what? We do this as a single shot rather than the full orchestrator
        // loop so it's cheap and bounded.
        guard let inferenceStream = chatService.aiParticipant.onInferenceRequest else { return }

        let context = buildHeartbeatContext(conversation: conversation, chatService: chatService)
        let request = ChatCompletionRequest(
            model: conversation.agentConfig.model,
            messages: [
                APIMessage(role: "system", content: Self.heartbeatSystemPrompt),
                APIMessage(role: "user", content: context),
            ],
            stream: true
        )

        var response = ""
        do {
            for try await token in inferenceStream(request) {
                response += token
            }
        } catch {
            return
        }

        let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed.lowercased() != "nothing",
              !trimmed.lowercased().hasPrefix("nothing ")
        else {
            return
        }

        await chatService.insertAIMessage(trimmed, conversationID: conversation.id)
        lastNudgeAt[conversation.id] = Date()
    }

    // MARK: - Prompt construction

    private static let heartbeatSystemPrompt = """
    You are Teale, a group-chat AI running a scheduled check-in for a conversation.
    Decide whether to post a short proactive message right now. Only post when:
    - A date or plan from group memory is imminent or stale ("trip is in 2 weeks and nobody's booked", "Mom's birthday tomorrow")
    - There's an unanswered question from a prior message
    - A running decision has been stuck and a nudge would help
    Do NOT post if nothing is actionable — reply with the literal word "nothing".
    When you DO post, write it as a single, warm, helpful sentence addressed to the group. No greetings, no self-introduction.
    """

    private func buildHeartbeatContext(conversation: Conversation, chatService: ChatService) -> String {
        var lines: [String] = []
        lines.append("Group: \(conversation.title ?? "unnamed") (\(conversation.type.rawValue))")
        lines.append("Now: \(ISO8601DateFormatter().string(from: Date()))")
        if let last = conversation.lastMessageAt {
            let hours = Int(Date().timeIntervalSince(last) / 3600)
            lines.append("Last message: \(hours)h ago")
        }

        let memory = chatService.memoryStore.entries(for: conversation.id).suffix(20)
        if !memory.isEmpty {
            lines.append("Group memory:")
            lines.append(contentsOf: memory.map { "- \($0.text)" })
        }

        let recent = chatService.activeMessages.suffix(10)
        if !recent.isEmpty {
            lines.append("Recent messages:")
            lines.append(contentsOf: recent.map { msg in
                let sender = msg.isFromAgent ? "Teale" : "User"
                return "[\(sender)] \(msg.content)"
            })
        }

        return lines.joined(separator: "\n")
    }
}
