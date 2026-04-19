import Foundation

// MARK: - PTN Store

/// File-based persistence for PTN memberships.
/// Directory: ~/Library/Application Support/Teale/ptn/
/// Files:
///   {ptnID}.json   — PTNMembershipInfo (public data + certificate)
///   {ptnID}.ca.key — CA private key raw bytes (0600 perms, only on creator)
public actor PTNStore {
    private let baseDirectory: URL

    public init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        self.baseDirectory = appSupport.appendingPathComponent("Teale/ptn")
    }

    private func ensureDirectory() throws {
        try FileManager.default.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
    }

    // MARK: - Membership Persistence

    public func loadAll() throws -> [PTNMembershipInfo] {
        try ensureDirectory()
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: baseDirectory, includingPropertiesForKeys: nil) else {
            return []
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        var memberships: [PTNMembershipInfo] = []
        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                  let membership = try? decoder.decode(PTNMembershipInfo.self, from: data) else {
                continue
            }
            memberships.append(membership)
        }
        return memberships
    }

    public func save(_ membership: PTNMembershipInfo) throws {
        try ensureDirectory()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(membership)
        let url = baseDirectory.appendingPathComponent("\(membership.ptnID).json")
        try data.write(to: url, options: .atomic)
    }

    public func delete(ptnID: String) throws {
        let membershipURL = baseDirectory.appendingPathComponent("\(ptnID).json")
        let caKeyURL = baseDirectory.appendingPathComponent("\(ptnID).ca.key")
        let fm = FileManager.default
        try? fm.removeItem(at: membershipURL)
        try? fm.removeItem(at: caKeyURL)
    }

    // MARK: - CA Key Persistence

    public func saveCAKey(_ keyData: Data, ptnID: String) throws {
        try ensureDirectory()
        let url = baseDirectory.appendingPathComponent("\(ptnID).ca.key")
        try keyData.write(to: url, options: .atomic)
        // Restrict permissions to owner-only (0600)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path
        )
    }

    public func loadCAKey(ptnID: String) throws -> Data? {
        let url = baseDirectory.appendingPathComponent("\(ptnID).ca.key")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try Data(contentsOf: url)
    }

    public func deleteCAKey(ptnID: String) throws {
        let url = baseDirectory.appendingPathComponent("\(ptnID).ca.key")
        try? FileManager.default.removeItem(at: url)
    }
}
