import Foundation

// MARK: - Preference Entry

/// A single preference fact about the local user, stored on-device only.
/// Examples: "vegetarian", "allergic to cats", "prefers morning flights",
/// "timezone: America/Los_Angeles", "pronouns: they/them".
public struct PreferenceEntry: Codable, Sendable, Identifiable, Equatable {
    public let id: UUID
    public var key: String
    public var value: String
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        key: String,
        value: String,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.key = key
        self.value = value
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

// MARK: - User Preferences

/// The local user's preferences. Never synced to peers — when the AI runs on
/// this device, these preferences are available as context; they stay private
/// to the local device otherwise.
public struct UserPreferences: Codable, Sendable, Equatable {
    public var entries: [PreferenceEntry]

    public init(entries: [PreferenceEntry] = []) {
        self.entries = entries
    }
}
