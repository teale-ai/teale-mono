import Foundation

// MARK: - Supported Languages

/// UI language preference, persisted by AppState and synced to the shared
/// desktop web UI (which owns all user-facing translations; the native
/// SwiftUI string tables were removed with the unreachable companion views).
public enum AppLanguage: String, CaseIterable, Codable, Identifiable {
    case english = "en"
    case spanish = "es"
    case portugueseBrazil = "pt-BR"
    case filipinoPhilippines = "fil-PH"
    case chineseSimplified = "zh-Hans"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .english: return "English"
        case .spanish: return "Español"
        case .portugueseBrazil: return "Português (Brasil)"
        case .filipinoPhilippines: return "Filipino (Philippines)"
        case .chineseSimplified: return "简体中文"
        }
    }

    /// Best match for the system locale, used when the user has never picked
    /// a language. Traditional Chinese and unmapped locales fall back to
    /// English.
    public static var systemPreferred: AppLanguage {
        for code in Locale.preferredLanguages {
            let lower = code.lowercased()
            if lower.hasPrefix("zh-hans") || lower.hasPrefix("zh-cn") || lower.hasPrefix("zh-sg") || lower == "zh" {
                return .chineseSimplified
            }
            if lower.hasPrefix("es") { return .spanish }
            if lower.hasPrefix("pt") { return .portugueseBrazil }
            if lower.hasPrefix("fil") { return .filipinoPhilippines }
            if lower.hasPrefix("en") { return .english }
        }
        return .english
    }
}
