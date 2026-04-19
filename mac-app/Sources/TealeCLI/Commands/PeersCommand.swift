import ArgumentParser
import Foundation
import LocalAPI

struct Peers: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "List connected peers"
    )

    @Option(name: .long, help: "Port of the running node")
    var port: Int = 11435

    @Option(name: .long, help: "API key for authenticated access")
    var apiKey: String?

    @Flag(name: .long, help: "Show only WAN peers")
    var wan: Bool = false

    @Flag(name: .long, help: "Show only LAN cluster peers")
    var cluster: Bool = false

    @Flag(name: .long, help: "Output as JSON")
    var json: Bool = false

    func run() async throws {
        let client = TealeClient(port: port, apiKey: apiKey)
        let peers = try await client.listPeers()

        if json {
            let data = try JSONEncoder.prettyPrinting.encode(peers)
            print(String(data: data, encoding: .utf8) ?? "{}")
            return
        }

        let showWAN = !cluster  // show WAN unless only cluster requested
        let showCluster = !wan  // show cluster unless only WAN requested

        if showCluster && !peers.clusterPeers.isEmpty {
            print("LAN Cluster (\(peers.clusterPeers.count)):")
            for peer in peers.clusterPeers {
                let models = peer.loadedModels.isEmpty ? "(no models)" : peer.loadedModels.joined(separator: ", ")
                print("  \(peer.displayName)  \(models)")
                print("    ID: \(peer.nodeID)")
            }
        }

        if showWAN && !peers.wanPeers.isEmpty {
            if showCluster && !peers.clusterPeers.isEmpty { print() }
            print("WAN P2P (\(peers.wanPeers.count)):")
            for peer in peers.wanPeers {
                let models = peer.loadedModels.isEmpty ? "(no models)" : peer.loadedModels.joined(separator: ", ")
                print("  \(peer.displayName)  \(models)")
                print("    ID: \(peer.nodeID)")
            }
        }

        let total = (showWAN ? peers.wanPeers.count : 0) + (showCluster ? peers.clusterPeers.count : 0)
        if total == 0 {
            print("No connected peers.")
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
