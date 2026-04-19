import Foundation

// MARK: - Persisted Ledger Data

struct LedgerData: Codable, Sendable {
    var transactions: [USDCTransaction]
    var currentBalance: USDCAmount
    var totalEarned: USDCAmount
    var totalSpent: USDCAmount

    init() {
        transactions = []
        currentBalance = .zero
        totalEarned = .zero
        totalSpent = .zero
    }
}

// MARK: - USDCLedger

/// Actor that maintains the local USDC ledger with JSON file persistence.
public actor USDCLedger {
    private var data: LedgerData
    private let fileURL: URL
    private var isNewLedger: Bool

    /// Initialize the ledger, loading from disk if available or creating a new one with a welcome bonus.
    public init(directoryURL: URL? = nil) async {
        let directory = directoryURL ?? USDCLedger.defaultDirectory()
        let url = directory.appendingPathComponent("credits.json")
        self.fileURL = url

        // Try to load existing data
        if var loaded = USDCLedger.loadFromDisk(url: url) {
            // Migrate old credit-denominated ledgers to USDC.
            // Old credits used values like 100.0 for the welcome bonus;
            // USDC equivalents are 10,000x smaller (100 credits = $0.01 USDC).
            // Any balance >= 1.0 is definitely old credits (max realistic USDC
            // balance from inference earnings would be far below $1).
            if loaded.currentBalance.value >= 1.0 {
                let factor = 1.0 / 10_000.0
                loaded.currentBalance = USDCAmount(loaded.currentBalance.value * factor)
                loaded.totalEarned = USDCAmount(loaded.totalEarned.value * factor)
                loaded.totalSpent = USDCAmount(loaded.totalSpent.value * factor)
                for i in loaded.transactions.indices {
                    loaded.transactions[i].amount = USDCAmount(loaded.transactions[i].amount.value * factor)
                }
            }
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

        let transaction = USDCTransaction(
            type: .bonus,
            amount: InferencePricing.welcomeBonus,
            description: "Welcome bonus for joining the network"
        )
        data.currentBalance += InferencePricing.welcomeBonus
        data.transactions.append(transaction)
        save()
    }

    /// Credit (add) an amount to the ledger.
    public func credit(amount: USDCAmount, transaction: USDCTransaction) {
        data.currentBalance += amount
        data.totalEarned += amount
        data.transactions.append(transaction)
        save()
    }

    /// Debit (subtract) an amount from the ledger.
    public func debit(amount: USDCAmount, transaction: USDCTransaction) {
        data.currentBalance -= amount
        data.totalSpent += amount
        data.transactions.append(transaction)
        save()
    }

    /// Record a transaction without affecting the balance (e.g. platform fee tracking).
    public func record(transaction: USDCTransaction) {
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
    public func getHistory(limit: Int = 50, offset: Int = 0) -> [USDCTransaction] {
        let sorted = data.transactions.sorted { $0.timestamp > $1.timestamp }
        let start = min(offset, sorted.count)
        let end = min(start + limit, sorted.count)
        return Array(sorted[start..<end])
    }

    /// Get all transactions (for analytics).
    public func getAllTransactions() -> [USDCTransaction] {
        data.transactions
    }

    // MARK: - Persistence

    private static func defaultDirectory() -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("Teale")
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
