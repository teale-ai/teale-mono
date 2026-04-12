import SwiftUI
import AppCore
import CreditKit
import SharedTypes
import ClusterKit
import WalletKit

struct WalletView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Balance Card
                BalanceCard()

                // Solana Wallet (if enabled)
                if appState.walletBridge != nil {
                    Divider()
                    SolanaWalletSection()
                }

                Divider()

                // Send Credits (only visible when peers are connected)
                SendCreditsSection()

                Divider()

                // Pricing Guide
                PricingGuideSection()

                Divider()

                // Earning/Spending Summary
                CreditSummarySection()

                Divider()

                // Recent Transactions
                TransactionsSection()
            }
            .padding()
        }
        .navigationTitle(appState.loc("wallet.title"))
    }
}

// MARK: - Balance Card

private struct BalanceCard: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        VStack(spacing: 8) {
            Text(appState.loc("wallet.balance"))
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Text(appState.wallet.balance.description)
                .font(.system(size: 36, weight: .bold, design: .rounded))
                .foregroundStyle(.primary)

            Text("USDC")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
        .background(.quaternary.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

// MARK: - Send Credits

private struct SendCreditsSection: View {
    @Environment(AppState.self) private var appState
    @State private var selectedPeerID: UUID?
    @State private var amountText: String = ""
    @State private var memo: String = ""
    @State private var isSending: Bool = false
    @State private var resultMessage: String?

    private var connectedPeers: [PeerSummary] {
        appState.clusterManager.peerSummaries
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(appState.loc("wallet.sendCredits"))
                .font(.subheadline)
                .foregroundStyle(.secondary)

            if connectedPeers.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "network.slash")
                        .foregroundStyle(.secondary)
                    Text(appState.loc("wallet.connectCluster"))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .padding(.vertical, 8)
            } else {
                VStack(spacing: 8) {
                    Picker("To", selection: $selectedPeerID) {
                        Text(appState.loc("wallet.selectPeer")).tag(UUID?.none)
                        ForEach(connectedPeers) { peer in
                            Text(peer.name).tag(UUID?.some(peer.id))
                        }
                    }
                    .pickerStyle(.menu)

                    HStack(spacing: 8) {
                        TextField(appState.loc("wallet.amount"), text: $amountText)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 80)

                        TextField(appState.loc("wallet.memo"), text: $memo)
                            .textFieldStyle(.roundedBorder)

                        Button {
                            send()
                        } label: {
                            if isSending {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Text(appState.loc("wallet.send"))
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(!canSend)
                    }
                }

                if let resultMessage {
                    Text(resultMessage)
                        .font(.caption)
                        .foregroundStyle(resultMessage.hasPrefix("Sent") ? .green : .red)
                        .transition(.opacity)
                }
            }
        }
        .onAppear {
            applyPendingPeerSelection()
        }
        .onChange(of: connectedPeers.map(\.id)) {
            applyPendingPeerSelection()
        }
    }

    private var canSend: Bool {
        guard !isSending else { return false }
        guard selectedPeerID != nil else { return false }
        guard let amount = Double(amountText), amount > 0 else { return false }
        return true
    }

    private func send() {
        guard let peerID = selectedPeerID,
              let amount = Double(amountText), amount > 0 else { return }
        isSending = true
        resultMessage = nil
        let memoText = memo.isEmpty ? nil : memo
        Task {
            let success = await appState.sendCredits(amount: amount, to: peerID, memo: memoText)
            isSending = false
            withAnimation {
                if success {
                    resultMessage = "Sent \(USDCAmount(amount).description) USDC"
                    amountText = ""
                    memo = ""
                } else {
                    resultMessage = "Failed — insufficient balance or peer unreachable"
                }
            }
        }
    }

    private func applyPendingPeerSelection() {
        if let pendingPeerID = appState.pendingWalletTransferPeerID,
           connectedPeers.contains(where: { $0.id == pendingPeerID }) {
            selectedPeerID = pendingPeerID
            appState.pendingWalletTransferPeerID = nil
            return
        }

        if selectedPeerID == nil, connectedPeers.count == 1 {
            selectedPeerID = connectedPeers[0].id
        }
    }
}

