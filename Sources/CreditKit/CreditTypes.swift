import Foundation
import SharedTypes

// MARK: - USDCAmount

/// A wrapper around Double representing a USDC balance or amount.
public struct USDCAmount: Codable, Sendable, Hashable, CustomStringConvertible {
    public var value: Double

    public init(_ value: Double) {
        self.value = value
    }

    public var description: String {
        if value == 0 { return "$0.000000" }
        if value >= 1.0 { return String(format: "$%.2f", value) }
        // Always show 6 decimals for sub-dollar amounts so users can see micro-earnings
        return String(format: "$%.6f", value)
    }

    public static func + (lhs: USDCAmount, rhs: USDCAmount) -> USDCAmount {
        USDCAmount(lhs.value + rhs.value)
    }

    public static func - (lhs: USDCAmount, rhs: USDCAmount) -> USDCAmount {
        USDCAmount(lhs.value - rhs.value)
    }

    public static func * (lhs: USDCAmount, rhs: Double) -> USDCAmount {
        USDCAmount(lhs.value * rhs)
    }

    public static func += (lhs: inout USDCAmount, rhs: USDCAmount) {
        lhs.value += rhs.value
    }

    public static func -= (lhs: inout USDCAmount, rhs: USDCAmount) {
        lhs.value -= rhs.value
    }

    public static let zero = USDCAmount(0)
}

extension USDCAmount: Comparable {
    public static func < (lhs: USDCAmount, rhs: USDCAmount) -> Bool {
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
    case sdkEarning    // Earned via TealeSDK contribution (attributed to developer wallet)
}

// MARK: - USDCTransaction

public struct USDCTransaction: Codable, Sendable, Identifiable {
    public var id: UUID
    public var timestamp: Date
    public var type: TransactionType
    public var amount: USDCAmount
    public var description: String
    public var peerNodeID: String?
    public var modelID: String?
    public var tokenCount: Int?
    public var txSignature: String?  // Solana transaction signature for on-chain operations

    public init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        type: TransactionType,
        amount: USDCAmount,
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

// MARK: - InferencePricing

public struct InferencePricing: Sendable {

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

    /// Calculate the USDC cost for a given number of tokens on a specific model.
    public static func cost(tokenCount: Int, parameterCount: String, quantization: QuantizationType) -> USDCAmount {
        let complexity = modelComplexityFactor(parameterCount: parameterCount)
        let quantMult = quantizationMultiplier(quantization)
        let cost = (Double(tokenCount) / 1000.0) * complexity * quantMult / 10_000.0
        return USDCAmount(cost)
    }

    /// Calculate the USDC cost using a ModelDescriptor.
    public static func cost(tokenCount: Int, model: ModelDescriptor) -> USDCAmount {
        cost(tokenCount: tokenCount, parameterCount: model.parameterCount, quantization: model.quantization)
    }

    /// The earning rate is 95% of the cost (5% network fee).
    public static func earning(tokenCount: Int, parameterCount: String, quantization: QuantizationType) -> USDCAmount {
        let totalCost = cost(tokenCount: tokenCount, parameterCount: parameterCount, quantization: quantization)
        return totalCost * 0.95
    }

    /// The earning rate using a ModelDescriptor.
    public static func earning(tokenCount: Int, model: ModelDescriptor) -> USDCAmount {
        earning(tokenCount: tokenCount, parameterCount: model.parameterCount, quantization: model.quantization)
    }

    /// The welcome bonus for new users.
    public static let welcomeBonus = USDCAmount(0.01)

    /// Minimum balance required to make remote inference requests.
    public static let minimumBalanceForRemote = USDCAmount(0.0001)
}

// MARK: - WalletBalance

public struct WalletBalance: Codable, Sendable {
    public var currentBalance: USDCAmount
    public var totalEarned: USDCAmount
    public var totalSpent: USDCAmount
    public var transactionCount: Int

    public init(
        currentBalance: USDCAmount = .zero,
        totalEarned: USDCAmount = .zero,
        totalSpent: USDCAmount = .zero,
        transactionCount: Int = 0
    ) {
        self.currentBalance = currentBalance
        self.totalEarned = totalEarned
        self.totalSpent = totalSpent
        self.transactionCount = transactionCount
    }
}
