import Foundation

func companionTruncatedIdentifier(_ value: String, prefix: Int = 8, suffix: Int = 8) -> String {
    guard value.count > prefix + suffix else { return value }
    return String(value.prefix(prefix)) + "..." + String(value.suffix(suffix))
}
