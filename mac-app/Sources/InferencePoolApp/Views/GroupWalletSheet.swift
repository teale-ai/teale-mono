import SwiftUI
import ChatKit

struct GroupWalletSheet: View {
    let conversation: Conversation
    let chatService: ChatService
    let currentUserID: UUID

    @Environment(\.dismiss) private var dismiss
    @State private var contributeAmount: String = "5"
    @State private var entries: [WalletLedgerEntry] = []
    @State private var balance: Double = 0
    @State private var errorMessage: String?

    // Auto-top-up form state
    @State private var autoEnabled: Bool = false
    @State private var threshold: String = "1"
    @State private var topUpAmount: String = "5"
    @State private var dailyCap: String = "20"

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            Form {
                balanceSection
                contributeSection
                autoTopUpSection
                ledgerSection
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 560, height: 640)
        .onAppear(perform: loadState)
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Image(systemName: "creditcard.circle.fill")
                .foregroundStyle(Color(red: 0.0, green: 0.6, blue: 0.6))
                .font(.title)
            VStack(alignment: .leading, spacing: 2) {
                Text("Group Wallet")
                    .font(.title2.weight(.semibold))
                Text(conversation.displayTitle())
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    // MARK: - Balance

    private var balanceSection: some View {
        Section("Balance") {
            HStack {
                Text("$\(String(format: "%.2f", balance))")
                    .font(.largeTitle.weight(.semibold))
                    .foregroundStyle(Color(red: 0.0, green: 0.6, blue: 0.6))
                Spacer()
                Text("\(entries.count) entr\(entries.count == 1 ? "y" : "ies")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
        }
    }

    // MARK: - Contribute

    private var contributeSection: some View {
        Section("Contribute from your personal wallet") {
            HStack {
                Text("$")
                    .foregroundStyle(.secondary)
                TextField("Amount", text: $contributeAmount)
                    .textFieldStyle(.roundedBorder)
                Button("Contribute") {
                    contribute()
                }
                .buttonStyle(.borderedProminent)
            }
            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    // MARK: - Auto top-up

    private var autoTopUpSection: some View {
        Section("Auto top-up (this device only)") {
            Toggle("Enabled", isOn: $autoEnabled)
            HStack {
                Text("When balance drops below")
                Text("$")
                    .foregroundStyle(.secondary)
                TextField("Threshold", text: $threshold)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 80)
            }
            HStack {
                Text("Contribute")
                Text("$")
                    .foregroundStyle(.secondary)
                TextField("Top-up amount", text: $topUpAmount)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 80)
            }
            HStack {
                Text("Daily cap")
                Text("$")
                    .foregroundStyle(.secondary)
                TextField("Daily cap", text: $dailyCap)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 80)
            }
            HStack {
                Spacer()
                Button("Save rule", action: saveAutoTopUp)
                    .buttonStyle(.bordered)
            }
        }
    }

    // MARK: - Ledger

    private var ledgerSection: some View {
        Section("Ledger") {
            if entries.isEmpty {
                Text("No entries yet. Contributions and debits will appear here.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(entries.sorted(by: { $0.createdAt > $1.createdAt })) { entry in
                    HStack(alignment: .top) {
                        Image(systemName: icon(for: entry.kind))
                            .foregroundStyle(color(for: entry.kind))
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(entry.kind.rawValue.capitalized)
                                    .font(.callout.weight(.medium))
                                Spacer()
                                Text("\(entry.kind == .contribution ? "+" : "−")$\(String(format: "%.2f", entry.amount))")
                                    .font(.callout.weight(.semibold))
                                    .foregroundStyle(color(for: entry.kind))
                            }
                            if let memo = entry.memo {
                                Text(memo)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Text(entry.createdAt, style: .relative)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }

    private func icon(for kind: WalletLedgerEntryKind) -> String {
        switch kind {
        case .contribution: return "arrow.down.circle.fill"
        case .debit: return "arrow.up.circle.fill"
        case .withdrawal: return "arrow.uturn.up.circle.fill"
        }
    }

    private func color(for kind: WalletLedgerEntryKind) -> Color {
        switch kind {
        case .contribution: return .green
        case .debit: return .orange
        case .withdrawal: return .secondary
        }
    }

    // MARK: - Actions

    private func loadState() {
        let store = chatService.walletStore
        entries = store.entries(for: conversation.id)
        balance = store.balance(for: conversation.id)
        if let rule = store.autoTopUpRule(for: conversation.id) {
            autoEnabled = rule.enabled
            threshold = String(format: "%.2f", rule.thresholdAmount)
            topUpAmount = String(format: "%.2f", rule.topUpAmount)
            dailyCap = String(format: "%.2f", rule.dailyCap)
        }
    }

    private func contribute() {
        errorMessage = nil
        guard let amount = Double(contributeAmount.trimmingCharacters(in: .whitespaces)), amount > 0 else {
            errorMessage = "Enter a valid positive amount."
            return
        }
        Task {
            let success = await chatService.contributeToGroupWallet(
                amount: amount,
                conversationID: conversation.id,
                memo: "Manual contribution"
            )
            if success {
                loadState()
            } else {
                errorMessage = "Contribution failed — insufficient funds in personal wallet?"
            }
        }
    }

    private func saveAutoTopUp() {
        let store = chatService.walletStore
        let thr = Double(threshold) ?? 1
        let top = Double(topUpAmount) ?? 5
        let cap = Double(dailyCap) ?? 20
        var rule = store.autoTopUpRule(for: conversation.id) ?? AutoTopUpRule(conversationID: conversation.id)
        rule.thresholdAmount = thr
        rule.topUpAmount = top
        rule.dailyCap = cap
        rule.enabled = autoEnabled
        store.setAutoTopUpRule(rule)
    }
}
