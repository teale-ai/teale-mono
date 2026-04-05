import Foundation
import SharedTypes

// MARK: - CreditWallet

/// Observable wrapper around CreditLedger for SwiftUI binding.
@Observable
public final class CreditWallet: @unchecked Sendable {
    public private(set) var balance: CreditAmount = .zero
    public private(set) var recentTransactions: [CreditTransaction] = []
    public private(set) var totalEarned: CreditAmount = .zero
    public private(set) var totalSpent: CreditAmount = .zero

    private var ledger: CreditLedger?

    public init(ledger: CreditLedger) {
        self.ledger = ledger
    }

    /// Create a placeholder wallet (no ledger) for use before async init completes
    public static func placeholder() -> CreditWallet {
        let wallet = CreditWallet()
        return wallet
    }

    private init() {
        self.ledger = nil
    }

    /// Record an earning (we served inference for a peer).
    public func recordEarning(tokens: Int, model: ModelDescriptor, peer: String? = nil) async {
        guard let ledger = ledger else { return }
        let amount = CreditPricing.earning(tokenCount: tokens, model: model)
        let transaction = CreditTransaction(
            type: .earned,
            amount: amount,
            description: "Served \(tokens) tokens of \(model.name)",
            peerNodeID: peer,
            modelID: model.id,
            tokenCount: tokens
        )
        await ledger.credit(amount: amount, transaction: transaction)
        await refreshBalance()
    }

    /// Record spending (we consumed inference from a peer).
    public func recordSpending(tokens: Int, model: ModelDescriptor, peer: String? = nil) async {
        guard let ledger = ledger else { return }
        let amount = CreditPricing.cost(tokenCount: tokens, model: model)
        let transaction = CreditTransaction(
            type: .spent,
            amount: amount,
            description: "Used \(tokens) tokens of \(model.name)",
            peerNodeID: peer,
            modelID: model.id,
            tokenCount: tokens
        )
        await ledger.debit(amount: amount, transaction: transaction)
        await refreshBalance()
    }

    /// Get current balance asynchronously (safe from any context).
    public func currentBalance() async -> CreditAmount {
        guard let ledger = ledger else { return .zero }
        return await ledger.getBalance().currentBalance
    }

    /// Refresh all published properties from the ledger.
    public func refreshBalance() async {
        guard let ledger = ledger else { return }
        let walletBalance = await ledger.getBalance()
        let recent = await ledger.getHistory(limit: 20)

        self.balance = walletBalance.currentBalance
        self.totalEarned = walletBalance.totalEarned
        self.totalSpent = walletBalance.totalSpent
        self.recentTransactions = recent
    }
}
