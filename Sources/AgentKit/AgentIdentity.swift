import Foundation

// MARK: - Agent Type

public enum AgentType: String, Codable, Sendable, CaseIterable {
    case personal
    case business
    case service
}

// MARK: - Communication Tone

public enum CommunicationTone: String, Codable, Sendable, CaseIterable {
    case formal
    case casual
    case concise
    case detailed
}

// MARK: - Agent Capability

public struct AgentCapability: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    public var description: String
    public var parameters: [String: String]

    public init(id: String, name: String, description: String, parameters: [String: String] = [:]) {
        self.id = id
        self.name = name
        self.description = description
        self.parameters = parameters
    }
}

// MARK: - Well-Known Capabilities

extension AgentCapability {
    public static let scheduling = AgentCapability(
        id: "scheduling",
        name: "Scheduling",
        description: "Schedule meetings, appointments, and events"
    )

    public static let shopping = AgentCapability(
        id: "shopping",
        name: "Shopping",
        description: "Find products, compare prices, and make purchases"
    )

    public static let customerSupport = AgentCapability(
        id: "customer-support",
        name: "Customer Support",
        description: "Handle customer inquiries and support requests"
    )

    public static let inference = AgentCapability(
        id: "inference",
        name: "Inference",
        description: "Run AI model inference on Apple Silicon hardware"
    )

    public static let translation = AgentCapability(
        id: "translation",
        name: "Translation",
        description: "Translate text between languages",
        parameters: ["languages": "en,es,fr,de,ja,zh"]
    )

    public static let generalChat = AgentCapability(
        id: "general-chat",
        name: "General Chat",
        description: "Free-form conversation and Q&A"
    )

    public static let taskExecution = AgentCapability(
        id: "task-execution",
        name: "Task Execution",
        description: "Execute arbitrary tasks on behalf of the user"
    )

    public static let informationRetrieval = AgentCapability(
        id: "information-retrieval",
        name: "Information Retrieval",
        description: "Search for and retrieve information"
    )
}

// MARK: - Availability Schedule

public struct AvailabilitySchedule: Codable, Sendable, Equatable {
    public struct DayRange: Codable, Sendable, Equatable {
        public var day: Int       // 1 = Monday, 7 = Sunday
        public var startHour: Int // 0-23
        public var endHour: Int   // 0-23

        public init(day: Int, startHour: Int, endHour: Int) {
            self.day = day
            self.startHour = startHour
            self.endHour = endHour
        }
    }

    public var timezone: String
    public var ranges: [DayRange]
    public var alwaysAvailable: Bool

    public init(timezone: String = "UTC", ranges: [DayRange] = [], alwaysAvailable: Bool = true) {
        self.timezone = timezone
        self.ranges = ranges
        self.alwaysAvailable = alwaysAvailable
    }
}

// MARK: - Delegation Rule

public struct DelegationRule: Codable, Sendable, Equatable {
    public var capability: String
    public var maxCreditSpend: Double
    public var requiresApproval: Bool
    public var allowedAgentTypes: [AgentType]

    public init(capability: String, maxCreditSpend: Double, requiresApproval: Bool = false, allowedAgentTypes: [AgentType] = AgentType.allCases) {
        self.capability = capability
        self.maxCreditSpend = maxCreditSpend
        self.requiresApproval = requiresApproval
        self.allowedAgentTypes = allowedAgentTypes
    }
}

// MARK: - Agent Preferences

public struct AgentPreferences: Codable, Sendable, Equatable {
    public var tone: CommunicationTone
    public var language: String
    public var autoNegotiate: Bool
    public var maxBudgetPerTransaction: Double?
    public var availableHours: AvailabilitySchedule?
    public var delegationRules: [DelegationRule]

    public init(
        tone: CommunicationTone = .casual,
        language: String = "en",
        autoNegotiate: Bool = true,
        maxBudgetPerTransaction: Double? = nil,
        availableHours: AvailabilitySchedule? = nil,
        delegationRules: [DelegationRule] = []
    ) {
        self.tone = tone
        self.language = language
        self.autoNegotiate = autoNegotiate
        self.maxBudgetPerTransaction = maxBudgetPerTransaction
        self.availableHours = availableHours
        self.delegationRules = delegationRules
    }
}

// MARK: - Business Info

public struct BusinessInfo: Codable, Sendable, Equatable {
    public var businessName: String
    public var category: String
    public var location: String?
    public var website: String?
    public var verified: Bool

    public init(businessName: String, category: String, location: String? = nil, website: String? = nil, verified: Bool = false) {
        self.businessName = businessName
        self.category = category
        self.location = location
        self.website = website
        self.verified = verified
    }
}

// MARK: - Agent Profile

public struct AgentProfile: Codable, Sendable, Equatable, Identifiable {
    public var id: String { nodeID }
    public var nodeID: String
    public var agentType: AgentType
    public var displayName: String
    public var bio: String
    public var capabilities: [AgentCapability]
    public var preferences: AgentPreferences
    public var businessInfo: BusinessInfo?
    public var createdAt: Date
    public var version: Int

    public init(
        nodeID: String,
        agentType: AgentType = .personal,
        displayName: String,
        bio: String = "",
        capabilities: [AgentCapability] = [.generalChat],
        preferences: AgentPreferences = AgentPreferences(),
        businessInfo: BusinessInfo? = nil,
        createdAt: Date = Date(),
        version: Int = 1
    ) {
        self.nodeID = nodeID
        self.agentType = agentType
        self.displayName = displayName
        self.bio = bio
        self.capabilities = capabilities
        self.preferences = preferences
        self.businessInfo = businessInfo
        self.createdAt = createdAt
        self.version = version
    }
}
