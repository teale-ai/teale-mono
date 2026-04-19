import Foundation

// MARK: - Tool Protocol Types

/// Schema description surfaced to the LLM so it knows how to call a tool.
public struct ToolSchema: Sendable, Equatable {
    public let name: String
    public let description: String
    /// JSON-schema-style parameter descriptor (serialized as a string).
    public let parametersJSON: String

    public init(name: String, description: String, parametersJSON: String) {
        self.name = name
        self.description = description
        self.parametersJSON = parametersJSON
    }

    /// Prompt-formatted description for the system prompt.
    public var promptLine: String {
        "- \(name): \(description). Parameters: \(parametersJSON)"
    }
}

/// A parsed tool call extracted from a model response.
public struct ToolCall: Sendable, Equatable, Codable {
    public let tool: String
    public let params: [String: String]

    public init(tool: String, params: [String: String]) {
        self.tool = tool
        self.params = params
    }
}

/// Result of running a tool.
public struct ToolOutcome: Sendable, Equatable, Codable {
    public let tool: String
    public let success: Bool
    public let content: String

    public init(tool: String, success: Bool, content: String) {
        self.tool = tool
        self.success = success
        self.content = content
    }
}

/// Handler registered with the orchestrator's tool registry.
public protocol ToolHandler: Sendable {
    var schema: ToolSchema { get }
    func run(params: [String: String]) async throws -> String
}

// MARK: - Tool Registry

@MainActor
@Observable
public final class ToolRegistry {
    private var handlers: [String: any ToolHandler] = [:]

    public init() {}

    public func register(_ handler: any ToolHandler) {
        handlers[handler.schema.name] = handler
    }

    public func unregister(name: String) {
        handlers.removeValue(forKey: name)
    }

    public func schemas() -> [ToolSchema] {
        handlers.values.map(\.schema).sorted { $0.name < $1.name }
    }

    public var isEmpty: Bool { handlers.isEmpty }

    /// Execute a tool call. Always returns an outcome; never throws.
    public func execute(_ call: ToolCall) async -> ToolOutcome {
        guard let handler = handlers[call.tool] else {
            return ToolOutcome(tool: call.tool, success: false, content: "Unknown tool '\(call.tool)'")
        }
        do {
            let result = try await handler.run(params: call.params)
            return ToolOutcome(tool: call.tool, success: true, content: result)
        } catch {
            return ToolOutcome(tool: call.tool, success: false, content: "Error: \(error.localizedDescription)")
        }
    }
}

// MARK: - Tool Call Parsing

public enum ToolCallParser {
    /// Extract the first `<tool_call>{...}</tool_call>` block from `text`.
    /// Returns the parsed call plus the remaining text (before the block).
    public static func extract(from text: String) -> (call: ToolCall, textBefore: String)? {
        let openTag = "<tool_call>"
        let closeTag = "</tool_call>"
        guard let openRange = text.range(of: openTag),
              let closeRange = text.range(of: closeTag, range: openRange.upperBound..<text.endIndex)
        else {
            return nil
        }
        let jsonString = String(text[openRange.upperBound..<closeRange.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = jsonString.data(using: .utf8) else { return nil }

        // Decode as { "tool": "name", "params": { ... } } with String values;
        // coerce numbers/bools to strings for ergonomic handler APIs.
        struct Raw: Decodable {
            let tool: String
            let params: [String: AnyCodable]?
        }
        struct AnyCodable: Decodable {
            let stringValue: String
            init(from decoder: Decoder) throws {
                let c = try decoder.singleValueContainer()
                if let s = try? c.decode(String.self) { stringValue = s }
                else if let i = try? c.decode(Int.self) { stringValue = String(i) }
                else if let d = try? c.decode(Double.self) { stringValue = String(d) }
                else if let b = try? c.decode(Bool.self) { stringValue = b ? "true" : "false" }
                else { stringValue = "" }
            }
        }

        guard let parsed = try? JSONDecoder().decode(Raw.self, from: data) else {
            return nil
        }
        let params = parsed.params?.mapValues(\.stringValue) ?? [:]
        let call = ToolCall(tool: parsed.tool, params: params)
        let textBefore = String(text[text.startIndex..<openRange.lowerBound])
        return (call, textBefore)
    }
}
