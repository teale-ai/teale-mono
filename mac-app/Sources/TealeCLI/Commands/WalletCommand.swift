import ArgumentParser
import Foundation
import LocalAPI

struct Wallet: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Manage wallet and credits",
        subcommands: [Balance.self, Transactions.self, Send.self, Solana.self]
    )

    @Option(name: .long, help: "Port of the running node")
    var port: Int = 11435

    @Option(name: .long, help: "API key for authenticated access")
    var apiKey: String?
}

extension Wallet {
    struct Balance: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Show credit balance")

        @OptionGroup var parent: Wallet

        @Flag(name: .long, help: "Output as JSON")
        var json: Bool = false

        func run() async throws {
            let client = TealeClient(port: parent.port, apiKey: parent.apiKey)
            let w = try await client.walletBalance()

            if json {
                let data = try JSONEncoder.prettyPrinting.encode(w)
                print(String(data: data, encoding: .utf8) ?? "{}")
                return
            }

            print("  Device ID:     \(w.deviceID)")
            print("  Balance:       $\(String(format: "%.6f", w.balance)) USDC")
            print("  Total earned:  $\(String(format: "%.6f", w.totalEarned)) USDC")
            print("  Total spent:   $\(String(format: "%.6f", w.totalSpent)) USDC")
        }
    }

    struct Transactions: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List recent transactions")

        @OptionGroup var parent: Wallet

        @Option(name: .long, help: "Maximum number of transactions")
        var limit: Int = 20

        @Flag(name: .long, help: "Output as JSON")
        var json: Bool = false

        func run() async throws {
            let client = TealeClient(port: parent.port, apiKey: parent.apiKey)
            let txns = try await client.walletTransactions(limit: limit)

            if json {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                encoder.dateEncodingStrategy = .iso8601
                let data = try encoder.encode(txns)
                print(String(data: data, encoding: .utf8) ?? "[]")
                return
            }

            if txns.isEmpty {
                print("No transactions.")
                return
            }

            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .abbreviated

            for tx in txns {
                let sign = ["earned", "bonus", "transfer"].contains(where: { tx.type.contains($0) }) ? "+" : "-"
                let age = formatter.localizedString(for: tx.timestamp, relativeTo: Date())
                print("  \(sign)$\(String(format: "%.6f", tx.amount))  \(tx.type)  \(age)")
                print("    \(tx.description)")
            }
        }
    }

    struct Send: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Send credits to a peer")

        @OptionGroup var parent: Wallet

        @Argument(help: "Amount in USDC")
        var amount: Double

        @Argument(help: "Peer UUID")
        var peerID: String

        @Option(name: .long, help: "Optional memo")
        var memo: String?

        func run() async throws {
            let client = TealeClient(port: parent.port, apiKey: parent.apiKey)
            let success = try await client.walletSend(amount: amount, peerID: peerID, memo: memo)
            if success {
                print("Sent $\(String(format: "%.6f", amount)) USDC to \(peerID)")
            } else {
                throw CleanExit.message("Transfer failed. Insufficient balance or peer not found.")
            }
        }
    }

    struct Solana: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Show Solana wallet status")

        @OptionGroup var parent: Wallet

        @Flag(name: .long, help: "Output as JSON")
        var json: Bool = false

        func run() async throws {
            let client = TealeClient(port: parent.port, apiKey: parent.apiKey)
            let s = try await client.solanaStatus()

            if json {
                let data = try JSONEncoder.prettyPrinting.encode(s)
                print(String(data: data, encoding: .utf8) ?? "{}")
                return
            }

            print("  Enabled:  \(s.enabled)")
            print("  Network:  \(s.network)")
            if s.enabled {
                print("  Address:  \(s.address)")
                print("  Balance:  \(s.usdcBalance) USDC")
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
