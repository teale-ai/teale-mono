import Foundation

/// Configuration for connecting to Supabase.
/// Reads from Supabase.plist in the app bundle, or falls back to environment variables.
public struct SupabaseConfig: Sendable {
    public let url: URL
    public let anonKey: String

    public init(url: URL, anonKey: String) {
        self.url = url
        self.anonKey = anonKey
    }

    /// Load config from Supabase.plist in the main bundle, then env vars.
    public static var `default`: SupabaseConfig? {
        // Try Supabase.plist first
        if let plistURL = Bundle.main.url(forResource: "Supabase", withExtension: "plist"),
           let data = try? Data(contentsOf: plistURL),
           let dict = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String],
           let urlString = dict["SUPABASE_URL"],
           let url = URL(string: urlString),
           let key = dict["SUPABASE_ANON_KEY"] {
            return SupabaseConfig(url: url, anonKey: key)
        }

        // Fall back to environment variables
        if let urlString = ProcessInfo.processInfo.environment["SUPABASE_URL"],
           let url = URL(string: urlString),
           let key = ProcessInfo.processInfo.environment["SUPABASE_ANON_KEY"] {
            return SupabaseConfig(url: url, anonKey: key)
        }

        // Development fallback — return nil when not configured
        return nil
    }
}
