import Foundation
import SharedTypes

public enum PrivacyFilterMode: String, CaseIterable, Codable, Sendable, Identifiable {
    case off = "off"
    case autoWAN = "auto_wan"
    case always = "always"

    public var id: String { rawValue }

    public static let userDefaultsKey = "teale.privacy_filter_mode"

    public static func storedDefault() -> PrivacyFilterMode {
#if os(iOS)
        let fallback: PrivacyFilterMode = .off
#else
        let fallback: PrivacyFilterMode = .autoWAN
#endif
        guard let raw = UserDefaults.standard.string(forKey: userDefaultsKey) else {
            return fallback
        }
        return PrivacyFilterMode(rawValue: raw) ?? fallback
    }

    public func persist() {
        UserDefaults.standard.set(rawValue, forKey: Self.userDefaultsKey)
    }
}

public enum PrivacyHelperState: String, Codable, Sendable {
    case disabled
    case unsupported
    case ready
    case unavailable
}

public struct PrivacyHelperStatus: Codable, Sendable {
    public var state: PrivacyHelperState
    public var detail: String?

    public init(state: PrivacyHelperState, detail: String? = nil) {
        self.state = state
        self.detail = detail
    }
}

public struct PreparedPrivacyFilteredRequest: Sendable {
    public let request: ChatCompletionRequest
    public let placeholderMap: [String: String]

    public init(request: ChatCompletionRequest, placeholderMap: [String: String]) {
        self.request = request
        self.placeholderMap = placeholderMap
    }

    public var isFiltered: Bool { !placeholderMap.isEmpty }

    public func restoreText(_ text: String) -> String {
        guard isFiltered else { return text }
        var restored = text
        for (placeholder, original) in placeholderMap.sorted(by: { $0.key.count > $1.key.count }) {
            restored = restored.replacingOccurrences(of: placeholder, with: original)
        }
        return restored
    }

    public func restoreResponse(_ response: ChatCompletionResponse) -> ChatCompletionResponse {
        guard isFiltered, var first = response.choices.first else {
            return response
        }
        first.message.content = restoreText(first.message.content)
        var restored = response
        restored.choices[0] = first
        return restored
    }

    public func makeStreamingRestorer() -> StreamingPlaceholderRestorer? {
        guard isFiltered else { return nil }
        return StreamingPlaceholderRestorer(placeholderMap: placeholderMap)
    }
}

public final class StreamingPlaceholderRestorer: @unchecked Sendable {
    private let replacements: [(placeholder: String, original: String)]
    private let placeholders: [String]
    private let maxPlaceholderLength: Int
    private var buffer = ""

    public init(placeholderMap: [String: String]) {
        self.replacements = placeholderMap
            .map { (placeholder: $0.key, original: $0.value) }
            .sorted { lhs, rhs in lhs.placeholder.count > rhs.placeholder.count }
        self.placeholders = self.replacements.map(\.placeholder)
        self.maxPlaceholderLength = self.placeholders.map(\.count).max() ?? 0
    }

    public func consume(_ text: String, terminal: Bool = false) -> String {
        buffer += text
        let holdback = terminal ? 0 : holdbackLength(in: buffer)
        let safeLength = max(0, buffer.count - holdback)
        let safe = String(buffer.prefix(safeLength))
        buffer = String(buffer.dropFirst(safeLength))
        return replacePlaceholders(in: safe)
    }

    public func finish() -> String {
        let flushed = replacePlaceholders(in: buffer)
        buffer = ""
        return flushed
    }

    private func replacePlaceholders(in text: String) -> String {
        guard !text.isEmpty else { return text }
        var restored = text
        for replacement in replacements {
            restored = restored.replacingOccurrences(
                of: replacement.placeholder,
                with: replacement.original
            )
        }
        return restored
    }

    private func holdbackLength(in text: String) -> Int {
        guard maxPlaceholderLength > 1, !text.isEmpty else { return 0 }
        let maxCandidate = min(maxPlaceholderLength - 1, text.count)
        guard maxCandidate > 0 else { return 0 }
        for candidate in stride(from: maxCandidate, through: 1, by: -1) {
            let suffix = String(text.suffix(candidate))
            if placeholders.contains(where: { $0.hasPrefix(suffix) }) {
                return candidate
            }
        }
        return 0
    }
}

public enum DesktopPrivacyFilterError: LocalizedError {
    case unsupportedOnThisPlatform
    case helperUnavailable(String)
    case invalidResponse(String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedOnThisPlatform:
            return "The privacy filter helper is not supported on this platform."
        case .helperUnavailable(let detail):
            return "Privacy filter unavailable: \(detail)"
        case .invalidResponse(let detail):
            return "Privacy filter returned an invalid response: \(detail)"
        }
    }
}

