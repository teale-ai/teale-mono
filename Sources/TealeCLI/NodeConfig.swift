import Foundation

/// Persistent configuration for the Teale CLI node, stored at ~/.teale/config.json.
struct NodeConfig: Codable {
    /// Whether first-run setup has been completed.
    var setupComplete: Bool = false

    /// Wallet address to auto-forward earnings to (nil = keep on device).
    var forwardEarningsTo: String?

    /// Whether maximize-earnings mode is the default.
    var maximizeEarnings: Bool = false

    // MARK: - Persistence

    static let configDir = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".teale")
    static let configFile = configDir.appending(path: "config.json")

    static func load() -> NodeConfig {
        guard let data = try? Data(contentsOf: configFile),
              let config = try? JSONDecoder().decode(NodeConfig.self, from: data) else {
            return NodeConfig()
        }
        return config
    }

    func save() {
        try? FileManager.default.createDirectory(at: Self.configDir, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(self) {
            try? data.write(to: Self.configFile)
        }
    }
}
