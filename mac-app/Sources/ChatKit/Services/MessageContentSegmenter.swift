import Foundation

// MARK: - Message Content Segmenter

/// Splits an AI/user message body into text and fenced-code-block segments.
/// Supports triple-backtick fences with an optional language tag on the opening fence.
public enum MessageContentSegmenter {
    public enum Segment: Equatable {
        case text(String)
        case code(language: String?, code: String)
    }

    public static func segments(_ content: String) -> [Segment] {
        var result: [Segment] = []
        var remaining = Substring(content)

        let fence = "```"
        while let open = remaining.range(of: fence) {
            let pre = String(remaining[remaining.startIndex..<open.lowerBound])
            if !pre.isEmpty {
                result.append(.text(pre))
            }

            let afterOpen = open.upperBound
            // Optional language tag on the same line as the opening fence.
            let lineEnd = remaining[afterOpen...].firstIndex(of: "\n") ?? remaining.endIndex
            let languageToken = String(remaining[afterOpen..<lineEnd]).trimmingCharacters(in: .whitespaces)
            let language: String? = languageToken.isEmpty ? nil : languageToken

            // Body starts after the language-tag line (or directly after the fence if the language tag is absent).
            let bodyStart = lineEnd < remaining.endIndex ? remaining.index(after: lineEnd) : lineEnd

            guard let close = remaining[bodyStart...].range(of: fence) else {
                // Unterminated fence — treat the rest as text so we don't silently swallow content.
                let tail = String(remaining[open.lowerBound..<remaining.endIndex])
                result.append(.text(tail))
                return result
            }

            let code = String(remaining[bodyStart..<close.lowerBound])
                .trimmingCharacters(in: CharacterSet(charactersIn: "\n"))
            result.append(.code(language: language, code: code))

            remaining = remaining[close.upperBound...]
        }

        let tail = String(remaining)
        if !tail.isEmpty {
            result.append(.text(tail))
        }
        return result
    }
}