private struct HelperHealthResponse: Decodable {
    let ready: Bool
    let error: String?
}

struct PrivacyDetectedSpan: Decodable, Equatable {
    let label: String
    let start: Int
    let end: Int
    let text: String
}

private struct HelperRedactResponse: Decodable {
    let ok: Bool
    let spans: [PrivacyDetectedSpan]
}

struct PrivacyPlaceholderPlanner {
    var placeholderBySemanticKey = [String: String]()
    var placeholderMap = [String: String]()
    var nextIndexByPrefix = [String: Int]()

    mutating func replaceSpans(
        in text: String,
        spans: [PrivacyDetectedSpan]
    ) -> String {
        let sortedSpans = spans.sorted { lhs, rhs in
            if lhs.start == rhs.start {
                return lhs.end < rhs.end
            }
            return lhs.start < rhs.start
        }

        var result = ""
        var cursor = 0
        for span in sortedSpans {
            guard span.start >= cursor, span.end >= span.start else { continue }
            result += substring(in: text, from: cursor, to: span.start)
            let semanticKey = "\(span.label)\u{1F}\(span.text)"
            let placeholder = placeholderBySemanticKey[semanticKey] ?? {
                let prefix = placeholderPrefix(for: span.label)
                let next = (nextIndexByPrefix[prefix] ?? 0) + 1
                nextIndexByPrefix[prefix] = next
                let generated = "<\(prefix)_\(next)>"
                placeholderBySemanticKey[semanticKey] = generated
                placeholderMap[generated] = span.text
                return generated
            }()
            result += placeholder
            cursor = span.end
        }
        result += substring(in: text, from: cursor, to: text.count)
        return result
    }

    private func substring(in text: String, from startOffset: Int, to endOffset: Int) -> String {
        guard startOffset < endOffset else { return "" }
        let lower = text.index(text.startIndex, offsetBy: max(0, min(startOffset, text.count)))
        let upper = text.index(text.startIndex, offsetBy: max(0, min(endOffset, text.count)))
        guard lower < upper else { return "" }
        return String(text[lower..<upper])
    }

    private func placeholderPrefix(for label: String) -> String {
        switch label {
        case "private_person":
            return "PRIVATE_PERSON"
        case "private_email":
            return "PRIVATE_EMAIL"
        case "private_phone":
            return "PRIVATE_PHONE"
        case "private_date":
            return "PRIVATE_DATE"
        case "private_url":
            return "PRIVATE_URL"
        case "private_address":
            return "PRIVATE_ADDRESS"
        case "account_number":
            return "PRIVATE_ACCOUNT_NUMBER"
        case "secret":
            return "SECRET"
        default:
            let normalized = label
                .uppercased()
                .replacingOccurrences(of: "-", with: "_")
                .replacingOccurrences(of: " ", with: "_")
            return normalized.isEmpty ? "REDACTED" : normalized
        }
    }
}

