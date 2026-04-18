import Foundation

// MARK: - Schedule Preset

public enum SchedulePreset: String, Codable, CaseIterable, Sendable {
    case alwaysOn
    case businessHours
    case afterHours
    case weekendsOnly

    public var displayName: String {
        switch self {
        case .alwaysOn: return "Always On"
        case .businessHours: return "Business Hours (9-17)"
        case .afterHours: return "After Hours (17-9)"
        case .weekendsOnly: return "Weekends Only"
        }
    }
}

// MARK: - Contribution Schedule

public struct ContributionSchedule: Codable, Sendable {
    /// 7 days (Mon=0..Sun=6) × 24 hours. `true` = contributing.
    public var weeklyGrid: [[Bool]]
    public var onlyWhenPluggedIn: Bool
    public var onlyOnWiFi: Bool
    public var preset: SchedulePreset?

    public init(
        weeklyGrid: [[Bool]] = Array(repeating: Array(repeating: true, count: 24), count: 7),
        onlyWhenPluggedIn: Bool = false,
        onlyOnWiFi: Bool = false,
        preset: SchedulePreset? = .alwaysOn
    ) {
        self.weeklyGrid = weeklyGrid
        self.onlyWhenPluggedIn = onlyWhenPluggedIn
        self.onlyOnWiFi = onlyOnWiFi
        self.preset = preset
    }

    /// Build a schedule from a preset
    public static func fromPreset(_ preset: SchedulePreset) -> ContributionSchedule {
        var grid = Array(repeating: Array(repeating: false, count: 24), count: 7)

        switch preset {
        case .alwaysOn:
            grid = Array(repeating: Array(repeating: true, count: 24), count: 7)

        case .businessHours:
            // Mon-Fri (0-4), 9-17
            for day in 0..<5 {
                for hour in 9..<17 {
                    grid[day][hour] = true
                }
            }

        case .afterHours:
            // Mon-Fri: 17-23 and 0-9. Weekends: all day.
            for day in 0..<5 {
                for hour in 0..<9 { grid[day][hour] = true }
                for hour in 17..<24 { grid[day][hour] = true }
            }
            for day in 5..<7 {
                for hour in 0..<24 { grid[day][hour] = true }
            }

        case .weekendsOnly:
            for day in 5..<7 {
                for hour in 0..<24 { grid[day][hour] = true }
            }
        }

        return ContributionSchedule(weeklyGrid: grid, preset: preset)
    }

    /// Check if the schedule allows contribution right now
    public func isActiveNow() -> Bool {
        let calendar = Calendar.current
        let now = Date()
        let weekday = calendar.component(.weekday, from: now)
        let hour = calendar.component(.hour, from: now)

        // Calendar weekday: 1=Sun, 2=Mon ... 7=Sat
        // Grid index: 0=Mon ... 6=Sun
        let dayIndex: Int
        switch weekday {
        case 1: dayIndex = 6  // Sunday
        case 2: dayIndex = 0  // Monday
        case 3: dayIndex = 1
        case 4: dayIndex = 2
        case 5: dayIndex = 3
        case 6: dayIndex = 4
        case 7: dayIndex = 5  // Saturday
        default: dayIndex = 0
        }

        guard dayIndex < weeklyGrid.count, hour < weeklyGrid[dayIndex].count else {
            return true  // Fallback: allow
        }

        return weeklyGrid[dayIndex][hour]
    }

    // MARK: - Persistence

    private static var fileURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("Teale/contribution_schedule.json")
    }

    public func save() {
        let encoder = JSONEncoder()
        guard let data = try? encoder.encode(self) else { return }
        let dir = Self.fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? data.write(to: Self.fileURL, options: .atomic)
    }

    public static func loadFromDisk() -> ContributionSchedule {
        guard FileManager.default.fileExists(atPath: fileURL.path),
              let data = try? Data(contentsOf: fileURL),
              let schedule = try? JSONDecoder().decode(ContributionSchedule.self, from: data) else {
            return ContributionSchedule()
        }
        return schedule
    }
}
