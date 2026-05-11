import Foundation

// MARK: - OpenAI-Compatible API Types

public struct ChatCompletionRequest: Codable, Sendable {
    public var model: String?
    public var messages: [APIMessage]
    public var temperature: Double?
    public var topP: Double?
    public var maxTokens: Int?
    public var stream: Bool?
    public var streamOptions: [String: Bool]?
    public var stop: [String]?
    public var presencePenalty: Double?
    public var frequencyPenalty: Double?
    public var tools: [OpenAIJSONValue]?
    public var toolChoice: OpenAIJSONValue?
    /// Optional group ID for group-first inference routing.
    /// When set, the provider chain prioritizes group members' devices.
    public var groupID: String?

    enum CodingKeys: String, CodingKey {
        case model, messages, temperature, stream, stop
        case streamOptions = "stream_options"
        case topP = "top_p"
        case maxTokens = "max_tokens"
        case presencePenalty = "presence_penalty"
        case frequencyPenalty = "frequency_penalty"
        case tools
        case toolChoice = "tool_choice"
        case groupID = "group_id"
    }

    public init(
        model: String? = nil,
        messages: [APIMessage],
        temperature: Double? = nil,
        topP: Double? = nil,
        maxTokens: Int? = nil,
        stream: Bool? = nil,
        tools: [OpenAIJSONValue]? = nil,
        toolChoice: OpenAIJSONValue? = nil
    ) {
        self.model = model
        self.messages = messages
        self.temperature = temperature
        self.topP = topP
        self.maxTokens = maxTokens
        self.stream = stream
        self.streamOptions = nil
        self.tools = tools
        self.toolChoice = toolChoice
    }
}

public struct APIMessage: Codable, Sendable {
    public var role: String
    public var content: String
    public var name: String?
    public var toolCalls: [ToolCall]?
    public var toolCallID: String?

    enum CodingKeys: String, CodingKey {
        case role, content, name
        case toolCalls = "tool_calls"
        case toolCallID = "tool_call_id"
    }

    public init(
        role: String,
        content: String,
        name: String? = nil,
        toolCalls: [ToolCall]? = nil,
        toolCallID: String? = nil
    ) {
        self.role = role
        self.content = content
        self.name = name
        self.toolCalls = toolCalls
        self.toolCallID = toolCallID
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        role = try container.decode(String.self, forKey: .role)
        if let text = try? container.decode(String.self, forKey: .content) {
            content = text
        } else if (try? container.decodeNil(forKey: .content)) == true {
            content = ""
        } else if let raw = try? container.decode(OpenAIJSONValue.self, forKey: .content) {
            content = raw.compactJSONString
        } else {
            content = ""
        }
        name = try container.decodeIfPresent(String.self, forKey: .name)
        toolCalls = try container.decodeIfPresent([ToolCall].self, forKey: .toolCalls)
        toolCallID = try container.decodeIfPresent(String.self, forKey: .toolCallID)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(role, forKey: .role)
        try container.encode(content, forKey: .content)
        try container.encodeIfPresent(name, forKey: .name)
        try container.encodeIfPresent(toolCalls, forKey: .toolCalls)
        try container.encodeIfPresent(toolCallID, forKey: .toolCallID)
    }
}

public struct ToolCall: Codable, Sendable, Equatable {
    public var index: Int?
    public var id: String?
    public var type: String?
    public var function: FunctionCall?

    public init(
        index: Int? = nil,
        id: String? = nil,
        type: String? = "function",
        function: FunctionCall? = nil
    ) {
        self.index = index
        self.id = id
        self.type = type
        self.function = function
    }

    public struct FunctionCall: Codable, Sendable, Equatable {
        public var name: String?
        public var arguments: String?

        public init(name: String? = nil, arguments: String? = nil) {
            self.name = name
            self.arguments = arguments
        }
    }
}

public enum OpenAIJSONValue: Codable, Sendable, Equatable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case object([String: OpenAIJSONValue])
    case array([OpenAIJSONValue])
    case null

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int.self) {
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([String: OpenAIJSONValue].self) {
            self = .object(value)
        } else if let value = try? container.decode([OpenAIJSONValue].self) {
            self = .array(value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value):
            try container.encode(value)
        case .int(let value):
            try container.encode(value)
        case .double(let value):
            try container.encode(value)
        case .bool(let value):
            try container.encode(value)
        case .object(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .null:
            try container.encodeNil()
        }
    }

    var compactJSONString: String {
        guard let data = try? JSONEncoder().encode(self),
              let string = String(data: data, encoding: .utf8) else {
            return ""
        }
        return string
    }
}

