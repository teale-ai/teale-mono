import Foundation

// MARK: - Persisted Ledger Data

struct LedgerData: Codable, Sendable {
    var transactions: [CreditTransaction]
    var currentBalance: CreditAmount
    var totalEarned: CreditAmount
    var totalSpent: CreditAmount

    init() {
        transactions = []
        currentBalance = .zero
        totalEarned = .zero
        totalSpent = .zero
    }
}

// MARK: - CreditLedger

/// Actor that maintains the local credit ledger with JSON file persistence.
public actor CreditLedger {
    private var data: LedgerData
    private let fileURL: URL
    private var isNewLedger: Bool

    /// Initialize the ledger, loading from disk if available or creating a new one with a welcome bonus.
    public init(directoryURL: URL? = nil) async {
        let directory = directoryURL ?? CreditLedger.defaultDirectory()
        let url = directory.appendingPathComponent("credits.json")
        self.fileURL = url

        // Try to load existing data
        if let loaded = CreditLedger.loadFromDisk(url: url) {
            self.data = loaded
            self.isNewLedger = false
        } else {
            self.data = LedgerData()
            self.isNewLedger = true
        }
    }

    /// Apply the welcome bonus if this is a brand-new ledger. Call after init.
    public func applyWelcomeBonusIfNeeded() async {
        guard isNewLedger else { return }
        isNewLedger = false

        let transaction = CreditTransaction(
            type: .bonus,
            amount: CreditPricing.welcomeBonus,
            description: "Welcome bonus for joining the network"
        )
        data.currentBalance += CreditPricing.welcomeBonus
        data.transactions.append(transaction)
        save()
    }

    /// Credit (add) an amount to the ledger.
    public func credit(amount: CreditAmount, transaction: CreditTransaction) {
        data.currentBalance += amount
        data.totalEarned += amount
        data.transactions.append(transaction)
        save()
    }

    /// Debit (subtract) an amount from the ledger.
    public func debit(amount: CreditAmount, transaction: CreditTransaction) {
        data.currentBalance -= amount
        data.totalSpent += amount
        data.transactions.append(transaction)
        save()
    }

    /// Get the current wallet balance summary.
    public func getBalance() -> WalletBalance {
        WalletBalance(
            currentBalance: data.currentBalance,
            totalEarned: data.totalEarned,
            totalSpent: data.totalSpent,
            transactionCount: data.transactions.count
        )
    }

    /// Get transaction history, most recent first.
    public func getHistory(limit: Int = 50, offset: Int = 0) -> [CreditTransaction] {
        let sorted = data.transactions.sorted { $0.timestamp > $1.timestamp }
        let start = min(offset, sorted.count)
        let end = min(start + limit, sorted.count)
        return Array(sorted[start..<end])
    }

    /// Get all transactions (for analytics).
    public func getAllTransactions() -> [CreditTransaction] {
        data.transactions
    }

    // MARK: - Persistence

    private static func defaultDirectory() -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("InferencePool")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func loadFromDisk(url: URL) -> LedgerData? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(LedgerData.self, from: data)
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let jsonData = try? encoder.encode(data) else { return }
        try? jsonData.write(to: fileURL, options: .atomic)
    }
}
