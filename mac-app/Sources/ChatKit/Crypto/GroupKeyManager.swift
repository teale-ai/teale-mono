import Foundation

// MARK: - Group Key Manager

/// Manages sender keys for E2E encrypted group chats.
/// Each group member has a unique sender key. All members hold
/// each other's keys so they can decrypt any member's messages.
///
/// Keys are persisted to ~/Library/Application Support/Teale/group-keys/
public actor GroupKeyManager {
    private var keysByGroup: [UUID: [String: SenderKey]] = [:] // groupID -> [keyID: SenderKey]
    private var myKeysByGroup: [UUID: SenderKey] = [:]          // groupID -> my current sender key
    private let memberID: UUID

    private static let storageDir: URL = {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("Teale/group-keys", isDirectory: true)
    }()

    public init(memberID: UUID) {
        self.memberID = memberID
        loadFromDisk()
    }

    // MARK: - Key Generation

    /// Get or create the local user's sender key for a group.
    public func mySenderKey(for groupID: UUID) -> SenderKey {
        if let existing = myKeysByGroup[groupID], !existing.expired {
            return existing
        }

        let key = SenderKey.generate(memberID: memberID)
        myKeysByGroup[groupID] = key
        store(key: key, for: groupID)
        saveToDisk()
        return key
    }

    /// Rotate the local user's sender key (call when a member leaves the group).
    public func rotateSenderKey(for groupID: UUID) -> SenderKey {
        // Expire old key
        if var old = myKeysByGroup[groupID] {
            old.expired = true
            store(key: old, for: groupID)
        }

        let newKey = SenderKey.generate(memberID: memberID)
        myKeysByGroup[groupID] = newKey
        store(key: newKey, for: groupID)
        saveToDisk()
        return newKey
    }

    // MARK: - Key Storage

    /// Store a sender key received from another group member.
    public func storeSenderKey(_ key: SenderKey, for groupID: UUID) {
        store(key: key, for: groupID)
        saveToDisk()
    }

    /// Look up a sender key by its ID for decryption.
    public func senderKey(for groupID: UUID, keyID: String) -> SenderKey? {
        keysByGroup[groupID]?[keyID]
    }

    /// Get all active (non-expired) sender keys for a group.
    public func activeSenderKeys(for groupID: UUID) -> [SenderKey] {
        guard let groupKeys = keysByGroup[groupID] else { return [] }
        return Array(groupKeys.values).filter { !$0.expired }
    }

    /// Remove all keys for a group (when leaving).
    public func removeKeys(for groupID: UUID) {
        keysByGroup.removeValue(forKey: groupID)
        myKeysByGroup.removeValue(forKey: groupID)
        saveToDisk()
    }

    // MARK: - Private

    private func store(key: SenderKey, for groupID: UUID) {
        var groupKeys = keysByGroup[groupID] ?? [:]
        groupKeys[key.keyID] = key
        keysByGroup[groupID] = groupKeys
    }

    // MARK: - Persistence

    private func saveToDisk() {
        let dir = Self.storageDir
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let state = PersistedState(keysByGroup: keysByGroup, myKeysByGroup: myKeysByGroup)
        if let data = try? JSONEncoder().encode(state) {
            let file = dir.appendingPathComponent("keys.json")
            try? data.write(to: file, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        }
    }

    private func loadFromDisk() {
        let file = Self.storageDir.appendingPathComponent("keys.json")
        guard let data = try? Data(contentsOf: file),
              let state = try? JSONDecoder().decode(PersistedState.self, from: data) else {
            return
        }
        keysByGroup = state.keysByGroup
        myKeysByGroup = state.myKeysByGroup
    }

    private struct PersistedState: Codable {
        var keysByGroup: [UUID: [String: SenderKey]]
        var myKeysByGroup: [UUID: SenderKey]
    }
}
