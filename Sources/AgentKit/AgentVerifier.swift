import Foundation

// MARK: - Agent Verifier

/// Maintains a registry of trusted agent public keys for signature verification.
/// Uses a Trust-On-First-Use (TOFU) model — new agents are registered on first contact,
/// subsequent messages must match the pinned key.
public actor AgentVerifier {
    private var trustedKeys: [String: Data] = [:]  // agentID -> raw public key bytes
    private let storePath: URL

    public init(storePath: URL? = nil) {
        self.storePath = storePath ?? {
            let home = FileManager.default.homeDirectoryForCurrentUser
            return home.appendingPathComponent(".teale/agent_trusted_keys.json")
        }()
    }

    // MARK: - Key Management

    /// Register a trusted public key for an agent
    public func registerKey(agentID: String, publicKey: Data) {
        trustedKeys[agentID] = publicKey
        try? save()
    }

    /// Remove a trusted key
    public func removeKey(agentID: String) {
        trustedKeys.removeValue(forKey: agentID)
        try? save()
    }

    /// Check if an agent's public key is registered
    public func isKnown(agentID: String) -> Bool {
        trustedKeys[agentID] != nil
    }

    /// Get the registered public key for an agent
    public func publicKey(for agentID: String) -> Data? {
        trustedKeys[agentID]
    }

    /// Number of registered agents
    public var registeredCount: Int {
        trustedKeys.count
    }

    // MARK: - Persistence

    public func load() throws {
        guard FileManager.default.fileExists(atPath: storePath.path) else { return }
        let data = try Data(contentsOf: storePath)
        let store = try JSONDecoder().decode(AgentKeyStore.self, from: data)
        trustedKeys = store.keys.reduce(into: [:]) { dict, entry in
            if let keyData = Data(base64Encoded: entry.publicKeyBase64) {
                dict[entry.agentID] = keyData
            }
        }
    }

    public func save() throws {
        let entries = trustedKeys.map { agentID, keyData in
            AgentKeyEntry(agentID: agentID, publicKeyBase64: keyData.base64EncodedString())
        }
        let store = AgentKeyStore(keys: entries)
        let data = try JSONEncoder().encode(store)

        let dir = storePath.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try data.write(to: storePath, options: .atomic)
    }
}

// MARK: - Persistence Types

private struct AgentKeyStore: Codable {
    var keys: [AgentKeyEntry]
}

private struct AgentKeyEntry: Codable {
    var agentID: String
    var publicKeyBase64: String
}
