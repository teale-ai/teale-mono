import Foundation
import InferenceEngine

// MARK: - RAM Limit

public enum RAMLimit: Sendable {
    /// Use up to this percentage of available RAM (after OS reservation)
    case percent(Int)
    /// Use up to this many GB
    case absoluteGB(Double)
}

// MARK: - Contribution Options

public struct ContributionOptions: Sendable {
    public var maxRAMContribution: RAMLimit
    public var schedule: SchedulePreset
    public var requireWiFi: Bool
    public var requirePluggedIn: Bool
    public var maxConcurrentRequests: Int
    public var allowedModelFamilies: [String]?

    public init(
        maxRAMContribution: RAMLimit = .percent(50),
        schedule: SchedulePreset = .afterHours,
        requireWiFi: Bool = true,
        requirePluggedIn: Bool = true,
        maxConcurrentRequests: Int = 1,
        allowedModelFamilies: [String]? = nil
    ) {
        self.maxRAMContribution = maxRAMContribution
        self.schedule = schedule
        self.requireWiFi = requireWiFi
        self.requirePluggedIn = requirePluggedIn
        self.maxConcurrentRequests = maxConcurrentRequests
        self.allowedModelFamilies = allowedModelFamilies
    }

    /// Convert to a ContributionSchedule for the throttler
    func toContributionSchedule() -> ContributionSchedule {
        var schedule = ContributionSchedule.fromPreset(self.schedule)
        schedule.onlyWhenPluggedIn = requirePluggedIn
        schedule.onlyOnWiFi = requireWiFi
        return schedule
    }
}
