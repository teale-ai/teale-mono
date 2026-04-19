import Foundation

// MARK: - Group Wallet Store

/// Device-local replica of each group wallet's ledger. Entries also arrive
/// via the encrypted P2P channel as `.walletEntry` messages, which the
/// `ChatService` dispatches here.
///
/// File: `~/Library/Application Support/Teale/wallets/{conversationID}.json`.
@MainActor
@Observable
public final class GroupWalletStore {
    private var walletsByConversation: [UUID: GroupWallet] = [:]
    private var policiesByConversation: [UUID: GroupWalletPolicy] = [:]
    /// Local auto-top-up rules keyed by conversationID. Never synced.
    private var autoTopUpRules: [UUID: AutoTopUpRule] = [:]
    /// Records how much the local user has auto-contributed today (per group) so
    /// we can honor the `dailyCap`.
    private var todayAutoContributions: [UUID: Double] = [:]
    private var todayAutoContributionDate: Date = Calendar.current.startOfDay(for: Date())

    public init() {
        loadAutoTopUpRules()
    }

    // MARK: - Read

    public func wallet(for conversationID: UUID) -> GroupWallet {
        if let cached = walletsByConversation[conversationID] {
            return cached
        }
        let loaded = loadWallet(conversationID: conversationID) ?? GroupWallet(conversationID: conversationID)
        walletsByConversation[conversationID] = loaded
        return loaded
    }

    public func balance(for conversationID: UUID) -> Double {
        wallet(for: conversationID).balance
    }

    public func entries(for conversationID: UUID) -> [WalletLedgerEntry] {
        wallet(for: conversationID).entries
    }

    public func policy(for conversationID: UUID) -> GroupWalletPolicy {
        policiesByConversation[conversationID] ?? .default
    }

    public func updatePolicy(_ policy: GroupWalletPolicy, for conversationID: UUID) {
        policiesByConversation[conversationID] = policy
    }

    // MARK: - Append entries

    /// Append a new entry authored locally. Caller is responsible for
    /// broadcasting the entry via P2P — this store only persists local state.
    @discardableResult
    public func append(_ entry: WalletLedgerEntry) -> GroupWallet {
        var wallet = wallet(for: entry.conversationID)
        // Dedup — entries might arrive via P2P before the author's own append.
        guard !wallet.entries.contains(where: { $0.id == entry.id }) else { return wallet }
        wallet.entries.append(entry)
        walletsByConversation[entry.conversationID] = wallet
        save(wallet)
        return wallet
    }

    // MARK: - Auto top-up

    public func autoTopUpRule(for conversationID: UUID) -> AutoTopUpRule? {
        autoTopUpRules[conversationID]
    }

    public func setAutoTopUpRule(_ rule: AutoTopUpRule) {
        autoTopUpRules[rule.conversationID] = rule
        saveAutoTopUpRules()
    }

    public func removeAutoTopUpRule(for conversationID: UUID) {
        autoTopUpRules.removeValue(forKey: conversationID)
        saveAutoTopUpRules()
    }

    /// Record that `amount` was just auto-contributed to this group and return
    /// the day's total (so callers can check the cap).
    public func recordAutoContribution(amount: Double, conversationID: UUID) -> Double {
        rollDayIfNeeded()
        let total = (todayAutoContributions[conversationID] ?? 0) + amount
        todayAutoContributions[conversationID] = total
        return total
    }

    public func autoContributedToday(for conversationID: UUID) -> Double {
        rollDayIfNeeded()
        return todayAutoContributions[conversationID] ?? 0
    }

    private func rollDayIfNeeded() {
        let today = Calendar.current.startOfDay(for: Date())
        if today != todayAutoContributionDate {
            todayAutoContributions.removeAll()
            todayAutoContributionDate = today
        }
    }

    // MARK: - Persistence

    private static let directory: URL = {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return support.appendingPathComponent("Teale/wallets", isDirectory: true)
    }()

    private static var autoTopUpURL: URL {
        directory.appendingPathComponent("auto_topup.json")
    }

    private func walletURL(for conversationID: UUID) -> URL {
        Self.directory.appendingPathComponent("\(conversationID.uuidString).json")
    }

    private func loadWallet(conversationID: UUID) -> GroupWallet? {
        guard let data = try? Data(contentsOf: walletURL(for: conversationID)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(GroupWallet.self, from: data)
    }

    private func save(_ wallet: GroupWallet) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        guard let data = try? encoder.encode(wallet) else { return }
        try? data.write(to: walletURL(for: wallet.conversationID), options: .atomic)
    }

    private func loadAutoTopUpRules() {
        guard let data = try? Data(contentsOf: Self.autoTopUpURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let rules = try? decoder.decode([AutoTopUpRule].self, from: data) else { return }
        for rule in rules {
            autoTopUpRules[rule.conversationID] = rule
        }
    }

    private func saveAutoTopUpRules() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        let rules = Array(autoTopUpRules.values)
        guard let data = try? encoder.encode(rules) else { return }
        try? data.write(to: Self.autoTopUpURL, options: .atomic)
    }
}
