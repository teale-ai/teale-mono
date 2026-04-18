import Foundation
import SolanaSwift

// MARK: - Solana RPC Service

/// Actor wrapping solana-swift's JSON-RPC client for USDC operations.
public actor SolanaRPCService {
    private let apiClient: JSONRPCAPIClient
    private let config: WalletKitConfig

    public init(config: WalletKitConfig = .devnet) {
        self.config = config
        let endpoint = APIEndPoint(
            address: config.rpcEndpoint.absoluteString,
            network: config.rpcEndpoint.absoluteString.contains("devnet") ? .devnet : .mainnetBeta
        )
        self.apiClient = JSONRPCAPIClient(endpoint: endpoint)
    }

    /// Get USDC balance for a Solana address (returns token amount as UInt64, 6 decimals).
    public func getUSDCBalance(for address: String) async throws -> UInt64 {
        let accounts: [TokenAccount<TokenAccountState>] = try await apiClient.getTokenAccountsByOwner(
            pubkey: address,
            params: OwnerInfoParams(mint: config.usdcMint, programId: nil),
            configs: RequestConfiguration(encoding: "base64"),
            decodingTo: TokenAccountState.self
        )

        guard let account = accounts.first else {
            return 0
        }

        // TokenAccountState.lamports holds the SPL token amount (micro-USDC)
        return account.account.data.lamports
    }

    /// Get SOL balance for a Solana address (in lamports, 1 SOL = 1_000_000_000 lamports).
    public func getSOLBalance(for address: String) async throws -> UInt64 {
        try await apiClient.getBalance(account: address, commitment: "confirmed")
    }

    /// Get recent transaction signatures for an address (for deposit detection).
    public func getRecentSignatures(
        for address: String,
        limit: Int = 20,
        before: String? = nil
    ) async throws -> [SignatureInfo] {
        try await apiClient.getSignaturesForAddress(
            address: address,
            configs: RequestConfiguration(limit: limit, before: before)
        )
    }

    /// Request an airdrop on devnet (for testing).
    public func requestAirdrop(to address: String, lamports: UInt64 = 1_000_000_000) async throws -> String {
        try await apiClient.requestAirdrop(account: address, lamports: lamports)
    }
}
