import Foundation
import SharedTypes

// MARK: - AI Participant

/// Manages AI agent behavior in conversations.
/// Decides when to respond, builds context, and triggers inference.
@MainActor
@Observable
public final class AIParticipant {
    /// Whether the AI is currently generating a response
    public private(set) var isGenerating: Bool = false
    /// Streaming text from the current generation
    public private(set) var streamingText: String = ""

    /// Callback to route inference requests. Set by the app layer.
    /// Takes a ChatCompletionRequest, returns an async stream of token strings.
    public var onInferenceRequest: ((ChatCompletionRequest) -> AsyncThrowingStream<String, Error>)?

    public init() {}

    // MARK: - Should Respond

    /// Determine if the AI agent should respond to a new message.
    /// Default behavior: agent sits in the background until mentioned.
    public func shouldRespond(
        to message: Message,
        config: AgentConfig,
        currentUserID: UUID
    ) -> Bool {
        // Never respond to own AI messages or system messages
        guard !message.isFromAgent else { return false }
        guard message.messageType == .text else { return false }

        // Check for @mention (case-insensitive)
        let lower = message.content.lowercased()
        let isMentioned = lower.contains("@teale") || lower.contains("@agent")

        // Default: only respond when mentioned
        if config.mentionOnly || !config.autoRespond {
            return isMentioned
        }

        // autoRespond mode (opt-in, not default)
        return true
    }

    // MARK: - Generate Response

    /// Generate an AI response for the conversation.
    /// Returns the full response text, or nil if inference is unavailable.
    public func generateResponse(
        conversation: Conversation,
        messages: [Message],
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
            tools: tools
        )

        var fullResponse = ""
        do {
            let stream = onInferenceRequest(request)
            for try await token in stream {
                fullResponse += token
                streamingText = fullResponse
            }
        } catch {
            if fullResponse.isEmpty {
                return nil
            }
        }

        return fullResponse.isEmpty ? nil : fullResponse
    }

    // MARK: - Context Building

    private func buildRequest(
        conversation: Conversation,
        messages: [Message],
        participants: [ParticipantInfo],
        tools: [ConversationToolSummary]
    ) -> ChatCompletionRequest {
        let systemPrompt = buildSystemPrompt(
            conversation: conversation,
            participants: participants,
            tools: tools
        )

        var apiMessages = [APIMessage(role: "system", content: systemPrompt)]

        // Convert recent messages to API format (budget: last 50 messages)
        let recentMessages = messages.suffix(50)
        for msg in recentMessages {
            let role: String
            switch msg.messageType {
            case .text: role = "user"
            case .aiResponse: role = "assistant"
            case .system, .toolCall, .toolResult: role = "system"
            }

            var content = msg.content
            // Prefix user messages with sender name in group chats
            if conversation.type == .group && msg.messageType == .text, let senderID = msg.senderID {
                let senderName = participants.first { $0.participant.userID == senderID }?.displayName ?? "User"
                content = "[\(senderName)] \(content)"
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
        tools: [ConversationToolSummary]
    ) -> String {
        var parts: [String] = []

        // Base identity
        let chatType = conversation.type == .dm ? "direct message" : "group conversation"
        let title = conversation.title ?? "a conversation"
        parts.append("You are Teale, an AI assistant in \(chatType) called \"\(title)\".")

        // Participants
        if !participants.isEmpty {
            let names = participants.map { "\($0.displayName) (\($0.participant.role.rawValue))" }
            parts.append("Participants: \(names.joined(separator: ", "))")
        }

        // Available tools
        if !tools.isEmpty {
            let toolDescriptions = tools.map(\.promptDescription)
            parts.append("Available tools:\n" + toolDescriptions.map { "- \($0)" }.joined(separator: "\n"))
        }

        // Custom system prompt override
        if let custom = conversation.agentConfig.systemPrompt, !custom.isEmpty {
            parts.append(custom)
        }

        // Behavioral guidance
        parts.append("Be helpful, concise, and conversational. When multiple people are chatting, address them by name when relevant.")

        return parts.joined(separator: "\n\n")
    }
}
