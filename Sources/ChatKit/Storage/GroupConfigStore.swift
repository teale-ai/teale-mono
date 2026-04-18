import Foundation
import CryptoKit

// MARK: - Group Config Store

/// Versioned, admin-signed group configuration (MD files) replicated to all devices.
///
/// Stored at `~/.teale/groups/{groupID}/config/`.
/// Only the group admin can update; all members verify the admin's Ed25519 signature.
public actor GroupConfigStore {
    private let baseDir: URL

    private static let appDir: URL = {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("Teale/groups", isDirectory: true)
    }()

    public init() {
        self.baseDir = Self.appDir
    }

    // MARK: - Read

    /// Load the current config for a group.
    public func loadConfig(groupID: UUID) -> GroupConfig? {
        let file = configFile(for: groupID)
        guard let data = try? Data(contentsOf: file) else { return nil }
        return try? JSONDecoder().decode(GroupConfig.self, from: data)
    }

    /// Read a specific MD file from the group config.
    public func readFile(_ name: String, groupID: UUID) -> String? {
        loadConfig(groupID: groupID)?.files[name]
    }

    /// Get the system prompt (agent.md) for a group's AI agent.
    public func agentPrompt(groupID: UUID) -> String? {
        readFile("agent.md", groupID: groupID)
    }

    // MARK: - Write (admin only)

    /// Update the group config and sign it. Returns the new config for distribution.
    public func updateConfig(
        groupID: UUID,
        files: [String: String],
        adminSigningKey: Curve25519.Signing.PrivateKey
    ) -> GroupConfig {
        let existing = loadConfig(groupID: groupID)
        let newVersion = (existing?.version ?? 0) + 1

        var config = GroupConfig(
            groupID: groupID,
            version: newVersion,
            files: files,
            updatedAt: Date(),
            adminSignature: Data()
        )

        // Sign the config content
        let signingData = config.signingData
        config.adminSignature = (try? adminSigningKey.signature(for: signingData)) ?? Data()

        saveConfig(config, groupID: groupID)
        return config
    }

    // MARK: - Receive (from peer)

    /// Accept a config update from a peer. Verifies admin signature and version.
    public func receiveConfig(
        _ config: GroupConfig,
        adminVerifyKey: Curve25519.Signing.PublicKey
    ) -> Bool {
        // Verify signature
        let signingData = config.signingData
        guard adminVerifyKey.isValidSignature(config.adminSignature, for: signingData) else {
            return false
        }

        // Accept only if version is newer
        let existing = loadConfig(groupID: config.groupID)
        guard config.version > (existing?.version ?? 0) else {
            return false
        }

        saveConfig(config, groupID: config.groupID)
        return true
    }

    // MARK: - Private

    private func saveConfig(_ config: GroupConfig, groupID: UUID) {
        let dir = configDir(for: groupID)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .prettyPrinted
        guard let data = try? encoder.encode(config) else { return }
        try? data.write(to: configFile(for: groupID), options: .atomic)
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: configFile(for: groupID).path
        )
    }

    private func configDir(for groupID: UUID) -> URL {
        baseDir.appendingPathComponent(groupID.uuidString, isDirectory: true)
            .appendingPathComponent("config", isDirectory: true)
    }

    private func configFile(for groupID: UUID) -> URL {
        configDir(for: groupID).appendingPathComponent("config.json")
    }
}

// MARK: - Group Config

/// Versioned, signed group configuration containing MD files.
public struct GroupConfig: Codable, Sendable {
    public let groupID: UUID
    public let version: Int
    /// MD file contents keyed by filename (e.g. "agent.md", "knowledge.md", "tools.md")
    public let files: [String: String]
    public let updatedAt: Date
    /// Ed25519 signature from the group admin over (groupID || version || files hash)
    public var adminSignature: Data

    /// The data that is signed by the admin.
    public var signingData: Data {
        var data = Data()
        data.append(Data(groupID.uuidString.utf8))
        withUnsafeBytes(of: version.littleEndian) { data.append(contentsOf: $0) }
        // Hash the file contents for a stable signature input
        let filesJSON = (try? JSONEncoder().encode(files)) ?? Data()
        let hash = SHA256.hash(data: filesJSON)
        data.append(contentsOf: hash)
        return data
    }

    enum CodingKeys: String, CodingKey {
        case groupID = "group_id"
        case version, files
        case updatedAt = "updated_at"
        case adminSignature = "admin_signature"
    }
}

// MARK: - Config Sync Payload

public struct GroupConfigUpdatePayload: Codable, Sendable {
    public let config: GroupConfig
    public let adminVerifyKey: Data // Ed25519 public key (32 bytes)

    public init(config: GroupConfig, adminVerifyKey: Data) {
        self.config = config
        self.adminVerifyKey = adminVerifyKey
    }
}
