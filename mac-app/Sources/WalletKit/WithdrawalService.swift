import Foundation
import SolanaSwift

// MARK: - Withdrawal Service

/// Handles sending USDC from the app wallet to an external Solana address.
/// Automatically deducts a 1.8% platform fee and sends it to the Teale treasury.
public struct WithdrawalService: Sendable {

    /// Send USDC to an external Solana address, splitting 98.2% to destination and 1.8% to treasury.
    /// - Returns: The transaction signature on success
    public static func sendUSDC(
        from identity: SolanaIdentity,
        to destinationAddress: String,
        amountMicroUSDC: UInt64,
        config: WalletKitConfig = .mainnet
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

        // Calculate fee split
        let feeAmount = UInt64(Double(amountMicroUSDC) * WalletKitConfig.platformFeeRate)
        let netAmount = amountMicroUSDC - feeAmount

        // Build instructions
        var instructions: [TransactionInstruction] = []

        // --- Destination ATA ---
        let destATA = try PublicKey.associatedTokenAddress(
            walletAddress: destPubkey,
            tokenMintAddress: mintPubkey,
            tokenProgramId: tokenProgramId
        )

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

        // Transfer net amount (95%) to destination
        let transferInstruction = TokenProgram.transferInstruction(
            source: sourceATA,
            destination: destATA,
            owner: sourcePubkey,
            amount: netAmount
        )
        instructions.append(transferInstruction)

        // --- Treasury fee (5%) ---
        if feeAmount > 0 {
            let treasuryPubkey = try PublicKey(string: WalletKitConfig.treasuryAddress)
            let treasuryATA = try PublicKey.associatedTokenAddress(
                walletAddress: treasuryPubkey,
                tokenMintAddress: mintPubkey,
                tokenProgramId: tokenProgramId
            )

            let treasuryBalance = try? await apiClient.getBalance(account: treasuryATA.base58EncodedString, commitment: "confirmed")
            if treasuryBalance == nil || treasuryBalance == 0 {
                let createTreasuryATAInstruction = try AssociatedTokenProgram.createAssociatedTokenAccountInstruction(
                    mint: mintPubkey,
                    owner: treasuryPubkey,
                    payer: sourcePubkey,
                    tokenProgramId: tokenProgramId
                )
                instructions.append(createTreasuryATAInstruction)
            }

            let feeInstruction = TokenProgram.transferInstruction(
                source: sourceATA,
                destination: treasuryATA,
                owner: sourcePubkey,
                amount: feeAmount
            )
            instructions.append(feeInstruction)
        }

        // Use BlockchainClient to prepare and send (atomic — all or nothing)
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
