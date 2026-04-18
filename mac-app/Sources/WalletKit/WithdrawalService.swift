import Foundation
import SolanaSwift

// MARK: - Withdrawal Service

/// Handles sending USDC from the app wallet to an external Solana address.
public struct WithdrawalService: Sendable {

    /// Send USDC to an external Solana address.
    /// - Returns: The transaction signature on success
    public static func sendUSDC(
        from identity: SolanaIdentity,
        to destinationAddress: String,
        amountMicroUSDC: UInt64,
        config: WalletKitConfig = .devnet
    ) async throws -> String {
        guard Base58.decode(destinationAddress) != nil else {
            throw WalletKitError.invalidDestinationAddress
        }

        let endpoint = APIEndPoint(
            address: config.rpcEndpoint.absoluteString,
            network: config.rpcEndpoint.absoluteString.contains("devnet") ? .devnet : .mainnetBeta
        )
        let apiClient = JSONRPCAPIClient(endpoint: endpoint)
        let blockchainClient = BlockchainClient(apiClient: apiClient)

        // Create KeyPair from our identity's 64-byte secret key (seed + pubkey)
        let keyPair = try KeyPair(secretKey: identity.solanaSecretKey)

        // Derive public keys
        let sourcePubkey = try PublicKey(string: identity.solanaAddress)
        let destPubkey = try PublicKey(string: destinationAddress)
        let mintPubkey = try PublicKey(string: config.usdcMint)
        let tokenProgramId = TokenProgram.id

        let sourceATA = try PublicKey.associatedTokenAddress(
            walletAddress: sourcePubkey,
            tokenMintAddress: mintPubkey,
            tokenProgramId: tokenProgramId
        )

        let destATA = try PublicKey.associatedTokenAddress(
            walletAddress: destPubkey,
            tokenMintAddress: mintPubkey,
            tokenProgramId: tokenProgramId
        )

        // Build instructions
        var instructions: [TransactionInstruction] = []

        // Check if destination ATA exists; if not, create it
        let destBalance = try? await apiClient.getBalance(account: destATA.base58EncodedString, commitment: "confirmed")
        if destBalance == nil || destBalance == 0 {
            let createATAInstruction = try AssociatedTokenProgram.createAssociatedTokenAccountInstruction(
                mint: mintPubkey,
                owner: destPubkey,
                payer: sourcePubkey,
                tokenProgramId: tokenProgramId
            )
            instructions.append(createATAInstruction)
        }

        // SPL Token transfer instruction
        let transferInstruction = TokenProgram.transferInstruction(
            source: sourceATA,
            destination: destATA,
            owner: sourcePubkey,
            amount: amountMicroUSDC
        )
        instructions.append(transferInstruction)

        // Use BlockchainClient to prepare and send
        let prepared = try await blockchainClient.prepareTransaction(
            instructions: instructions,
            signers: [keyPair],
            feePayer: sourcePubkey
        )

        let signature = try await blockchainClient.sendTransaction(
            preparedTransaction: prepared
        )

        return signature
    }
}
