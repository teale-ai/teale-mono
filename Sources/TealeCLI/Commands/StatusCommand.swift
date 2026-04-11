import ArgumentParser
import Foundation
import LocalAPI

struct Status: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Show status of the running Teale node"
    )

    @Option(name: .long, help: "Port of the running node")
    var port: Int = 11435

    @Option(name: .long, help: "API key for authenticated access")
    var apiKey: String?

    @Flag(name: .long, help: "Output as JSON")
    var json: Bool = false

    func run() async throws {
        let client = TealeClient(port: port, apiKey: apiKey)
        let snapshot: RemoteAppSnapshot
        do {
            snapshot = try await client.snapshot()
        } catch {
            throw CleanExit.message("Cannot connect to Teale node on port \(port). Is it running?")
        }

        if json {
            let data = try JSONEncoder.prettyPrinting.encode(snapshot)
            print(String(data: data, encoding: .utf8) ?? "{}")
        } else {
            printStatus(snapshot)
        }
    }

    private func printStatus(_ s: RemoteAppSnapshot) {
        print("Teale Node Status")
        print("  Version:  \(s.appVersion)")
        print("  Engine:   \(s.engineStatus)")
        print("  Server:   \(s.isServerRunning ? "running" : "stopped")")

        if let model = s.loadedModelRepo {
            print("  Model:    \(model)")
        } else {
            print("  Model:    (none loaded)")
        }

        print("  Cluster:  \(s.settings.clusterEnabled ? "enabled" : "disabled")")
        print("  WAN:      \(s.settings.wanEnabled ? "enabled" : "disabled")")
        if let err = s.settings.wanLastError {
            print("  WAN err:  \(err)")
        }
        print("  Storage:  \(String(format: "%.0f", s.settings.maxStorageGB)) GB max")

        let downloaded = s.models.filter({ $0.downloaded }).count
        let total = s.models.count
        print("  Models:   \(downloaded)/\(total) downloaded")
    }
}

private extension JSONEncoder {
    static var prettyPrinting: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}
