import Foundation

public enum CompanionDisplayUnit: String, CaseIterable, Codable, Sendable, Identifiable {
    case credits
    case usd

    public var id: String { rawValue }

    public static let creditsPerUSD: Double = 1_000_000

    public var label: String {
        switch self {
        case .credits:
            return "Credits"
        case .usd:
            return "USD"
        }
    }

    public var shortLabel: String {
        switch self {
        case .credits:
            return "credits"
        case .usd:
            return "USD"
        }
    }

    public var spendLabel: String {
        switch self {
        case .credits:
            return "Teale credits"
        case .usd:
            return "USD"
        }
    }
}
