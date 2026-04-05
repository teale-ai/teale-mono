import SwiftUI
import CreditKit

struct WalletView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Balance Card
                BalanceCard()

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
                Text(transaction.timestamp, style: .relative)
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

    private var iconName: String {
        switch transaction.type {
        case .earned: return "arrow.down.circle.fill"
        case .spent: return "arrow.up.circle.fill"
        case .bonus: return "gift.fill"
        case .adjustment: return "arrow.left.arrow.right"
        case .transfer: return "arrow.right.circle.fill"
        }
    }

    private var iconColor: Color {
        switch transaction.type {
        case .earned, .bonus: return .green
        case .spent: return .red
        case .adjustment, .transfer: return .blue
        }
    }

    private var amountText: String {
        let sign = transaction.type == .spent ? "-" : "+"
        return "\(sign)\(String(format: "%.2f", transaction.amount.value))"
    }

    private var amountColor: Color {
        transaction.type == .spent ? .red : .green
    }
}
