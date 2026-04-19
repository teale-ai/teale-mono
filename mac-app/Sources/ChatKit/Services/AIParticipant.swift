import Foundation
import SharedTypes

// MARK: - AI Participant (Orchestrator)

/// Manages AI agent behavior in conversations.
/// Decides when to respond, runs the orchestrator tool loop, persists tool-call / tool-result / ai-response messages.
@MainActor
@Observable
public final class AIParticipant {
    /// Whether the AI is currently generating a response.
    public private(set) var isGenerating: Bool = false
    /// Streaming text from the current inference pass.
    public private(set) var streamingText: String = ""

    /// Inference routing callback set by the app layer.
    public var onInferenceRequest: ((ChatCompletionRequest) -> AsyncThrowingStream<String, Error>)?

    /// Optional tool registry for orchestrator tool calls.
    public var toolRegistry: ToolRegistry?

    /// Optional group memory store — when present, recent memory entries for
    /// the active conversation are injected into the system prompt so the AI
    /// starts every turn already knowing the group's context.
    public var memoryStore: GroupMemoryStore?

    /// Optional per-device preference store — the local user's preferences are
    /// injected into the system prompt as "the typing user's personal context".
    public var preferenceStore: UserPreferenceStore?

    /// Maximum number of tool-call iterations before the orchestrator gives up.
    public var maxIterations: Int = 4

    public init() {}

    // MARK: - Should Respond

    public func shouldRespond(
        to message: DecryptedMessage,
        config: AgentConfig,
        currentUserID: UUID
    ) -> Bool {
        guard !message.isFromAgent else { return false }
        guard message.messageType == .text else { return false }

        let lower = message.content.lowercased()
        let isMentioned = lower.contains("@teale") || lower.contains("@agent")

        if config.mentionOnly || !config.autoRespond {
            return isMentioned
        }
        return true
    }

    // MARK: - Orchestrator Turn

    /// Execute one orchestrator turn: iterate inference + tool calls, persisting each
    /// `.toolCall` / `.toolResult` / `.aiResponse` through `chatService`.
    public func runTurn(
        conversation: Conversation,
        chatService: ChatService,
        participants: [ParticipantInfo]
    ) async {
        guard let onInferenceRequest else { return }

        isGenerating = true
        defer {
            isGenerating = false
            streamingText = ""
        }

        for _ in 0..<maxIterations {
            streamingText = ""

            let request = buildRequest(
                conversation: conversation,
                messages: chatService.activeMessages,
                participants: participants,
                toolSchemas: toolRegistry?.schemas() ?? []
            )

            var fullResponse = ""
            do {
                for try await token in onInferenceRequest(request) {
                    fullResponse += token
                    streamingText = fullResponse
                }
            } catch {
                if fullResponse.isEmpty {
                    await chatService.insertAIMessage("[Inference error: \(error.localizedDescription)]", conversationID: conversation.id)
                    return
                }
            }

            // Parse a tool call out of the response, if any.
            if let (call, textBefore) = ToolCallParser.extract(from: fullResponse),
               let registry = toolRegistry, !registry.isEmpty {

                let prefix = textBefore.trimmingCharacters(in: .whitespacesAndNewlines)
                if !prefix.isEmpty {
                    await chatService.insertAIMessage(prefix, conversationID: conversation.id)
                }

                await chatService.insertToolCall(call, conversationID: conversation.id)
                let outcome = await registry.execute(call)
                await chatService.insertToolResult(outcome, conversationID: conversation.id)

                // Continue the loop — next iteration sees tool result in context.
                continue
            }

            // No tool call — treat as the final response.
            let trimmed = fullResponse.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                await chatService.insertAIMessage(trimmed, conversationID: conversation.id)
            }
            return
        }

