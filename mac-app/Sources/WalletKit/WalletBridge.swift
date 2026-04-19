import Foundation
import CreditKit

// MARK: - Wallet Bridge

/// Bridges the on-chain Solana USDC wallet to the internal CreditKit USDC ledger.
/// Deposits and withdrawals flow through here.
@Observable
public final class WalletBridge: @unchecked Sendable {

    // MARK: - Observable State

    /// The Solana address for this device's wallet
    public private(set) var solanaAddress: String = ""

    /// On-chain USDC balance in micro-USDC (6 decimals)
    public private(set) var usdcBalanceRaw: UInt64 = 0

    /// Formatted USDC balance string
    public var usdcBalanceFormatted: String {
        let usd = Double(usdcBalanceRaw) / 1_000_000.0
        if usd == 0 { return "$0.00" }
        if usd < 0.01 { return String(format: "$%.4f", usd) }
        return String(format: "$%.2f", usd)
    }

    /// Whether deposit monitoring is active
    public private(set) var isMonitoring: Bool = false

    /// Whether a withdrawal is currently in progress
    public private(set) var pendingWithdrawal: Bool = false

    /// Last error message (cleared on next successful operation)
    public private(set) var lastError: String?

    /// Recent on-chain transactions
    public private(set) var recentOnChainTransactions: [OnChainTransfer] = []

    // MARK: - Internal State

    private let identity: SolanaIdentity
    private let rpc: SolanaRPCService
    private let depositMonitor: DepositMonitor
    private let usdcWallet: USDCWallet
    private let config: WalletKitConfig

    /// Previous USDC balance for detecting deposit amounts via balance diff
    private var previousUSDCBalance: UInt64 = 0

    // MARK: - Init

    public init(
        identity: SolanaIdentity,
        creditWallet: USDCWallet,
        config: WalletKitConfig = .mainnet
    ) {
        self.identity = identity
        self.usdcWallet = creditWallet
        self.config = config
        self.solanaAddress = identity.solanaAddress
        self.rpc = SolanaRPCService(config: config)
        self.depositMonitor = DepositMonitor(rpc: rpc, address: identity.solanaAddress, config: config)
    }

    // MARK: - Monitoring

    /// Start monitoring for incoming USDC deposits.
    public func startMonitoring() async {
        // Wire up deposit callback
        await depositMonitor.setOnDeposit { [weak self] transfer in
            await self?.handleDeposit(transfer)
        }
        await depositMonitor.startMonitoring()
        isMonitoring = true

        // Initial balance fetch
        await refreshBalance()
    }

    /// Stop monitoring for deposits.
    public func stopMonitoring() async {
        await depositMonitor.stopMonitoring()
        isMonitoring = false
    }

    // MARK: - Balance

    /// Refresh on-chain USDC balance.
    public func refreshBalance() async {
        do {
            let balance = try await rpc.getUSDCBalance(for: solanaAddress)
            previousUSDCBalance = usdcBalanceRaw
            usdcBalanceRaw = balance
            lastError = nil
        } catch {
            lastError = "Failed to fetch balance: \(error.localizedDescription)"
        }
    }

    // MARK: - Deposits

    /// Handle a detected USDC deposit by crediting the internal ledger.
    private func handleDeposit(_ transfer: OnChainTransfer) async {
        // Refresh balance to get the actual amount
        let oldBalance = usdcBalanceRaw
        await refreshBalance()
        let newBalance = usdcBalanceRaw

        guard newBalance > oldBalance else { return }
        let depositMicroUSDC = newBalance - oldBalance

        // Convert micro-USDC to USD
        let usdcAmount = USDCAmount(Double(depositMicroUSDC) / 1_000_000.0)

        // Record in the USDC ledger
        let transaction = USDCTransaction(
            type: .adjustment,
            amount: usdcAmount,
            description: String(format: "USDC deposit ($%.4f)", Double(depositMicroUSDC) / 1_000_000.0),
            txSignature: transfer.signature
        )
        await usdcWallet.recordAdjustmentCredit(
            amount: usdcAmount,
            description: transaction.description
        )

        // Track on-chain
        let record = OnChainTransfer(
            signature: transfer.signature,
            fromAddress: transfer.fromAddress,
            toAddress: solanaAddress,
            amountMicroUSDC: depositMicroUSDC,
            timestamp: Date(),
            direction: .deposit
        )
        recentOnChainTransactions.insert(record, at: 0)
        if recentOnChainTransactions.count > 50 {
            recentOnChainTransactions = Array(recentOnChainTransactions.prefix(50))
        }
    }

    // MARK: - Withdrawals

    /// Withdraw USDC to an external Solana address.
    /// Uses optimistic debit: debits the ledger first, then sends on-chain.
    /// On failure, a compensating credit reverses the debit.
    /// - Returns: The Solana transaction signature
    public func withdraw(creditAmount: USDCAmount, to destinationAddress: String) async throws -> String {
        guard !pendingWithdrawal else {
            throw WalletKitError.withdrawalInProgress
        }

        // Validate sufficient balance
        let currentBalance = await usdcWallet.currentBalance()
        guard currentBalance >= creditAmount else {
            throw WalletKitError.insufficientCreditBalance
        }

        let microUSDC = UInt64(creditAmount.value * 1_000_000.0)
        guard microUSDC > 0 else {
            throw WalletKitError.insufficientCreditBalance
        }

        pendingWithdrawal = true
        lastError = nil

        // Optimistic debit
        await usdcWallet.recordAdjustmentDebit(
            amount: creditAmount,
            description: String(format: "USDC withdrawal ($%.4f) - pending", Double(microUSDC) / 1_000_000.0)
        )

        do {
            // Send USDC on-chain
            let signature = try await WithdrawalService.sendUSDC(
                from: identity,
                to: destinationAddress,
                amountMicroUSDC: microUSDC,
                config: config
            )

            // Track on-chain
            let record = OnChainTransfer(
                signature: signature,
                fromAddress: solanaAddress,
                toAddress: destinationAddress,
                amountMicroUSDC: microUSDC,
                timestamp: Date(),
                direction: .withdrawal
            )
            recentOnChainTransactions.insert(record, at: 0)

            // Refresh on-chain balance
            await refreshBalance()

            pendingWithdrawal = false
            return signature
        } catch {
            // Compensating credit — reverse the optimistic debit
            await usdcWallet.recordAdjustmentCredit(
                amount: creditAmount,
                description: "Withdrawal failed — USDC restored"
            )

            pendingWithdrawal = false
            lastError = "Withdrawal failed: \(error.localizedDescription)"
            throw error
        }
    }

    // MARK: - Utilities

    /// SOL balance (needed for transaction fees)
    public func getSOLBalance() async -> Double {
        do {
            let lamports = try await rpc.getSOLBalance(for: solanaAddress)
            return Double(lamports) / 1_000_000_000.0
        } catch {
            return 0
        }
    }
}

// MARK: - DepositMonitor callback setter

extension DepositMonitor {
    func setOnDeposit(_ callback: @escaping @Sendable (OnChainTransfer) async -> Void) {
        self.onDeposit = callback
    }
}
