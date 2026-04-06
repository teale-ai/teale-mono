import Foundation

/// Reads from bundled AuthKit resources first, then app-level overrides, then environment variables.
public struct SupabaseConfig: Sendable {
    public let url: URL
    public let anonKey: String
    public let redirectURL: URL?

    public init(url: URL, anonKey: String, redirectURL: URL? = nil) {
        self.url = url
        self.anonKey = anonKey
        self.redirectURL = redirectURL
    }

    /// Load config from bundled AuthKit resources, app overrides, then environment variables.
    public static var `default`: SupabaseConfig? {
        if let config = loadFromPlist(bundle: Bundle.module) {
            return config
        }

        if let config = loadFromPlist(bundle: Bundle.main) {
            return config
        }

        if let urlString = normalizedValue(ProcessInfo.processInfo.environment["SUPABASE_URL"]),
           let url = URL(string: urlString),
           let key = normalizedValue(ProcessInfo.processInfo.environment["SUPABASE_ANON_KEY"]) {
            let redirectURL = redirectURL(
                configuredValue: ProcessInfo.processInfo.environment["SUPABASE_REDIRECT_URL"]
            )
            return SupabaseConfig(url: url, anonKey: key, redirectURL: redirectURL)
        }

        return nil
    }

    private static func loadFromPlist(bundle: Bundle) -> SupabaseConfig? {
        guard let plistURL = bundle.url(forResource: "Supabase", withExtension: "plist"),
              let data = try? Data(contentsOf: plistURL),
              let dict = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String],
              let urlString = normalizedValue(dict["SUPABASE_URL"]),
              let url = URL(string: urlString),
              let key = normalizedValue(dict["SUPABASE_ANON_KEY"]) else {
            return nil
        }

        let redirectURL = redirectURL(configuredValue: dict["SUPABASE_REDIRECT_URL"])
        return SupabaseConfig(url: url, anonKey: key, redirectURL: redirectURL)
    }

    private static func normalizedValue(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty,
              !trimmed.contains("YOUR_PROJECT_ID"),
              !trimmed.contains("YOUR_ANON_KEY_HERE") else {
            return nil
        }
        return trimmed
    }

    private static func redirectURL(configuredValue: String?) -> URL? {
        if let configuredValue = normalizedValue(configuredValue),
           let url = URL(string: configuredValue) {
            return url
        }

        guard let urlTypes = Bundle.main.object(forInfoDictionaryKey: "CFBundleURLTypes") as? [[String: Any]] else {
            return nil
        }

        for urlType in urlTypes {
            guard let schemes = urlType["CFBundleURLSchemes"] as? [String] else {
                continue
            }

            if let scheme = schemes.first(where: { !$0.isEmpty }) {
                return URL(string: "\(scheme)://auth/callback")
            }
        }

        return nil
    }
}