// MARK: - Chat Completion Response (non-streaming)

public struct ChatCompletionResponse: Codable, Sendable {
    public var id: String
    public var object: String
    public var created: Int
    public var model: String
    public var choices: [Choice]
    public var usage: Usage?

    public struct Choice: Codable, Sendable {
        public var index: Int
        public var message: APIMessage
        public var finishReason: String?

        enum CodingKeys: String, CodingKey {
            case index, message
            case finishReason = "finish_reason"
        }

        public init(index: Int, message: APIMessage, finishReason: String?) {
            self.index = index
            self.message = message
            self.finishReason = finishReason
        }
    }

    public struct Usage: Codable, Sendable {
        public var promptTokens: Int
        public var completionTokens: Int
        public var totalTokens: Int

        enum CodingKeys: String, CodingKey {
            case promptTokens = "prompt_tokens"
            case completionTokens = "completion_tokens"
            case totalTokens = "total_tokens"
        }

        public init(promptTokens: Int, completionTokens: Int, totalTokens: Int) {
            self.promptTokens = promptTokens
            self.completionTokens = completionTokens
            self.totalTokens = totalTokens
        }
    }

    public init(id: String, model: String, choices: [Choice], usage: Usage? = nil) {
        self.id = id
        self.object = "chat.completion"
        self.created = Int(Date().timeIntervalSince1970)
        self.model = model
        self.choices = choices
        self.usage = usage
    }
}

// MARK: - Chat Completion Chunk (streaming)

public struct ChatCompletionChunk: Codable, Sendable {
    public var id: String
    public var object: String
    public var created: Int
    public var model: String
    public var choices: [StreamChoice]
    public var usage: ChatCompletionResponse.Usage?

    public struct StreamChoice: Codable, Sendable {
        public var index: Int
        public var delta: Delta
        public var finishReason: String?

        enum CodingKeys: String, CodingKey {
            case index, delta
            case finishReason = "finish_reason"
        }

        public init(index: Int, delta: Delta, finishReason: String?) {
            self.index = index
            self.delta = delta
            self.finishReason = finishReason
        }
    }

    public struct Delta: Codable, Sendable {
        public var role: String?
        public var content: String?
        public var toolCalls: [ToolCall]?

        enum CodingKeys: String, CodingKey {
            case role, content
            case toolCalls = "tool_calls"
        }

        public init(role: String? = nil, content: String? = nil, toolCalls: [ToolCall]? = nil) {
            self.role = role
            self.content = content
            self.toolCalls = toolCalls
        }
    }

    public init(id: String, model: String, choices: [StreamChoice], usage: ChatCompletionResponse.Usage? = nil) {
        self.id = id
        self.object = "chat.completion.chunk"
        self.created = Int(Date().timeIntervalSince1970)
        self.model = model
        self.choices = choices
        self.usage = usage
    }
}

// MARK: - Models List Response

public struct ModelsListResponse: Codable, Sendable {
    public var object: String
    public var data: [ModelObject]

    public struct ModelObject: Codable, Sendable {
        public var id: String
        public var object: String
        public var created: Int
        public var ownedBy: String

        enum CodingKeys: String, CodingKey {
            case id, object, created
            case ownedBy = "owned_by"
        }

        public init(id: String, object: String, created: Int, ownedBy: String) {
            self.id = id
            self.object = object
            self.created = created
            self.ownedBy = ownedBy
        }
    }

    public init(data: [ModelObject]) {
        self.object = "list"
        self.data = data
    }
}

// MARK: - Error Response

public struct APIErrorResponse: Codable, Sendable {
    public var error: APIError

    public struct APIError: Codable, Sendable {
        public var message: String
        public var type: String
        public var code: String?
    }

    public init(message: String, type: String = "invalid_request_error", code: String? = nil) {
        self.error = APIError(message: message, type: type, code: code)
    }
}
