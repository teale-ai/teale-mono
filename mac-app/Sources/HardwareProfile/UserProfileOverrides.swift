import Foundation
import SharedTypes

// MARK: - User Profile Overrides

/// Loads and saves user-defined profile overrides from ~/.teale/profiles.json.
/// Uses the same DeviceModelProfile format as the built-in registry.
/// If the file doesn't exist or can't be parsed, returns empty (graceful fallback).
public struct UserProfileOverrides: Sendable {

    public static var filePath: URL {
        #if os(macOS)
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".teale/profiles.json")
        #else
        // iOS sandbox — no $HOME; put it under the app's Application Support.
        let base = (try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        )) ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("teale/profiles.json")
        #endif
    }

    /// Load user overrides. Returns empty array if file is missing or invalid.
    public static func load() -> [DeviceModelProfile] {
        guard FileManager.default.fileExists(atPath: filePath.path) else {
            return []
        }
        do {
            let data = try Data(contentsOf: filePath)
            return try JSONDecoder().decode([DeviceModelProfile].self, from: data)
        } catch {
            return []
        }
    }

    /// Save user overrides to disk. Creates ~/.teale/ if needed.
    public static func save(_ profiles: [DeviceModelProfile]) throws {
        let directory = filePath.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(profiles)
        try data.write(to: filePath, options: .atomic)
    }
}
