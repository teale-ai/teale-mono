import Foundation

// MARK: - API Key

public struct APIKey: Codable, Sendable, Identifiable {
    public var id: UUID
    public var key: String
    public var name: String
    public var createdAt: Date
    public var lastUsedAt: Date?
    public var isActive: Bool

    public init(id: UUID = UUID(), key: String, name: String, createdAt: Date = Date(), lastUsedAt: Date? = nil, isActive: Bool = true) {
        self.id = id
        self.key = key
        self.name = name
        self.createdAt = createdAt
        self.lastUsedAt = lastUsedAt
        self.isActive = isActive
    }

    /// Display-safe truncated key (e.g. "sk-solair-abc1...f9e2")
    public var truncatedKey: String {
        guard key.count > 20 else { return key }
        let prefix = key.prefix(14)
        let suffix = key.suffix(4)
        return "\(prefix)...\(suffix)"
    }
}

// MARK: - API Key Store

public actor APIKeyStore {
    private var keys: [APIKey] = []
    private let fileURL: URL

    public init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        self.fileURL = appSupport.appendingPathComponent("InferencePool/api_keys.json")
        self.keys = Self.loadFromDisk(fileURL)
    }

    /// Generate a new API key
    public func generateKey(name: String) -> APIKey {
        let hex = (0..<32).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
        let key = APIKey(key: "sk-solair-\(hex)", name: name)
        keys.append(key)
        saveToDisk()
        return key
    }

    /// Validate a bearer token against active keys
    public func validate(_ bearerToken: String) -> Bool {
        keys.contains { $0.isActive && $0.key == bearerToken }
    }

    /// Mark a key as recently used
    public func markUsed(key: String) {
        if let idx = keys.firstIndex(where: { $0.key == key }) {
            keys[idx].lastUsedAt = Date()
            saveToDisk()
        }
    }

    /// Revoke a key
    public func revokeKey(id: UUID) {
        if let idx = keys.firstIndex(where: { $0.id == id }) {
            keys[idx].isActive = false
            saveToDisk()
        }
    }

    /// Delete a key permanently
    public func deleteKey(id: UUID) {
        keys.removeAll { $0.id == id }
        saveToDisk()
    }

    /// Get all keys
    public func allKeys() -> [APIKey] {
        keys
    }

    // MARK: - Persistence

    private func saveToDisk() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(keys) else { return }
        let dir = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }

    private static func loadFromDisk(_ url: URL) -> [APIKey] {
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([APIKey].self, from: data)) ?? []
    }
}
