import Foundation

// MARK: - Tool Executor

/// Executes tool calls on the local device when the current user owns the tool.
/// Apple services (Calendar, Contacts, Reminders) use native frameworks (EventKit, etc.).
@MainActor
@Observable
public final class ToolExecutor {
    public private(set) var pendingToolCalls: [Message] = []

    /// Callback for when a tool result is ready to be sent as a message
    public var onToolResult: ((String, UUID, ToolResultMeta) async -> Void)?

    public init() {}

    /// Check if we should handle a tool call (current user owns the tool)
    public func shouldHandle(
        toolCall: Message,
        myTools: [ToolConnection],
        currentUserID: UUID
    ) -> Bool {
        guard toolCall.messageType == .toolCall else { return false }
        // Check if any of my tools match the requested tool type
        // For now, simple string matching on content
        return myTools.contains { $0.isActive && $0.userID == currentUserID }
    }

    /// Execute a tool call and return the result
    public func execute(
        toolCall: Message,
        tool: ToolConnection
    ) async -> (success: Bool, result: String) {
        // Phase 1: Return placeholder results
        // Phase 2: Actually call EventKit, Contacts, etc.
        switch tool.toolType {
        case .calendar:
            return await executeCalendarTool(toolCall: toolCall, tool: tool)
        case .reminders:
            return (true, "Reminders integration coming soon")
        case .contacts:
            return (true, "Contacts integration coming soon")
        case .email:
            return (true, "Email integration coming soon")
        case .notes:
            return (true, "Notes integration coming soon")
        case .custom:
            return (false, "Custom tool execution not yet supported")
        }
    }

    // MARK: - Calendar Tool

    private func executeCalendarTool(
        toolCall: Message,
        tool: ToolConnection
    ) async -> (success: Bool, result: String) {
        // Phase 1: Acknowledge the tool call
        // Phase 2: Use EventKit to actually create/read events
        guard tool.scopes.contains(.read) || tool.scopes.contains(.create) else {
            return (false, "Insufficient permissions for calendar access")
        }

        return (true, "Calendar tool acknowledged. EventKit integration pending.")
    }
}

// MARK: - Tool Result Metadata (convenience alias)

public typealias ToolResultMeta = MessageMetadata.ToolResultMeta
