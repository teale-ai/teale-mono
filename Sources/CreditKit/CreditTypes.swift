import Foundation
import SharedTypes

// MARK: - CreditAmount

/// A wrapper around Double representing a credit balance or amount.
public struct CreditAmount: Codable, Sendable, Hashable, CustomStringConvertible {
    public var value: Double

    public init(_ value: Double) {
        self.value = value
    }

    public var description: String {
        String(format: "%.2f credits", value)
    }

    public static func + (lhs: CreditAmount, rhs: CreditAmount) -> CreditAmount {
        CreditAmount(lhs.value + rhs.value)
    }

    public static func - (lhs: CreditAmount, rhs: CreditAmount) -> CreditAmount {
        CreditAmount(lhs.value - rhs.value)
    }

    public static func * (lhs: CreditAmount, rhs: Double) -> CreditAmount {
        CreditAmount(lhs.value * rhs)
    }

    public static func += (lhs: inout CreditAmount, rhs: CreditAmount) {
        lhs.value += rhs.value
    }

    public static func -= (lhs: inout CreditAmount, rhs: CreditAmount) {
        lhs.value -= rhs.value
    }

    public static let zero = CreditAmount(0)
}

extension CreditAmount: Comparable {
    public static func < (lhs: CreditAmount, rhs: CreditAmount) -> Bool {
        lhs.value < rhs.value
    }
}

// MARK: - TransactionType

public enum TransactionType: String, Codable, Sendable {
    case earned
    case spent
    case bonus
    case adjustment
    case transfer
    case deposit      // USDC deposit converted to credits
    case withdrawal   // Credits converted to USDC withdrawal
}

// MARK: - CreditTransaction

public struct CreditTransaction: Codable, Sendable, Identifiable {
    public var id: UUID
    public var timestamp: Date
    public var type: TransactionType
    public var amount: CreditAmount
    public var description: String
    public var peerNodeID: String?
    public var modelID: String?
    public var tokenCount: Int?
    public var txSignature: String?  // Solana transaction signature for on-chain operations

    public init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        type: TransactionType,
        amount: CreditAmount,
        description: String,
        peerNodeID: String? = nil,
        modelID: String? = nil,
        tokenCount: Int? = nil,
        txSignature: String? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.type = type
        self.amount = amount
        self.description = description
        self.peerNodeID = peerNodeID
        self.modelID = modelID
        self.tokenCount = tokenCount
        self.txSignature = txSignature
    }
}

// MARK: - CreditPricing

public struct CreditPricing: Sendable {

    /// Credits per 1K tokens based on model parameter count string (e.g. "1B", "8B").
    public static func modelComplexityFactor(parameterCount: String) -> Double {
        let normalized = parameterCount.uppercased().trimmingCharacters(in: .whitespaces)
        // Extract the numeric portion before 'B'
        if let bIndex = normalized.firstIndex(of: "B"),
           let value = Double(normalized[normalized.startIndex..<bIndex]) {
            // Scale: value * 0.1 credits per 1K tokens
            return value * 0.1
        }
        // Fallback for unknown formats
        return 1.0
    }

    /// Multiplier based on quantization level.
    public static func quantizationMultiplier(_ quantization: QuantizationType) -> Double {
        switch quantization {
        case .q4: return 1.0
        case .q8: return 1.5
        case .fp16: return 2.0
        }
    }

    /// Calculate the credit cost for a given number of tokens on a specific model.
    public static func cost(tokenCount: Int, parameterCount: String, quantization: QuantizationType) -> CreditAmount {
        let complexity = modelComplexityFactor(parameterCount: parameterCount)
        let quantMult = quantizationMultiplier(quantization)
        let cost = (Double(tokenCount) / 1000.0) * complexity * quantMult
        return CreditAmount(cost)
    }

    /// Calculate the credit cost using a ModelDescriptor.
    public static func cost(tokenCount: Int, model: ModelDescriptor) -> CreditAmount {
        cost(tokenCount: tokenCount, parameterCount: model.parameterCount, quantization: model.quantization)
    }

    /// The earning rate is 95% of the cost (5% network fee).
    public static func earning(tokenCount: Int, parameterCount: String, quantization: QuantizationType) -> CreditAmount {
        let totalCost = cost(tokenCount: tokenCount, parameterCount: parameterCount, quantization: quantization)
        return totalCost * 0.95
    }

    /// The earning rate using a ModelDescriptor.
    public static func earning(tokenCount: Int, model: ModelDescriptor) -> CreditAmount {
        earning(tokenCount: tokenCount, parameterCount: model.parameterCount, quantization: model.quantization)
    }

    /// The welcome bonus for new users.
    public static let welcomeBonus = CreditAmount(100.0)

    /// Minimum balance required to make remote inference requests.
    public static let minimumBalanceForRemote = CreditAmount(1.0)
}

// MARK: - WalletBalance

public struct WalletBalance: Codable, Sendable {
    public var currentBalance: CreditAmount
    public var totalEarned: CreditAmount
    public var totalSpent: CreditAmount
    public var transactionCount: Int

    public init(
        currentBalance: CreditAmount = .zero,
        totalEarned: CreditAmount = .zero,
        totalSpent: CreditAmount = .zero,
        transactionCount: Int = 0
    ) {
        self.currentBalance = currentBalance
        self.totalEarned = totalEarned
        self.totalSpent = totalSpent
        self.transactionCount = transactionCount
    }
}