// MARK: - Pricing Guide

private struct PricingGuideSection: View {
    @Environment(AppState.self) private var appState

    private struct UsageExample: Identifiable {
        var id: String { emoji + title }
        let emoji: String
        let title: String
        let detail: String
        let creditCost: String
    }

    private var balance: Double {
        appState.wallet.balance.value
    }

    private var examples: [UsageExample] {
        [
            UsageExample(
                emoji: "💬",
                title: appState.loc("wallet.quickQuestion"),
                detail: appState.loc("wallet.quickQuestionDetail"),
                creditCost: "~$0.00005"
            ),
            UsageExample(
                emoji: "📝",
                title: appState.loc("wallet.writeEmail"),
                detail: appState.loc("wallet.writeEmailDetail"),
                creditCost: "~$0.0001-0.0002"
            ),
            UsageExample(
                emoji: "💻",
                title: appState.loc("wallet.debugCode"),
                detail: appState.loc("wallet.debugCodeDetail"),
                creditCost: "~$0.0002-0.0005"
            ),
            UsageExample(
                emoji: "📖",
                title: appState.loc("wallet.summarize"),
                detail: appState.loc("wallet.summarizeDetail"),
                creditCost: "~$0.0003-0.0008"
            ),
        ]
    }

    private var balanceSummary: String {
        if balance >= 100 {
            return appState.loc("wallet.balancePlenty")
        } else if balance >= 30 {
            return appState.loc("wallet.balanceGood")
        } else if balance >= 10 {
            return appState.loc("wallet.balanceOk")
        } else if balance > 0 {
            return appState.loc("wallet.balanceLow")
        } else {
            return appState.loc("wallet.balanceEmpty")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(appState.loc("wallet.whatCanBuy"))
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Text(balanceSummary)
                .font(.caption)
                .foregroundStyle(.primary)
                .padding(.bottom, 2)

            VStack(spacing: 2) {
                ForEach(examples) { ex in
                    HStack(alignment: .top, spacing: 8) {
                        Text(ex.emoji)
                            .font(.body)
                            .frame(width: 20)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(ex.title)
                                .font(.caption.bold())
                            Text(ex.detail)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(ex.creditCost)
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, 5)
                    .padding(.horizontal, 8)
                }
            }
            .padding(.vertical, 4)
            .background(.blue.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))

            Text(appState.loc("wallet.pricingFooter"))
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }
}

// MARK: - Credit Summary

private struct CreditSummarySection: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(appState.loc("wallet.summary"))
                .font(.subheadline)
                .foregroundStyle(.secondary)

            HStack(spacing: 16) {
                VStack(spacing: 4) {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.down.circle.fill")
                            .foregroundStyle(.green)
                        Text(appState.wallet.totalEarned.description)
                            .font(.headline)
                    }
                    Text(appState.loc("wallet.earned"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(.green.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 8))

                VStack(spacing: 4) {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.up.circle.fill")
                            .foregroundStyle(.red)
                        Text(appState.wallet.totalSpent.description)
                            .font(.headline)
                    }
                    Text(appState.loc("wallet.spent"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(.red.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }

            Text("Earn USDC by serving inference to other nodes. Spend USDC to use remote models.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }
}

// MARK: - Transactions

private struct TransactionsSection: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(appState.loc("wallet.recentTransactions"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(appState.wallet.recentTransactions.count) shown")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            if appState.wallet.recentTransactions.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "clock")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                    Text(appState.loc("wallet.noTransactions"))
                        .foregroundStyle(.secondary)
                    Text("Start chatting or serve inference to see transactions here")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
            } else {
                ForEach(appState.wallet.recentTransactions) { transaction in
                    TransactionRow(transaction: transaction)
                }
            }
        }
    }
}

// MARK: - Transaction Row

private struct TransactionRow: View {
    let transaction: USDCTransaction

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: iconName)
                .foregroundStyle(iconColor)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text(transaction.description)
                    .font(.caption)
                    .lineLimit(1)
                Text(transaction.timestamp, format: .dateTime.month(.abbreviated).day().hour().minute())
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            Spacer()

            Text(amountText)
                .font(.caption.bold())
                .foregroundStyle(amountColor)
        }
        .padding(.vertical, 4)
    }

    private var isSentTransfer: Bool {
        transaction.type == .transfer && transaction.description.hasPrefix("Sent")
    }

    private var iconName: String {
        switch transaction.type {
        case .earned, .sdkEarning: return "arrow.down.circle.fill"
        case .spent: return "arrow.up.circle.fill"
        case .bonus: return "gift.fill"
        case .adjustment: return "arrow.left.arrow.right"
        case .transfer: return isSentTransfer ? "arrow.up.right.circle.fill" : "arrow.down.left.circle.fill"
        }
    }

    private var iconColor: Color {
        switch transaction.type {
        case .earned, .bonus, .sdkEarning: return .green
        case .spent: return .red
        case .adjustment: return .blue
        case .transfer: return isSentTransfer ? .orange : .blue
        }
    }

    private var amountText: String {
        let sign = (transaction.type == .spent || isSentTransfer) ? "-" : "+"
        return "\(sign)\(transaction.amount.description)"
    }

    private var amountColor: Color {
        (transaction.type == .spent || isSentTransfer) ? .red : .green
    }
}

