import Foundation

// MARK: - Agent Directory Entry

public struct AgentDirectoryEntry: Codable, Sendable, Identifiable, Equatable {
    public var id: String { profile.nodeID }
    public var profile: AgentProfile
    public var lastSeen: Date
    public var rating: Double?
    public var reviewCount: Int
    public var isOnline: Bool

    public init(
        profile: AgentProfile,
        lastSeen: Date = Date(),
        rating: Double? = nil,
        reviewCount: Int = 0,
        isOnline: Bool = true
    ) {
        self.profile = profile
        self.lastSeen = lastSeen
        self.rating = rating
        self.reviewCount = reviewCount
        self.isOnline = isOnline
    }
}

// MARK: - Agent Source

public enum AgentSource: String, Codable, Sendable {
    case local  // this device
    case lan    // discovered via Bonjour/ClusterKit
    case wan    // discovered via WAN relay
}

// MARK: - Agent Directory

public actor AgentDirectory {
    private var entries: [String: AgentDirectoryEntry] = [:]
    private var sources: [String: AgentSource] = [:]
    private let fileURL: URL

    public init(directory: URL? = nil) {
        let dir = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("InferencePool", isDirectory: true)
        self.fileURL = dir.appendingPathComponent("agent_directory.json")
    }

    // MARK: - Persistence

    public func load() throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        let data = try Data(contentsOf: fileURL)
        let decoded = try JSONDecoder().decode([AgentDirectoryEntry].self, from: data)
        entries = Dictionary(uniqueKeysWithValues: decoded.map { ($0.profile.nodeID, $0) })
    }

    public func save() throws {
        let dir = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(Array(entries.values))
        try data.write(to: fileURL, options: .atomic)
    }

    // MARK: - Registration

    public func register(profile: AgentProfile, source: AgentSource = .local) {
        let existing = entries[profile.nodeID]
        let entry = AgentDirectoryEntry(
            profile: profile,
            lastSeen: Date(),
            rating: existing?.rating,
            reviewCount: existing?.reviewCount ?? 0,
            isOnline: true
        )
        entries[profile.nodeID] = entry
        sources[profile.nodeID] = source
    }

    public func update(entry: AgentDirectoryEntry) {
        entries[entry.profile.nodeID] = entry
    }

    public func remove(nodeID: String) {
        entries.removeValue(forKey: nodeID)
        sources.removeValue(forKey: nodeID)
    }

    public func markOffline(nodeID: String) {
        guard var entry = entries[nodeID] else { return }
        entry.isOnline = false
        entries[nodeID] = entry
    }

    public func markOnline(nodeID: String) {
        guard var entry = entries[nodeID] else { return }
        entry.isOnline = true
        entry.lastSeen = Date()
        entries[nodeID] = entry
    }

    // MARK: - Queries

    public func get(nodeID: String) -> AgentDirectoryEntry? {
        entries[nodeID]
    }

    public func allEntries() -> [AgentDirectoryEntry] {
        Array(entries.values).sorted { $0.lastSeen > $1.lastSeen }
    }

    public func search(capability: String? = nil, agentType: AgentType? = nil, query: String? = nil) -> [AgentDirectoryEntry] {
        var results = Array(entries.values)

        if let capability = capability {
            results = results.filter { entry in
                entry.profile.capabilities.contains { $0.id == capability }
            }
        }

        if let agentType = agentType {
            results = results.filter { $0.profile.agentType == agentType }
        }

        if let query = query, !query.isEmpty {
            let lowered = query.lowercased()
            results = results.filter { entry in
                entry.profile.displayName.lowercased().contains(lowered) ||
                entry.profile.bio.lowercased().contains(lowered) ||
                entry.profile.capabilities.contains { $0.name.lowercased().contains(lowered) || $0.description.lowercased().contains(lowered) }
            }
        }

        return results.sorted { $0.lastSeen > $1.lastSeen }
    }

    public func nearbyAgents() -> [AgentDirectoryEntry] {
        entries.values.filter { sources[$0.profile.nodeID] == .lan && $0.isOnline }
            .sorted { $0.lastSeen > $1.lastSeen }
    }

    public func wanAgents() -> [AgentDirectoryEntry] {
        entries.values.filter { sources[$0.profile.nodeID] == .wan && $0.isOnline }
            .sorted { $0.lastSeen > $1.lastSeen }
    }

    public func onlineAgents() -> [AgentDirectoryEntry] {
        entries.values.filter { $0.isOnline }
            .sorted { $0.lastSeen > $1.lastSeen }
    }

    // MARK: - Rating

    public func updateRating(nodeID: String, newRating: Int) {
        guard var entry = entries[nodeID] else { return }
        let currentTotal = (entry.rating ?? 0) * Double(entry.reviewCount)
        entry.reviewCount += 1
        entry.rating = (currentTotal + Double(newRating)) / Double(entry.reviewCount)
        entries[nodeID] = entry
    }
}
