import Foundation

// MARK: - Configuration

public struct WalletKitConfig: Sendable {
    public var rpcEndpoint: URL
    public var usdcMint: String
    public var creditsPerUSDC: Double
    public var pollIntervalSeconds: TimeInterval

    public init(
        rpcEndpoint: URL,
        usdcMint: String,
        creditsPerUSDC: Double = 10_000,
        pollIntervalSeconds: TimeInterval = 30
    ) {
        self.rpcEndpoint = rpcEndpoint
        self.usdcMint = usdcMint
        self.creditsPerUSDC = creditsPerUSDC
        self.pollIntervalSeconds = pollIntervalSeconds
    }

    public static let mainnet = WalletKitConfig(
        rpcEndpoint: URL(string: "https://api.mainnet-beta.solana.com")!,
        usdcMint: "EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v",
        creditsPerUSDC: 10_000,
        pollIntervalSeconds: 30
    )

    public static let devnet = WalletKitConfig(
        rpcEndpoint: URL(string: "https://api.devnet.solana.com")!,
        usdcMint: "4zMMC9srt5Ri5X14GAgXhaHii3GnPAEERYPJgZJDncDU",
        creditsPerUSDC: 10_000,
        pollIntervalSeconds: 15
    )
}

// MARK: - On-Chain Transfer Record

public struct OnChainTransfer: Codable, Sendable, Identifiable {
    public var id: String { signature }
    public let signature: String
    public let fromAddress: String
    public let toAddress: String
    public let amountMicroUSDC: UInt64
    public let timestamp: Date
    public let direction: TransferDirection

    public enum TransferDirection: String, Codable, Sendable {
        case deposit
        case withdrawal
    }

    public init(
        signature: String,
        fromAddress: String,
        toAddress: String,
        amountMicroUSDC: UInt64,
        timestamp: Date,
        direction: TransferDirection
    ) {
        self.signature = signature
        self.fromAddress = fromAddress
        self.toAddress = toAddress
        self.amountMicroUSDC = amountMicroUSDC
        self.timestamp = timestamp
        self.direction = direction
    }

    /// Formatted USDC amount (6 decimal places → human-readable)
    public var usdcAmount: Double {
        Double(amountMicroUSDC) / 1_000_000.0
    }
}

// MARK: - Errors

public enum WalletKitError: LocalizedError, Sendable {
    case keychainLoadFailed
    case keychainSaveFailed
    case insufficientUSDCBalance
    case insufficientCreditBalance
    case insufficientSOLForFees
    case invalidDestinationAddress
    case transactionFailed(String)
    case rpcError(String)
    case noTokenAccount
    case withdrawalInProgress

    public var errorDescription: String? {
        switch self {
        case .keychainLoadFailed: return "Failed to load Solana wallet from Keychain"
        case .keychainSaveFailed: return "Failed to save Solana wallet to Keychain"
        case .insufficientUSDCBalance: return "Insufficient USDC balance for this transaction"
        case .insufficientCreditBalance: return "Insufficient credit balance for withdrawal"
        case .insufficientSOLForFees: return "Insufficient SOL to pay transaction fees"
        case .invalidDestinationAddress: return "Invalid Solana destination address"
        case .transactionFailed(let msg): return "Transaction failed: \(msg)"
        case .rpcError(let msg): return "Solana RPC error: \(msg)"
        case .noTokenAccount: return "No USDC token account found"
        case .withdrawalInProgress: return "A withdrawal is already in progress"
        }
    }
}