// MARK: - Solana Wallet Section

private struct SolanaWalletSection: View {
    @Environment(AppState.self) private var appState
    @State private var withdrawAmount: String = ""
    @State private var destinationAddress: String = ""
    @State private var isWithdrawing: Bool = false
    @State private var withdrawResult: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(appState.loc("wallet.solana.title"), systemImage: "link.circle.fill")
                .font(.headline)

            if let bridge = appState.walletBridge {
                // Address display
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(appState.loc("wallet.solana.address"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(bridge.solanaAddress)
                            .font(.system(.caption2, design: .monospaced))
                            .textSelection(.enabled)
                            .lineLimit(1)
                    }
                    Spacer()
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(bridge.solanaAddress, forType: .string)
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                .padding(10)
                .background(.quaternary.opacity(0.3))
                .clipShape(RoundedRectangle(cornerRadius: 8))

                // USDC Balance
                HStack {
                    Text(appState.loc("wallet.solana.onChainBalance"))
                        .font(.subheadline)
                    Spacer()
                    Text(bridge.usdcBalanceFormatted + " USDC")
                        .font(.subheadline.bold())
                        .foregroundStyle(.green)
                }

                // Deposit instructions
                VStack(alignment: .leading, spacing: 4) {
                    Text(appState.loc("wallet.solana.depositTitle"))
                        .font(.caption.bold())
                    Text(appState.loc("wallet.solana.depositInstructions"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.blue.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 8))

                // Withdraw form
                VStack(alignment: .leading, spacing: 8) {
                    Text(appState.loc("wallet.solana.withdrawTitle"))
                        .font(.caption.bold())

                    HStack(spacing: 8) {
                        TextField(appState.loc("wallet.solana.creditsAmount"), text: $withdrawAmount)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 100)

                        TextField(appState.loc("wallet.solana.destinationAddress"), text: $destinationAddress)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.body, design: .monospaced))

                        Button {
                            Task { await performWithdrawal(bridge: bridge) }
                        } label: {
                            if isWithdrawing {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Text(appState.loc("wallet.solana.withdrawButton"))
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(isWithdrawing || withdrawAmount.isEmpty || destinationAddress.isEmpty)
                    }

                    if let result = withdrawResult {
                        Text(result)
                            .font(.caption)
                            .foregroundStyle(result.contains("Success") ? .green : .red)
                    }
                }

                // Error display
                if let error = bridge.lastError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        }
    }

    private func performWithdrawal(bridge: WalletBridge) async {
        guard let amount = Double(withdrawAmount), amount > 0 else {
            withdrawResult = "Invalid amount"
            return
        }

        isWithdrawing = true
        withdrawResult = nil

        do {
            let usdcAmount = USDCAmount(amount)
            let sig = try await bridge.withdraw(creditAmount: usdcAmount, to: destinationAddress)
            withdrawResult = "Success! Tx: \(sig.prefix(16))..."
            withdrawAmount = ""
            destinationAddress = ""
        } catch {
            withdrawResult = error.localizedDescription
        }

        isWithdrawing = false
    }
}