public actor DesktopPrivacyFilter {
    public static let shared = DesktopPrivacyFilter()

    private static let defaultPort = 11439
    private static let defaultHost = "127.0.0.1"

    private var helperStatus = PrivacyHelperStatus(state: .disabled)
#if os(macOS)
    private var helperProcess: Process?
    private var lastSpawnAttempt: Date?
#endif

    public func status(for mode: PrivacyFilterMode = .storedDefault()) async -> PrivacyHelperStatus {
        if mode == .off {
            let status = PrivacyHelperStatus(state: .disabled, detail: "Privacy filtering is off.")
            helperStatus = status
            return status
        }

        do {
            try await ensureHelperAvailable()
            let status = PrivacyHelperStatus(state: .ready, detail: "Helper is ready.")
            helperStatus = status
            return status
        } catch {
            let state: PrivacyHelperState = isSupportedPlatform ? .unavailable : .unsupported
            let status = PrivacyHelperStatus(state: state, detail: error.localizedDescription)
            helperStatus = status
            return status
        }
    }

    public func prepare(request: ChatCompletionRequest) async throws -> PreparedPrivacyFilteredRequest {
        try await ensureHelperAvailable()

        var filteredRequest = request
        var planner = PrivacyPlaceholderPlanner()

        for index in filteredRequest.messages.indices {
            let original = filteredRequest.messages[index].content
            guard !original.isEmpty else { continue }
            let spans = try await redactSpans(for: original)
            guard !spans.isEmpty else { continue }

            let redacted = planner.replaceSpans(in: original, spans: spans)
            filteredRequest.messages[index].content = redacted
        }

        return PreparedPrivacyFilteredRequest(
            request: filteredRequest,
            placeholderMap: planner.placeholderMap
        )
    }

    private var isSupportedPlatform: Bool {
#if os(macOS)
        return true
#else
        return ProcessInfo.processInfo.environment["TEALE_OPF_HELPER_URL"] != nil
#endif
    }

    private func helperBaseURL() -> URL {
        if let override = ProcessInfo.processInfo.environment["TEALE_OPF_HELPER_URL"],
           let url = URL(string: override) {
            return url
        }
        return URL(string: "http://\(Self.defaultHost):\(Self.defaultPort)")!
    }

    private func ensureHelperAvailable() async throws {
        if try await pingHealth() {
            return
        }
#if os(macOS)
        try spawnHelperIfNeeded()
        for _ in 0..<12 {
            try? await Task.sleep(for: .milliseconds(250))
            if try await pingHealth() {
                return
            }
        }
#endif
        throw DesktopPrivacyFilterError.helperUnavailable(
            helperStatus.detail ?? "helper did not become ready"
        )
    }

    private func pingHealth() async throws -> Bool {
        var request = URLRequest(url: helperBaseURL().appending(path: "health"))
        request.timeoutInterval = 1.5
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw DesktopPrivacyFilterError.invalidResponse("missing HTTP response")
        }
        guard http.statusCode == 200 else {
            let detail = String(data: data, encoding: .utf8) ?? "HTTP \(http.statusCode)"
            throw DesktopPrivacyFilterError.helperUnavailable(detail)
        }
        let health = try JSONDecoder().decode(HelperHealthResponse.self, from: data)
        if !health.ready {
            throw DesktopPrivacyFilterError.helperUnavailable(health.error ?? "helper reported not ready")
        }
        return true
    }

    private func redactSpans(for text: String) async throws -> [PrivacyDetectedSpan] {
        var request = URLRequest(url: helperBaseURL().appending(path: "v1/redact"))
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["text": text])

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw DesktopPrivacyFilterError.invalidResponse("missing HTTP response")
        }
        guard http.statusCode == 200 else {
            let detail = String(data: data, encoding: .utf8) ?? "HTTP \(http.statusCode)"
            throw DesktopPrivacyFilterError.helperUnavailable(detail)
        }
        return try JSONDecoder().decode(HelperRedactResponse.self, from: data).spans
    }

#if os(macOS)
    private func spawnHelperIfNeeded() throws {
        if ProcessInfo.processInfo.environment["TEALE_OPF_HELPER_URL"] != nil {
            return
        }

        if let process = helperProcess, process.isRunning {
            return
        }

        if let lastAttempt = lastSpawnAttempt, Date().timeIntervalSince(lastAttempt) < 2 {
            return
        }
        lastSpawnAttempt = Date()

        let scriptURL = try locateHelperScript()
        let interpreter = ProcessInfo.processInfo.environment["TEALE_OPF_HELPER_PYTHON"] ?? "python3"

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [
            interpreter,
            scriptURL.path,
            "--host",
            Self.defaultHost,
            "--port",
            String(Self.defaultPort),
            "--device",
            "cpu",
        ]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        helperProcess = process
    }

    private func locateHelperScript() throws -> URL {
        if let override = ProcessInfo.processInfo.environment["TEALE_OPF_HELPER_SCRIPT"] {
            let url = URL(fileURLWithPath: override)
            if FileManager.default.fileExists(atPath: url.path) {
                return url
            }
        }

        for candidate in candidateRoots() {
            let script = candidate.appendingPathComponent("scripts/privacy_filter_helper.py")
            if FileManager.default.fileExists(atPath: script.path) {
                return script
            }
        }

        throw DesktopPrivacyFilterError.helperUnavailable(
            "scripts/privacy_filter_helper.py was not found"
        )
    }

    private func candidateRoots() -> [URL] {
        var roots = [URL]()
        let fileManager = FileManager.default
        if let cwd = fileManager.currentDirectoryPath.removingPercentEncoding {
            roots.append(URL(fileURLWithPath: cwd))
        }
        if let executableURL = Bundle.main.executableURL {
            var current = executableURL.deletingLastPathComponent()
            for _ in 0..<8 {
                roots.append(current)
                current.deleteLastPathComponent()
            }
        }
        return roots
    }
#endif
}
