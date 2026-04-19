import Foundation

// MARK: - Deposit Monitor

/// Polls Solana RPC for new USDC deposits to the app's wallet address.
public actor DepositMonitor {
    private let rpc: SolanaRPCService
    private let address: String
    private let config: WalletKitConfig
    private var monitorTask: Task<Void, Never>?
    private var lastSignature: String?

    private static let lastSignatureKey = "teale.walletkit.lastDepositSignature"

    /// Called when a new deposit is detected
    public var onDeposit: (@Sendable (OnChainTransfer) async -> Void)?

    public init(rpc: SolanaRPCService, address: String, config: WalletKitConfig = .mainnet) {
        self.rpc = rpc
        self.address = address
        self.config = config
        self.lastSignature = UserDefaults.standard.string(forKey: Self.lastSignatureKey)
    }

    /// Start polling for deposits.
    public func startMonitoring() {
        guard monitorTask == nil else { return }
        monitorTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                await self.poll()
                try? await Task.sleep(nanoseconds: UInt64(self.config.pollIntervalSeconds * 1_000_000_000))
            }
        }
    }

    /// Stop polling.
    public func stopMonitoring() {
        monitorTask?.cancel()
        monitorTask = nil
    }

    /// Check for new USDC transfers to our address.
    private func poll() async {
        do {
            let signatures = try await rpc.getRecentSignatures(
                for: address,
                limit: 10,
                before: nil
            )

            // Filter to signatures newer than our last known one
            var newSignatures: [String] = []
            for sig in signatures {
                if sig.signature == lastSignature { break }
                newSignatures.append(sig.signature)
            }

            guard !newSignatures.isEmpty else { return }

            // Process in chronological order (oldest first)
            for sig in newSignatures.reversed() {
                // For now, we detect deposits by checking USDC balance changes.
                // A full implementation would parse the transaction for SPL token transfer instructions.
                // This simplified approach credits based on the transaction existing.
                if let onDeposit {
                    let transfer = OnChainTransfer(
                        signature: sig,
                        fromAddress: "unknown",
                        toAddress: address,
                        amountMicroUSDC: 0, // Will be filled by WalletBridge via balance diff
                        timestamp: Date(),
                        direction: .deposit
                    )
                    await onDeposit(transfer)
                }
            }

            // Update last known signature
            if let newest = newSignatures.first {
                lastSignature = newest
                UserDefaults.standard.set(newest, forKey: Self.lastSignatureKey)
            }
        } catch {
            // Log but don't stop monitoring — transient RPC errors are common
            print("[WalletKit] Deposit poll error: \(error.localizedDescription)")
        }
    }
}
