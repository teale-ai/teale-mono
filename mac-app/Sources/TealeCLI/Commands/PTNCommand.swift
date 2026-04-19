import ArgumentParser
import Foundation
import LocalAPI

struct PTN: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ptn",
        abstract: "Manage Private TealeNet memberships",
        subcommands: [List.self, Create.self, Invite.self, IssueCert.self, Join.self, Leave.self, PromoteAdmin.self, ImportCAKey.self, Recover.self]
    )

    @Option(name: .long, help: "Port of the running node")
    var port: Int = 11435

    @Option(name: .long, help: "API key for authenticated access")
    var apiKey: String?
}

extension PTN {
    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List PTN memberships")

        @OptionGroup var parent: PTN

        @Flag(name: .long, help: "Output as JSON")
        var json: Bool = false

        func run() async throws {
            let client = TealeClient(port: parent.port, apiKey: parent.apiKey)
            let ptns = try await client.listPTNs()

            if json {
                let data = try JSONEncoder.prettyPrinting.encode(ptns)
                print(String(data: data, encoding: .utf8) ?? "[]")
                return
            }

            if ptns.isEmpty {
                print("No PTN memberships.")
                return
            }

            for ptn in ptns {
                let creator = ptn.isCreator ? " (creator)" : ""
                print("  \(ptn.ptnName)  [\(ptn.role)]\(creator)")
                print("    ID: \(ptn.ptnID)")
            }
        }
    }

    struct Create: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Create a new Private TealeNet")

        @OptionGroup var parent: PTN

        @Argument(help: "Name for the new PTN")
        var name: String

        func run() async throws {
            let client = TealeClient(port: parent.port, apiKey: parent.apiKey)
            let ptn = try await client.createPTN(name: name)
            print("Created PTN: \(ptn.ptnName)")
            print("  ID:   \(ptn.ptnID)")
            print("  Role: \(ptn.role)")
        }
    }

    struct Invite: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Generate an invite code for a PTN")

        @OptionGroup var parent: PTN

        @Argument(help: "PTN ID to generate invite for")
        var ptnID: String

        func run() async throws {
            let client = TealeClient(port: parent.port, apiKey: parent.apiKey)
            let code = try await client.invitePTN(ptnID: ptnID)
            print(code)
        }
    }

    struct IssueCert: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "issue-cert",
            abstract: "Issue a membership certificate for a node (admin only)"
        )

        @OptionGroup var parent: PTN

        @Argument(help: "PTN ID")
        var ptnID: String

        @Argument(help: "Node ID of the joining device")
        var nodeID: String

        @Option(name: .long, help: "Role to assign (provider, consumer)")
        var role: String = "provider"

        func run() async throws {
            let client = TealeClient(port: parent.port, apiKey: parent.apiKey)
            let certJSON = try await client.issuePTNCert(ptnID: ptnID, nodeID: nodeID, role: role)
            // Print raw cert JSON — the joiner pastes this into `teale ptn join`
            print(certJSON)
        }
    }

    struct Join: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Join a PTN using a certificate")

        @OptionGroup var parent: PTN

        @Argument(help: "Certificate JSON (from `teale ptn issue-cert`)")
        var certData: String

        func run() async throws {
            let client = TealeClient(port: parent.port, apiKey: parent.apiKey)
            let ptn = try await client.joinPTNWithCert(certData: certData)
            print("Joined PTN: \(ptn.ptnName)")
            print("  ID:   \(ptn.ptnID)")
            print("  Role: \(ptn.role)")
        }
    }

    struct Leave: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Leave a Private TealeNet")

        @OptionGroup var parent: PTN

        @Argument(help: "PTN ID to leave")
        var ptnID: String

        func run() async throws {
            let client = TealeClient(port: parent.port, apiKey: parent.apiKey)
            try await client.leavePTN(ptnID: ptnID)
            print("Left PTN \(ptnID)")
        }
    }

    struct PromoteAdmin: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "promote-admin",
            abstract: "Promote a member to admin (transfers CA key)"
        )

        @OptionGroup var parent: PTN

        @Argument(help: "PTN ID")
        var ptnID: String

        @Argument(help: "Node ID to promote")
        var nodeID: String

        func run() async throws {
            let client = TealeClient(port: parent.port, apiKey: parent.apiKey)
            let json = try await client.promoteAdmin(ptnID: ptnID, nodeID: nodeID)
            // Output the promotion payload — target imports this with `teale ptn import-ca-key`
            print(json)
        }
    }

    struct ImportCAKey: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "import-ca-key",
            abstract: "Import a CA key to become admin of a PTN"
        )

        @OptionGroup var parent: PTN

        @Argument(help: "PTN ID")
        var ptnID: String

        @Argument(help: "CA key hex (from `teale ptn promote-admin`)")
        var caKeyHex: String

        func run() async throws {
            let client = TealeClient(port: parent.port, apiKey: parent.apiKey)
            let ptn = try await client.importCAKey(ptnID: ptnID, caKeyHex: caKeyHex)
            print("Imported CA key for PTN: \(ptn.ptnName)")
            print("  Role: \(ptn.role)")
        }
    }

    struct Recover: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Recover a PTN by creating a new CA from existing membership")

        @OptionGroup var parent: PTN

        @Argument(help: "PTN ID to recover")
        var ptnID: String

        func run() async throws {
            let client = TealeClient(port: parent.port, apiKey: parent.apiKey)
            let ptn = try await client.recoverPTN(ptnID: ptnID)
            print("Recovered PTN: \(ptn.ptnName)")
            print("  New ID: \(ptn.ptnID)")
            print("  Role:   \(ptn.role)")
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
