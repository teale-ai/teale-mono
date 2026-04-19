import Foundation

// MARK: - User Preference Store

/// Device-local persistence for the user's personal preferences.
/// File: `~/Library/Application Support/Teale/user_preferences.json`.
/// Never synced to peers — these are this device's user's private facts that
/// the local AI can use when deciding what to say on this user's behalf.
@MainActor
@Observable
public final class UserPreferenceStore {
    public private(set) var preferences: UserPreferences = UserPreferences()

    public init() {
        self.preferences = load() ?? UserPreferences()
    }

    // MARK: - Mutations

    @discardableResult
    public func setPreference(key: String, value: String) -> PreferenceEntry {
        let trimmedKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if let idx = preferences.entries.firstIndex(where: { $0.key.caseInsensitiveCompare(trimmedKey) == .orderedSame }) {
            preferences.entries[idx].value = value
            preferences.entries[idx].updatedAt = Date()
            save()
            return preferences.entries[idx]
        }
        let entry = PreferenceEntry(key: trimmedKey, value: value)
        preferences.entries.append(entry)
        save()
        return entry
    }

    public func remove(id: UUID) {
        preferences.entries.removeAll { $0.id == id }
        save()
    }

    public func clear() {
        preferences.entries.removeAll()
        save()
    }

    // MARK: - Queries

    public func lookup(_ topic: String? = nil, limit: Int = 40) -> [PreferenceEntry] {
        guard let topic, !topic.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return Array(preferences.entries.suffix(limit))
        }
        let q = topic.lowercased()
        return preferences.entries
            .filter { $0.key.lowercased().contains(q) || $0.value.lowercased().contains(q) }
            .suffix(limit)
            .map { $0 }
    }

    // MARK: - Persistence

    private static var fileURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = support.appendingPathComponent("Teale", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("user_preferences.json")
    }

    private func load() -> UserPreferences? {
        guard let data = try? Data(contentsOf: Self.fileURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(UserPreferences.self, from: data)
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(preferences) else { return }
        try? data.write(to: Self.fileURL, options: .atomic)
    }
}
