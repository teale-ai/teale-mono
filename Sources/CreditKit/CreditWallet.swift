import Foundation
import SharedTypes

// MARK: - USDCWallet

/// Observable wrapper around USDCLedger for SwiftUI binding.
@Observable
public final class USDCWallet: @unchecked Sendable {
    public private(set) var balance: USDCAmount = .zero
    public private(set) var recentTransactions: [USDCTransaction] = []
    public private(set) var totalEarned: USDCAmount = .zero
    public private(set) var totalSpent: USDCAmount = .zero

    private var ledger: USDCLedger?

    public init(ledger: USDCLedger) {
        self.ledger = ledger
    }

    /// Create a placeholder wallet (no ledger) for use before async init completes
    public static func placeholder() -> USDCWallet {
        let wallet = USDCWallet()
        return wallet
    }

    private init() {
        self.ledger = nil
    }

    /// Record an earning (we served inference for a peer).
    public func recordEarning(tokens: Int, model: ModelDescriptor, peer: String? = nil) async {
        guard let ledger = ledger else { return }
        let amount = InferencePricing.earning(tokenCount: tokens, model: model)
        let transaction = USDCTransaction(
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
        let amount = InferencePricing.cost(tokenCount: tokens, model: model)
        let transaction = USDCTransaction(
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

    public func recordTransferDebit(
        amount: USDCAmount,
        toPeer peerNodeID: String,
        description: String,
        modelID: String? = nil,
        tokenCount: Int? = nil
    ) async {
        guard let ledger = ledger else { return }
        let transaction = USDCTransaction(
            type: .transfer,
            amount: amount,
            description: description,
            peerNodeID: peerNodeID,
            modelID: modelID,
            tokenCount: tokenCount
        )
        await ledger.debit(amount: amount, transaction: transaction)
        await refreshBalance()
    }

    public func recordTransferCredit(
        amount: USDCAmount,
        fromPeer peerNodeID: String,
        description: String,
        modelID: String? = nil,
        tokenCount: Int? = nil
    ) async {
        guard let ledger = ledger else { return }
        let transaction = USDCTransaction(
            type: .transfer,
            amount: amount,
            description: description,
            peerNodeID: peerNodeID,
            modelID: modelID,
            tokenCount: tokenCount
        )
        await ledger.credit(amount: amount, transaction: transaction)
        await refreshBalance()
    }

    public func recordAdjustmentCredit(
        amount: USDCAmount,
        description: String,
        peerNodeID: String? = nil,
        modelID: String? = nil,
        tokenCount: Int? = nil
    ) async {
        guard let ledger = ledger else { return }
        let transaction = USDCTransaction(
            type: .adjustment,
            amount: amount,
            description: description,
            peerNodeID: peerNodeID,
            modelID: modelID,
            tokenCount: tokenCount
        )
        await ledger.credit(amount: amount, transaction: transaction)
        await refreshBalance()
    }

    public func recordAdjustmentDebit(
        amount: USDCAmount,
        description: String,
        peerNodeID: String? = nil,
        modelID: String? = nil,
        tokenCount: Int? = nil
    ) async {
        guard let ledger = ledger else { return }
        let transaction = USDCTransaction(
            type: .adjustment,
            amount: amount,
            description: description,
            peerNodeID: peerNodeID,
            modelID: modelID,
            tokenCount: tokenCount
        )
        await ledger.debit(amount: amount, transaction: transaction)
        await refreshBalance()
    }

    /// Debit wallet for an outgoing P2P USDC transfer. Returns true if balance was sufficient.
    public func sendTransfer(amount: Double, toPeer peerNodeID: String, memo: String? = nil) async -> Bool {
        guard let ledger = ledger else { return false }
        let usdcAmount = USDCAmount(amount)
        let currentBal = await ledger.getBalance().currentBalance
        guard currentBal >= usdcAmount else { return false }

        let desc = memo.map { "Sent \(usdcAmount.description) USDC: \($0)" }
            ?? "Sent \(usdcAmount.description) USDC"
        await recordTransferDebit(amount: usdcAmount, toPeer: peerNodeID, description: desc)
        return true
    }

    /// Credit wallet for an incoming P2P USDC transfer.
    public func receiveTransfer(amount: Double, fromPeer peerNodeID: String, memo: String? = nil) async {
        let usdcAmount = USDCAmount(amount)
        let desc = memo.map { "Received \(usdcAmount.description) USDC: \($0)" }
            ?? "Received \(usdcAmount.description) USDC"
        await recordTransferCredit(amount: usdcAmount, fromPeer: peerNodeID, description: desc)
    }

    /// Get current balance asynchronously (safe from any context).
    public func currentBalance() async -> USDCAmount {
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
