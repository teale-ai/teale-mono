import ArgumentParser
import Foundation
import LocalAPI

struct Agent: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "View agent profile, directory, and conversations",
        subcommands: [Profile.self, Directory.self, Conversations.self]
    )

    @Option(name: .long, help: "Port of the running node")
    var port: Int = 11435

    @Option(name: .long, help: "API key for authenticated access")
    var apiKey: String?
}

extension Agent {
    struct Profile: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Show agent profile")

        @OptionGroup var parent: Agent

        @Flag(name: .long, help: "Output as JSON")
        var json: Bool = false

        func run() async throws {
            let client = TealeClient(port: parent.port, apiKey: parent.apiKey)
            guard let profile = try await client.agentProfile() else {
                print("No agent profile configured.")
                return
            }

            if json {
                let data = try JSONEncoder.prettyPrinting.encode(profile)
                print(String(data: data, encoding: .utf8) ?? "{}")
                return
            }

            print("  Name:         \(profile.displayName)")
            print("  Type:         \(profile.agentType)")
            print("  Node ID:      \(profile.nodeID)")
            if !profile.bio.isEmpty {
                print("  Bio:          \(profile.bio)")
            }
            if !profile.capabilities.isEmpty {
                print("  Capabilities: \(profile.capabilities.joined(separator: ", "))")
            }
        }
    }

    struct Directory: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List agents in directory")

        @OptionGroup var parent: Agent

        @Flag(name: .long, help: "Output as JSON")
        var json: Bool = false

        func run() async throws {
            let client = TealeClient(port: parent.port, apiKey: parent.apiKey)
            let entries = try await client.agentDirectory()

            if json {
                let data = try JSONEncoder.prettyPrinting.encode(entries)
                print(String(data: data, encoding: .utf8) ?? "[]")
                return
            }

            if entries.isEmpty {
                print("No agents discovered.")
                return
            }

            for entry in entries {
                let status = entry.isOnline ? "online" : "offline"
                let rating = entry.rating.map { String(format: "%.1f/5", $0) } ?? "-"
                print("  \(entry.displayName)  [\(entry.agentType)]  \(status)  \(rating)")
                if !entry.capabilities.isEmpty {
                    print("    \(entry.capabilities.prefix(5).joined(separator: ", "))")
                }
            }
        }
    }

    struct Conversations: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List agent conversations")

        @OptionGroup var parent: Agent

        @Flag(name: .long, help: "Output as JSON")
        var json: Bool = false

        func run() async throws {
            let client = TealeClient(port: parent.port, apiKey: parent.apiKey)
            let convos = try await client.agentConversations()

            if json {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                encoder.dateEncodingStrategy = .iso8601
                let data = try encoder.encode(convos)
                print(String(data: data, encoding: .utf8) ?? "[]")
                return
            }

            if convos.isEmpty {
                print("No conversations.")
                return
            }

            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .abbreviated

            for conv in convos {
                let age = formatter.localizedString(for: conv.updatedAt, relativeTo: Date())
                let peers = conv.participants.joined(separator: ", ")
                print("  [\(conv.state)]  \(conv.messageCount) msgs  \(age)")
                print("    ID: \(conv.id)")
                print("    Peers: \(peers)")
                if let last = conv.lastMessage {
                    print("    Last: \(last)")
                }
            }
        }
    }
}

private extension JSONEncoder {
    static var prettyPrinting: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}
