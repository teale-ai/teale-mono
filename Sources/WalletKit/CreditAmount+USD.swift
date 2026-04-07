import Foundation
import CreditKit

// MARK: - USD Conversion for CreditAmount

/// Peg: 1 credit = $0.0001 USD (10,000 credits = $1 USDC)
extension CreditAmount {
    /// The number of credits per 1 USDC
    public static let creditsPerUSDC: Double = 10_000

    /// USD value at the 1 credit = $0.0001 peg
    public var usdValue: Double { value / Self.creditsPerUSDC }

    /// Formatted USD string (shows 4 decimal places for small amounts)
    public var usdFormatted: String {
        let usd = usdValue
        if usd == 0 { return "$0.00" }
        if usd < 0.01 { return String(format: "$%.4f", usd) }
        return String(format: "$%.2f", usd)
    }

    /// Create CreditAmount from a USD value
    public static func fromUSD(_ usd: Double) -> CreditAmount {
        CreditAmount(usd * creditsPerUSDC)
    }

    /// Create CreditAmount from micro-USDC (raw on-chain value with 6 decimal places)
    /// 1_000_000 micro-USDC = $1.00 USDC = 10,000 credits
    public static func fromMicroUSDC(_ micro: UInt64) -> CreditAmount {
        let usd = Double(micro) / 1_000_000.0
        return fromUSD(usd)
    }

    /// Convert credits to micro-USDC (for on-chain transactions)
    public var microUSDC: UInt64 {
        UInt64(usdValue * 1_000_000.0)
    }
}
