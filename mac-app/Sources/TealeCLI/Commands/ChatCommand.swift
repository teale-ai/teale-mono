import ArgumentParser
import Foundation

struct Chat: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Send a chat message to the Teale node"
    )

    @Option(name: .long, help: "Port of the running node")
    var port: Int = 11435

    @Option(name: .long, help: "API key for authenticated access")
    var apiKey: String?

    @Option(name: .long, help: "Model to use (defaults to currently loaded model)")
    var model: String?

    @Argument(help: "The prompt to send")
    var prompt: String

    func run() async throws {
        let client = TealeClient(port: port, apiKey: apiKey)

        let bytes: URLSession.AsyncBytes
        do {
            bytes = try await client.chatStream(prompt: prompt, model: model)
        } catch {
            throw CleanExit.message("Cannot connect to Teale node on port \(port). Is it running?")
        }

        // Parse SSE stream and print tokens as they arrive
        for try await line in bytes.lines {
            guard line.hasPrefix("data: ") else { continue }
            let payload = String(line.dropFirst(6))
            if payload == "[DONE]" { break }

            guard let data = payload.data(using: .utf8) else { continue }
            if let chunk = try? JSONDecoder().decode(SSEChunk.self, from: data),
               let content = chunk.choices.first?.delta.content {
                print(content, terminator: "")
                fflush(stdout)
            }
        }

        // Trailing newline
        print("")
    }
}

// Minimal types for decoding SSE chunks — avoids pulling in SharedTypes
private struct SSEChunk: Decodable {
    let choices: [Choice]

    struct Choice: Decodable {
        let delta: Delta
    }

    struct Delta: Decodable {
        let content: String?
    }
}
