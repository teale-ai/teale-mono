import ArgumentParser
import Foundation
import LocalAPI

struct APIKeys: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "apikey",
        abstract: "Manage API keys for the Teale HTTP server",
        subcommands: [List.self, Generate.self, Revoke.self]
    )

    @Option(name: .long, help: "Port of the running node")
    var port: Int = 11435

    @Option(name: .long, help: "API key for authenticated access")
    var apiKey: String?
}

extension APIKeys {
    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List API keys")

        @OptionGroup var parent: APIKeys

        @Flag(name: .long, help: "Output as JSON")
        var json: Bool = false

        func run() async throws {
            let client = TealeClient(port: parent.port, apiKey: parent.apiKey)
            let keys = try await client.listAPIKeys()

            if json {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                encoder.dateEncodingStrategy = .iso8601
                let data = try encoder.encode(keys)
                print(String(data: data, encoding: .utf8) ?? "[]")
                return
            }

            if keys.isEmpty {
                print("No API keys.")
                return
            }

            for key in keys {
                let status = key.isActive ? "active" : "revoked"
                print("  \(key.name)  \(key.key)  [\(status)]")
                print("    ID: \(key.id)")
            }
        }
    }

    struct Generate: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Generate a new API key")

        @OptionGroup var parent: APIKeys

        @Argument(help: "Name for the new key")
        var name: String

        func run() async throws {
            let client = TealeClient(port: parent.port, apiKey: parent.apiKey)
            let key = try await client.generateAPIKey(name: name)
            print(key.key)
        }
    }

    struct Revoke: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Revoke an API key")

        @OptionGroup var parent: APIKeys

        @Argument(help: "UUID of the key to revoke")
        var id: String

        func run() async throws {
            guard let uuid = UUID(uuidString: id) else {
                throw CleanExit.message("Invalid UUID: \(id)")
            }
            let client = TealeClient(port: parent.port, apiKey: parent.apiKey)
            try await client.revokeAPIKey(id: uuid)
            print("Key revoked.")
        }
    }
}