        await chatService.insertAIMessage(
            "(orchestrator hit the maximum of \(maxIterations) tool iterations)",
            conversationID: conversation.id
        )
    }

    // MARK: - Legacy API (kept for iOS group chat path that calls generateResponse directly)

    /// Single-pass generation — returns the full response, no tool loop.
    /// Prefer `runTurn` for the orchestrator path.
    public func generateResponse(
        conversation: Conversation,
        messages: [DecryptedMessage],
        participants: [ParticipantInfo],
        tools: [ConversationToolSummary]
    ) async -> String? {
        guard let onInferenceRequest else { return nil }

        isGenerating = true
        streamingText = ""
        defer {
            isGenerating = false
            streamingText = ""
        }

        let request = buildRequest(
            conversation: conversation,
            messages: messages,
            participants: participants,
            toolSchemas: toolRegistry?.schemas() ?? []
        )

        var fullResponse = ""
        do {
            for try await token in onInferenceRequest(request) {
                fullResponse += token
                streamingText = fullResponse
            }
        } catch {
            if fullResponse.isEmpty { return nil }
        }
        return fullResponse.isEmpty ? nil : fullResponse
    }

    // MARK: - Context Building

    private func buildRequest(
        conversation: Conversation,
        messages: [DecryptedMessage],
        participants: [ParticipantInfo],
        toolSchemas: [ToolSchema]
    ) -> ChatCompletionRequest {
        let systemPrompt = buildSystemPrompt(
            conversation: conversation,
            participants: participants,
            toolSchemas: toolSchemas
        )

        var apiMessages = [APIMessage(role: "system", content: systemPrompt)]

        // Convert recent messages to API format (budget: last 50 messages).
        let recentMessages = messages.suffix(50)
        for msg in recentMessages {
            let role: String
            var content = msg.content

            switch msg.messageType {
            case .text:
                role = "user"
                if conversation.type == .group, let senderID = msg.senderID {
                    let senderName = participants.first { $0.participant.userID == senderID }?.displayName ?? "User"
                    content = "[\(senderName)] \(content)"
                }
            case .aiResponse:
                role = "assistant"
            case .toolCall:
                // Feed the model's own prior tool-call output back as assistant text
                // so it can continue the conversation with the tool result in view.
                role = "assistant"
                content = "<tool_call>\(content)</tool_call>"
            case .toolResult:
                // Tool results come back as user-role observations — a common convention
                // that keeps the "assistant acts, user observes" alternation clean.
                role = "user"
                content = "<tool_result>\(content)</tool_result>"
            case .system:
                role = "system"
            case .walletEntry, .agentRequest, .agentResponse, .disclosureConsent:
                // Bookkeeping / demo chips — not part of the model's chat context.
                continue
            }

            apiMessages.append(APIMessage(role: role, content: content))
        }

        return ChatCompletionRequest(
            model: conversation.agentConfig.model,
            messages: apiMessages,
            stream: true
        )
    }

    private func buildSystemPrompt(
        conversation: Conversation,
        participants: [ParticipantInfo],
        toolSchemas: [ToolSchema]
    ) -> String {
        var parts: [String] = []

        let chatType = conversation.type == .dm ? "direct message" : "group conversation"
        let title = conversation.title ?? "a conversation"
        parts.append("You are Teale, an AI assistant in \(chatType) called \"\(title)\".")

        if !participants.isEmpty {
            let names = participants.map { "\($0.displayName) (\($0.participant.role.rawValue))" }
            parts.append("Participants: \(names.joined(separator: ", "))")
        }

        // Inject accumulated group memory — the AI starts every turn already
        // aware of the running context (preferences, dates, plans, facts).
        if let memoryStore, let entries = Optional(memoryStore.entries(for: conversation.id)), !entries.isEmpty {
            let lines = entries.suffix(30).map { entry -> String in
                let categoryTag = entry.category.map { " [\($0)]" } ?? ""
                return "- \(entry.text)\(categoryTag)"
            }
            parts.append("Group memory (what you already know about this group):\n" + lines.joined(separator: "\n"))
        }

        // Inject the local user's personal preferences — only visible when the
        // AI is running on the user's own device. Frame them as "the typing
        // user" so the model doesn't attribute them to other participants.
        if let preferenceStore, !preferenceStore.preferences.entries.isEmpty {
            let lines = preferenceStore.preferences.entries.suffix(30).map { "- \($0.key): \($0.value)" }
            parts.append("Local user's personal preferences (private to this device, treat as context about the person typing):\n" + lines.joined(separator: "\n"))
        }

        if !toolSchemas.isEmpty {
            var toolSection = "You may call the following tools to help the user. "
            toolSection += "To call a tool, emit a single line of the form `<tool_call>{\"tool\":\"NAME\",\"params\":{...}}</tool_call>` and stop. "
            toolSection += "The system will run the tool and reply with `<tool_result>{...}</tool_result>`; you can then reply in natural language or call another tool.\n"
            toolSection += "When you learn a durable fact about the group (a preference, a date, a plan), call `remember` so you don't forget it next time.\n"
            toolSection += "Available tools:\n"
            toolSection += toolSchemas.map(\.promptLine).joined(separator: "\n")
            parts.append(toolSection)
        }

        if let custom = conversation.agentConfig.systemPrompt, !custom.isEmpty {
            parts.append(custom)
        }

        parts.append("Be helpful, concise, and conversational. When multiple people are chatting, address them by name when relevant.")

        return parts.joined(separator: "\n\n")
    }
}
