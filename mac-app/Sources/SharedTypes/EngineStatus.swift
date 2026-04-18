import Foundation

// MARK: - Engine Status

public enum EngineStatus: Sendable {
    case idle
    case loadingModel(ModelDescriptor)
    case ready(ModelDescriptor)
    case generating(ModelDescriptor, tokensGenerated: Int)
    case error(String)
    case paused(reason: PauseReason)

    public var isReady: Bool {
        if case .ready = self { return true }
        return false
    }

    public var isGenerating: Bool {
        if case .generating = self { return true }
        return false
    }

    public var currentModel: ModelDescriptor? {
        switch self {
        case .ready(let model): return model
        case .generating(let model, _): return model
        case .loadingModel(let model): return model
        default: return nil
        }
    }

    public var displayText: String {
        switch self {
        case .idle: return "Idle"
        case .loadingModel(let m): return "Loading \(m.name)..."
        case .ready(let m): return "Ready — \(m.name)"
        case .generating(let m, let tokens): return "Generating (\(tokens) tokens) — \(m.name)"
        case .error(let msg): return "Error: \(msg)"
        case .paused(let reason): return "Paused: \(reason.displayText)"
        }
    }
}

// MARK: - Pause Reason

public enum PauseReason: Sendable {
    case thermal
    case battery
    case lowPowerMode
    case userActive
    case networkUnavailable
    case scheduledOff
    case notPluggedIn
    case notOnWiFi

    public var displayText: String {
        switch self {
        case .thermal: return "Thermal throttling"
        case .battery: return "Low battery"
        case .lowPowerMode: return "Low Power Mode"
        case .userActive: return "User active"
        case .networkUnavailable: return "No network"
        case .scheduledOff: return "Outside scheduled hours"
        case .notPluggedIn: return "Not plugged in"
        case .notOnWiFi: return "Not on Wi-Fi"
        }
    }
}

// MARK: - Throttle Level

public enum ThrottleLevel: Int, Sendable, Comparable {
    case full = 100
    case reduced = 75
    case minimal = 25
    case paused = 0

    public static func < (lhs: ThrottleLevel, rhs: ThrottleLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}
