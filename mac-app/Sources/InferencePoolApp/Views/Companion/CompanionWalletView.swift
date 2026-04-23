import SwiftUI
import AppCore
import CreditKit

struct CompanionWalletView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            balancesSection
            ledgerSection
        }
    }

    private var balancesSection: some View {
        TealeSection(prompt: "balances") {
            TealeStats {
                TealeStatRow(
                    label: "Teale credits",
                    value: creditCountString(appState.wallet.balance),
                    note: "Credits go up while supply is on."
                )
                TealeStatRow(
                    label: "USDC",
                    value: appState.wallet.balance.description
                )
                TealeStatRow(
                    label: "Session",
                    value: "\(appState.totalTokensGenerated) tokens served",
                    note: "Availability credits begin once a compatible model is loaded and serving."
                )
                TealeStatRow(
                    label: "Lifetime earned",
                    value: appState.wallet.totalEarned.description
                )
                TealeStatRow(
                    label: "Lifetime spent",
                    value: appState.wallet.totalSpent.description
                )
                TealeStatRow(
                    label: "Requests",
                    value: "\(appState.totalRequestsServed)"
                )
                TealeStatRow(
                    label: "State",
                    value: appState.companionState.displayText,
                    valueColor: appState.companionState.chipColor
                )
            }
        }
    }

    private var ledgerSection: some View {
        TealeSection(prompt: "ledger") {
            if appState.wallet.recentTransactions.isEmpty {
                Text("No transactions yet. Supply a model to start earning.")
                    .font(TealeDesign.monoSmall)
                    .foregroundStyle(TealeDesign.muted)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(appState.wallet.recentTransactions.prefix(25).enumerated()), id: \.offset) { _, tx in
                        LedgerRow(transaction: tx)
                    }
                }
            }
        }
    }

    private func creditCountString(_ amount: USDCAmount) -> String {
        // Per reference_credit_ledger memory: 1 credit = $0.000001 — display
        // credits as a large integer so small earnings are visible at a glance.
        let credits = amount.value * 1_000_000
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 0
        return formatter.string(from: NSNumber(value: credits)) ?? String(Int(credits))
    }
}

private struct LedgerRow: View {
    let transaction: USDCTransaction

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(transaction.description)
                    .font(TealeDesign.mono)
                    .foregroundStyle(TealeDesign.text)
                    .lineLimit(2)
                Text(transaction.timestamp.formatted(date: .abbreviated, time: .shortened))
                    .font(TealeDesign.monoTiny)
                    .foregroundStyle(TealeDesign.muted)
            }
            Spacer(minLength: 8)
            Text(signedAmountText)
                .font(TealeDesign.mono)
                .foregroundStyle(isCredit ? TealeDesign.teale : TealeDesign.text)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(Rectangle().stroke(TealeDesign.border.opacity(0.6), lineWidth: 1))
    }

    private var signedAmountText: String {
        let amount = transaction.amount.description
        return isCredit ? "+\(amount)" : "-\(amount)"
    }

    private var isCredit: Bool {
        switch transaction.type {
        case .earned, .bonus, .sdkEarning: return true
        case .adjustment, .transfer: return transaction.amount.value >= 0
        case .spent, .platformFee: return false
        }
    }
}
