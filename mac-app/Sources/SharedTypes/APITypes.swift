import Foundation

// MARK: - OpenAI-Compatible API Types

public struct ChatCompletionRequest: Codable, Sendable {
    public var model: String?
    public var messages: [APIMessage]
    public var temperature: Double?
    public var topP: Double?
    public var maxTokens: Int?
    public var stream: Bool?
    public var stop: [String]?
    public var presencePenalty: Double?
    public var frequencyPenalty: Double?
    /// Optional group ID for group-first inference routing.
    /// When set, the provider chain prioritizes group members' devices.
    public var groupID: String?

    enum CodingKeys: String, CodingKey {
        case model, messages, temperature, stream, stop
        case topP = "top_p"
        case maxTokens = "max_tokens"
        case presencePenalty = "presence_penalty"
        case frequencyPenalty = "frequency_penalty"
        case groupID = "group_id"
    }

    public init(
        model: String? = nil,
        messages: [APIMessage],
        temperature: Double? = nil,
        topP: Double? = nil,
        maxTokens: Int? = nil,
        stream: Bool? = nil
    ) {
        self.model = model
        self.messages = messages
        self.temperature = temperature
        self.topP = topP
        self.maxTokens = maxTokens
        self.stream = stream
    }
}

public struct APIMessage: Codable, Sendable {
    public var role: String
    public var content: String

    public init(role: String, content: String) {
        self.role = role
        self.content = content
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

        public init(role: String? = nil, content: String? = nil) {
            self.role = role
            self.content = content
        }
    }

    public init(id: String, model: String, choices: [StreamChoice]) {
        self.id = id
        self.object = "chat.completion.chunk"
        self.created = Int(Date().timeIntervalSince1970)
        self.model = model
        self.choices = choices
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
