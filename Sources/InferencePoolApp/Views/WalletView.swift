import SwiftUI
import CreditKit
import SharedTypes
import ClusterKit

struct WalletView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Balance Card
                BalanceCard()

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
        .navigationTitle("Wallet")
    }
}

// MARK: - Balance Card

private struct BalanceCard: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        VStack(spacing: 8) {
            Text("Credit Balance")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Text(String(format: "%.2f", appState.wallet.balance.value))
                .font(.system(size: 36, weight: .bold, design: .rounded))
                .foregroundStyle(.primary)

            Text("credits")
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
            Text("Send Credits")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            if connectedPeers.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "network.slash")
                        .foregroundStyle(.secondary)
                    Text("Connect to a cluster to send credits to peers")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .padding(.vertical, 8)
            } else {
                VStack(spacing: 8) {
                    Picker("To", selection: $selectedPeerID) {
                        Text("Select peer...").tag(UUID?.none)
                        ForEach(connectedPeers) { peer in
                            Text(peer.name).tag(UUID?.some(peer.id))
                        }
                    }
                    .pickerStyle(.menu)

                    HStack(spacing: 8) {
                        TextField("Amount", text: $amountText)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 80)

                        TextField("Memo (optional)", text: $memo)
                            .textFieldStyle(.roundedBorder)

                        Button {
                            send()
                        } label: {
                            if isSending {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Text("Send")
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
                    resultMessage = "Sent \(String(format: "%.2f", amount)) credits"
                    amountText = ""
                    memo = ""
                } else {
                    resultMessage = "Failed — insufficient balance or peer unreachable"
                }
            }
        }
    }
}

// MARK: - Pricing Guide

private struct PricingGuideSection: View {
    @Environment(AppState.self) private var appState

    private struct ModelEstimate: Identifiable {
        var id: String { label }
        let label: String
        let paramB: Double
        let tokensFor100Credits: Int
        let approxChats: String
    }

    private var estimates: [ModelEstimate] {
        [
            ModelEstimate(label: "Small (1-4B)", paramB: 3, tokensFor100Credits: tokenBudget(paramB: 3), approxChats: "~hundreds of chats"),
            ModelEstimate(label: "Medium (8B)", paramB: 8, tokensFor100Credits: tokenBudget(paramB: 8), approxChats: "~50-100 chats"),
            ModelEstimate(label: "Large (27-32B)", paramB: 30, tokensFor100Credits: tokenBudget(paramB: 30), approxChats: "~10-20 chats"),
            ModelEstimate(label: "XL (70B+)", paramB: 70, tokensFor100Credits: tokenBudget(paramB: 70), approxChats: "~5-10 chats"),
        ]
    }

    private func tokenBudget(paramB: Double) -> Int {
        // cost = (tokens/1000) * (paramB * 0.1) * 1.0 (q4)
        // tokens = 100 * 1000 / (paramB * 0.1)
        Int(100.0 * 1000.0 / (paramB * 0.1))
    }

    private func formatTokens(_ count: Int) -> String {
        if count >= 1_000_000 {
            return String(format: "%.0fM", Double(count) / 1_000_000)
        } else if count >= 1_000 {
            return String(format: "%.0fK", Double(count) / 1_000)
        }
        return "\(count)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("What Can Your Credits Buy?")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            VStack(spacing: 6) {
                ForEach(estimates) { est in
                    HStack {
                        Text(est.label)
                            .font(.caption)
                            .frame(width: 100, alignment: .leading)
                        Text("~\(formatTokens(est.tokensFor100Credits)) tokens")
                            .font(.caption.monospaced())
                            .foregroundStyle(.primary)
                        Spacer()
                        Text(est.approxChats)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, 3)
                    .padding(.horizontal, 8)
                }
            }
            .padding(.vertical, 8)
            .background(.blue.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))

            Text("Estimates based on 100 credits with 4-bit quantization. Larger models cost more per token but produce higher quality output. You earn credits by serving inference to other nodes on the network.")
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
            Text("Summary")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            HStack(spacing: 16) {
                VStack(spacing: 4) {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.down.circle.fill")
                            .foregroundStyle(.green)
                        Text(String(format: "%.2f", appState.wallet.totalEarned.value))
                            .font(.headline)
                    }
                    Text("Earned")
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
                        Text(String(format: "%.2f", appState.wallet.totalSpent.value))
                            .font(.headline)
                    }
                    Text("Spent")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(.red.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }

            Text("Earn credits by serving inference to other nodes. Spend credits to use remote models.")
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
                Text("Recent Transactions")
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
                    Text("No transactions yet")
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
    let transaction: CreditTransaction

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
        case .earned: return "arrow.down.circle.fill"
        case .spent: return "arrow.up.circle.fill"
        case .bonus: return "gift.fill"
        case .adjustment: return "arrow.left.arrow.right"
        case .transfer: return isSentTransfer ? "arrow.up.right.circle.fill" : "arrow.down.left.circle.fill"
        }
    }

    private var iconColor: Color {
        switch transaction.type {
        case .earned, .bonus: return .green
        case .spent: return .red
        case .adjustment: return .blue
        case .transfer: return isSentTransfer ? .orange : .blue
        }
    }

    private var amountText: String {
        let sign = (transaction.type == .spent || isSentTransfer) ? "-" : "+"
        return "\(sign)\(String(format: "%.2f", transaction.amount.value))"
    }

    private var amountColor: Color {
        (transaction.type == .spent || isSentTransfer) ? .red : .green
    }
}
