import SwiftUI

struct CompanionWalletView: View {
    var appState: CompanionAppState

    var body: some View {
        NavigationStack {
            List {
                // Balance
                Section {
                    VStack(spacing: 8) {
                        Text("Credit Balance")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Text(String(format: "%.2f", appState.walletBalance))
                            .font(.system(size: 48, weight: .bold, design: .rounded))
                            .foregroundStyle(.primary)
                        Text("SOL credits")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                }

                // Earnings chart
                Section("Activity") {
                    earningsChart
                }

                // Recent transactions
                Section("Recent Transactions") {
                    if appState.transactions.isEmpty {
                        VStack(spacing: 8) {
                            Image(systemName: "tray")
                                .font(.title2)
                                .foregroundStyle(.tertiary)
                            Text("No transactions yet")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                    } else {
                        ForEach(appState.transactions) { transaction in
                            TransactionRow(transaction: transaction)
                        }
                    }
                }

                // Explainer
                Section {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: "lightbulb.fill")
                            .foregroundStyle(.yellow)
                            .font(.title3)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("How credits work")
                                .font(.subheadline)
                                .fontWeight(.medium)
                            Text("You earn credits by contributing inference compute on your Mac. Spending credits lets you use other nodes from this iOS app. Run the Solair macOS app to start earning.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
            .navigationTitle("Wallet")
        }
    }

    // MARK: - Earnings Chart

    private var earningsChart: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading) {
                    Text("Earned")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(String(format: "%.1f", totalEarned))
                        .font(.headline)
                        .foregroundStyle(.green)
                }
                Spacer()
                VStack(alignment: .trailing) {
                    Text("Spent")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(String(format: "%.1f", totalSpent))
                        .font(.headline)
                        .foregroundStyle(.orange)
                }
            }

            // Simple bar comparison
            GeometryReader { geo in
                let maxVal = max(totalEarned, totalSpent, 1)
                HStack(spacing: 4) {
                    // Earned bar
                    RoundedRectangle(cornerRadius: 4)
                        .fill(.green.opacity(0.7))
                        .frame(width: geo.size.width * 0.48 * (totalEarned / maxVal))

                    Spacer()

                    // Spent bar
                    RoundedRectangle(cornerRadius: 4)
                        .fill(.orange.opacity(0.7))
                        .frame(width: geo.size.width * 0.48 * (totalSpent / maxVal))
                }
            }
            .frame(height: 24)

            HStack {
                Label("Earned", systemImage: "circle.fill")
                    .font(.caption2)
                    .foregroundStyle(.green)
                Spacer()
                Label("Spent", systemImage: "circle.fill")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
        }
        .padding(.vertical, 4)
    }

    private var totalEarned: Double {
        appState.transactions.filter(\.isEarning).reduce(0) { $0 + $1.amount }
    }

    private var totalSpent: Double {
        appState.transactions.filter { !$0.isEarning }.reduce(0) { $0 + $1.amount }
    }
}

// MARK: - Transaction Row

private struct TransactionRow: View {
    let transaction: WalletTransaction

    var body: some View {
        HStack {
            Image(systemName: transaction.isEarning ? "arrow.down.circle.fill" : "arrow.up.circle.fill")
                .foregroundStyle(transaction.isEarning ? .green : .orange)

            VStack(alignment: .leading, spacing: 2) {
                Text(transaction.description)
                    .font(.subheadline)
                Text(transaction.date, style: .relative)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Text(String(format: "%@%.2f", transaction.isEarning ? "+" : "-", transaction.amount))
                .font(.subheadline)
                .fontWeight(.medium)
                .foregroundStyle(transaction.isEarning ? .green : .orange)
        }
    }
}
