import Foundation
import SharedTypes

// MARK: - Task Categories

/// What kind of cognitive work a sub-task involves.
public enum TaskCategory: String, Codable, Sendable, CaseIterable {
    case code
    case reasoning
    case creative
    case factual
    case summarization
    case translation
    case structured
    case general
}

// MARK: - Sub-Task

/// A single unit of work produced by request decomposition.
public struct SubTask: Sendable, Identifiable, Codable {
    public let id: UUID
    public let prompt: String
    public let category: TaskCategory
    public let orderIndex: Int
    public let dependsOn: [UUID]
    public let estimatedTokens: Int

    public init(
        id: UUID = UUID(),
        prompt: String,
        category: TaskCategory,
        orderIndex: Int,
        dependsOn: [UUID] = [],
        estimatedTokens: Int = 500
    ) {
        self.id = id
        self.prompt = prompt
        self.category = category
        self.orderIndex = orderIndex
        self.dependsOn = dependsOn
        self.estimatedTokens = estimatedTokens
    }
}

// MARK: - Compilation Plan

/// How the compiler decided to handle a request.
public enum CompilationPlan: Sendable {
    /// Simple request — pass straight through, no decomposition.
    case passthrough

    /// Decompose into sub-tasks, execute in parallel, synthesize.
    case compiled(subTasks: [SubTask], synthesisPrompt: String)

    /// Send the same request to N models, pick the best response.
    case compete(candidateCount: Int)
}

// MARK: - Sub-Task Result

/// The output from executing one sub-task on a device.
public struct SubTaskResult: Sendable {
    public let subTaskID: UUID
    public let content: String
    public let model: String
    public let deviceID: UUID?
    public let tokenCount: Int
    public let latencyMs: Double

    public init(
        subTaskID: UUID,
        content: String,
        model: String,
        deviceID: UUID? = nil,
        tokenCount: Int,
        latencyMs: Double
    ) {
        self.subTaskID = subTaskID
        self.content = content
        self.model = model
        self.deviceID = deviceID
        self.tokenCount = tokenCount
        self.latencyMs = latencyMs
    }
}

// MARK: - Model on Network

/// A model currently loaded and available somewhere on the network.
public struct ModelOnNetwork: Sendable, Identifiable {
    public var id: String { "\(model)-\(deviceID?.uuidString ?? "local")" }
    public let model: String
    public let modelFamily: String
    public let parameterBillions: Double
    public let deviceID: UUID?
    public let currentLoad: Int
    public let estimatedToksPerSec: Double

    public init(
        model: String,
        modelFamily: String,
        parameterBillions: Double,
        deviceID: UUID? = nil,
        currentLoad: Int = 0,
        estimatedToksPerSec: Double = 30.0
    ) {
        self.model = model
        self.modelFamily = modelFamily
        self.parameterBillions = parameterBillions
        self.deviceID = deviceID
        self.currentLoad = currentLoad
        self.estimatedToksPerSec = estimatedToksPerSec
    }
}

// MARK: - Model Affinity

/// How well a model family performs on each task category.
public struct ModelAffinity: Codable, Sendable {
    public let family: String
    public let scores: [TaskCategory: Double]

    public init(family: String, scores: [TaskCategory: Double]) {
        self.family = family
        self.scores = scores
    }

    public func score(for category: TaskCategory) -> Double {
        scores[category] ?? 0.5
    }
}

// MARK: - Contribution Record

/// Tracks what a device contributed to a compiled response.
public struct ContributionRecord: Sendable {
    public let deviceID: UUID?
    public let model: String
    public let subTaskID: UUID
    public let tokenCount: Int
    public let weight: Double

    public init(
        deviceID: UUID?,
        model: String,
        subTaskID: UUID,
        tokenCount: Int,
        weight: Double
    ) {
        self.deviceID = deviceID
        self.model = model
        self.subTaskID = subTaskID
        self.tokenCount = tokenCount
        self.weight = weight
    }
}

// MARK: - Compilation Errors

public enum CompilationError: LocalizedError, Sendable {
    case decompositionFailed(String)
    case noModelsAvailable
    case subTaskFailed(subTaskID: UUID, error: String)
    case synthesisFailed(String)
    case allCandidatesFailed
    case modelNotAvailable(requested: String, available: [String])

    public var errorDescription: String? {
        switch self {
        case .decompositionFailed(let reason): return "Decomposition failed: \(reason)"
        case .noModelsAvailable: return "No models available on the network"
        case .subTaskFailed(_, let error): return "Sub-task failed: \(error)"
        case .synthesisFailed(let reason): return "Synthesis failed: \(reason)"
        case .allCandidatesFailed: return "All candidate models failed"
        case .modelNotAvailable(let requested, let available):
            let list = available.isEmpty ? "none" : available.joined(separator: ", ")
            return "Model '\(requested)' is not available. Available models: \(list)"
        }
    }
}
