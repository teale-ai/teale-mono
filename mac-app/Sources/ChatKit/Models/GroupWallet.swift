import Foundation

// MARK: - Ledger Entry Kinds

public enum WalletLedgerEntryKind: String, Codable, Sendable {
    /// Member deposits credits into the group wallet (debits their personal wallet).
    case contribution
    /// Group wallet spent credits — typically paying a Teale inference node.
    case debit
    /// Member withdraws credits back to their personal wallet.
    case withdrawal
}

// MARK: - Wallet Ledger Entry

/// A single append-only event in a group wallet's ledger.
/// All devices replicate the same entries via the group's encrypted P2P channel;
/// each device computes balance locally by replaying the log.
public struct WalletLedgerEntry: Codable, Sendable, Identifiable, Equatable {
    public let id: UUID
    /// Which group this entry belongs to.
    public let conversationID: UUID
    /// Who authored this entry. For `.debit`, this is whichever member's message
    /// triggered the inference cost.
    public let authorID: UUID
    public let kind: WalletLedgerEntryKind
    /// Always positive; `kind` determines whether it adds to or subtracts from balance.
    public let amount: Double
    /// Optional human-readable memo: "auto top-up", "inference: llama-3 (1200 tokens)".
    public let memo: String?
    /// For debits, the inference node that was paid. Empty for contributions/withdrawals.
    public let payeeNodeID: String?
    /// For debits driven by inference, the model ID + token count (for accounting).
    public let modelID: String?
    public let tokenCount: Int?
    public let createdAt: Date

    public init(
        id: UUID = UUID(),
        conversationID: UUID,
        authorID: UUID,
        kind: WalletLedgerEntryKind,
        amount: Double,
        memo: String? = nil,
        payeeNodeID: String? = nil,
        modelID: String? = nil,
        tokenCount: Int? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.conversationID = conversationID
        self.authorID = authorID
        self.kind = kind
        self.amount = amount
        self.memo = memo
        self.payeeNodeID = payeeNodeID
        self.modelID = modelID
        self.tokenCount = tokenCount
        self.createdAt = createdAt
    }

    /// Signed contribution to balance: + for contributions, - for debits/withdrawals.
    public var signedAmount: Double {
        switch kind {
        case .contribution: return amount
        case .debit, .withdrawal: return -amount
        }
    }
}

// MARK: - Group Wallet (persisted ledger)

public struct GroupWallet: Codable, Sendable, Equatable {
    public var conversationID: UUID
    public var entries: [WalletLedgerEntry]

    public init(conversationID: UUID, entries: [WalletLedgerEntry] = []) {
        self.conversationID = conversationID
        self.entries = entries
    }

    /// Balance computed by replaying the log. Never mutated directly.
    public var balance: Double {
        entries.reduce(0) { $0 + $1.signedAmount }
    }

    /// Sum contributed by a specific member across all time. Used for UI split views.
    public func contributed(by userID: UUID) -> Double {
        entries
            .filter { $0.kind == .contribution && $0.authorID == userID }
            .reduce(0) { $0 + $1.amount }
    }
}

// MARK: - Multi-Sig Policy

/// Per-group spending rules enforced locally by each device before it accepts
/// a `.debit` ledger entry. "Multi-sig" here is a social-rule check, not a
/// cryptographic one — we don't need on-chain settlement.
public struct GroupWalletPolicy: Codable, Sendable, Equatable {
    /// Debits up to this amount are auto-accepted. Above, an admin confirmation is required.
    public var autoApproveDebitLimit: Double
    /// Max amount any single member can auto-contribute via auto-top-up per day.
    public var dailyAutoTopUpCap: Double

    public init(autoApproveDebitLimit: Double = 0.50, dailyAutoTopUpCap: Double = 10.0) {
        self.autoApproveDebitLimit = autoApproveDebitLimit
        self.dailyAutoTopUpCap = dailyAutoTopUpCap
    }

    public static let `default` = GroupWalletPolicy()
}

// MARK: - Auto Top-Up Rule (local, per-user per-group)

/// A rule the local user set to auto-contribute when the group wallet runs low.
/// Stored only on the user's device — other members can't see it, and it can't
/// be triggered on the user's behalf by anyone else.
public struct AutoTopUpRule: Codable, Sendable, Identifiable, Equatable {
    public var id: UUID
    public var conversationID: UUID
    /// Fire a top-up when the group balance dips below this.
    public var thresholdAmount: Double
    /// Contribute this amount when the threshold is breached.
    public var topUpAmount: Double
    /// Daily cap — don't contribute more than this from autotop-up per day.
    public var dailyCap: Double
    public var enabled: Bool
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        conversationID: UUID,
        thresholdAmount: Double = 1.0,
        topUpAmount: Double = 5.0,
        dailyCap: Double = 20.0,
        enabled: Bool = true,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.conversationID = conversationID
        self.thresholdAmount = thresholdAmount
        self.topUpAmount = topUpAmount
        self.dailyCap = dailyCap
        self.enabled = enabled
        self.createdAt = createdAt
    }
}
