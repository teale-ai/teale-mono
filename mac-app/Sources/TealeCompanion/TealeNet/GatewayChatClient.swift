#if os(iOS)
import Foundation

/// One streaming event from `/v1/chat/completions`.
enum GwChatEvent: Sendable {
    case delta(String)
    case finalTokens(Int)
    case error(String)
}

struct GwChatMessage: Codable, Sendable {
    let role: String
    let content: String
}

/// Streaming (SSE) chat client for `/v1/chat/completions`. Mirrors
/// `android-app/.../GatewayClient.kt` streamChat(). Used by the group
/// @teale mention flow + 1:1 chat.
final class GatewayChatClient: NSObject, @unchecked Sendable {

    private let auth: GatewayAuthClient
    private let baseURL: URL

    init(auth: GatewayAuthClient,
         baseURL: URL = URL(string: "https://gateway.teale.com")!) {
        self.auth = auth
        self.baseURL = baseURL
        super.init()
    }

    /// Streams deltas as an AsyncStream. Caller collects values.
    func streamChat(
        model: String,
        messages: [GwChatMessage],
        temperature: Double = 0.7
    ) -> AsyncStream<GwChatEvent> {
        AsyncStream { continuation in
            let task = Task {
                do {
                    let token = try await auth.bearer()
                    var req = URLRequest(url: baseURL.appendingPathComponent("/v1/chat/completions"))
                    req.httpMethod = "POST"
                    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                    req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                    req.timeoutInterval = 300

                    let body: [String: Any] = [
                        "model": model,
                        "messages": messages.map { ["role": $0.role, "content": $0.content] },
                        "temperature": temperature,
                        "stream": true,
                    ]
                    req.httpBody = try JSONSerialization.data(withJSONObject: body)

                    let (bytes, resp) = try await URLSession.shared.bytes(for: req)
                    guard let http = resp as? HTTPURLResponse,
                          (200..<300).contains(http.statusCode) else {
                        let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
                        continuation.yield(.error("HTTP \(code)"))
                        continuation.finish()
                        return
                    }

                    var tokensOut = 0
                    for try await line in bytes.lines {
                        guard line.hasPrefix("data: ") else { continue }
                        let payload = String(line.dropFirst(6))
                        if payload == "[DONE]" {
                            continuation.yield(.finalTokens(tokensOut))
                            continuation.finish()
                            return
                        }
                        guard let data = payload.data(using: .utf8),
                              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                              let choices = json["choices"] as? [[String: Any]] else { continue }
                        for choice in choices {
                            if let delta = choice["delta"] as? [String: Any],
                               let text = delta["content"] as? String, !text.isEmpty {
                                tokensOut += 1
                                continuation.yield(.delta(text))
                            }
                        }
                    }
                    // Stream ended without [DONE]; still signal final so caller stops.
                    continuation.yield(.finalTokens(tokensOut))
                    continuation.finish()
                } catch {
                    continuation.yield(.error(error.localizedDescription))
                    continuation.finish()
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Convenience: drain the stream and return the concatenated assistant
    /// text. Useful for the group @teale flow where we only post the final
    /// reply as a single group message.
    func completeOnce(model: String, messages: [GwChatMessage]) async throws -> String {
        var buf = ""
        for await ev in streamChat(model: model, messages: messages) {
            switch ev {
            case .delta(let s): buf.append(s)
            case .finalTokens: return buf.trimmingCharacters(in: .whitespacesAndNewlines)
            case .error(let m): throw GatewayAuthError.network(m)
            }
        }
        return buf.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
#endif
