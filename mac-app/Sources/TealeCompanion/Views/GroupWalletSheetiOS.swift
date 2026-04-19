import SwiftUI
import ChatKit

struct GroupWalletSheetiOS: View {
    let conversation: Conversation
    let chatService: ChatService
    let currentUserID: UUID

    @Environment(\.dismiss) private var dismiss
    @State private var contributeAmount: String = "5"
    @State private var entries: [WalletLedgerEntry] = []
    @State private var balance: Double = 0
    @State private var errorMessage: String?

    @State private var autoEnabled: Bool = false
    @State private var threshold: String = "1"
    @State private var topUpAmount: String = "5"
    @State private var dailyCap: String = "20"

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Balance")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("$\(String(format: "%.2f", balance))")
                            .font(.system(size: 38, weight: .semibold, design: .rounded))
                            .foregroundStyle(Color.teale)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
                }

                Section("Contribute") {
                    HStack {
                        Text("$")
                            .foregroundStyle(.secondary)
                        decimalField($contributeAmount, placeholder: "Amount")
                    }
                    Button {
                        contribute()
                    } label: {
                        Text("Add to group wallet")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Color.teale)

                    if let errorMessage {
                        Text(errorMessage).font(.caption).foregroundStyle(.red)
                    }
                }

                Section {
                    Toggle("Auto top-up", isOn: $autoEnabled)
                    HStack {
                        Text("When below")
                        Spacer()
                        Text("$")
                        decimalField($threshold, placeholder: "")
                            .multilineTextAlignment(.trailing)
                            .frame(width: 60)
                    }
                    HStack {
                        Text("Top-up amount")
                        Spacer()
                        Text("$")
                        decimalField($topUpAmount, placeholder: "")
                            .multilineTextAlignment(.trailing)
                            .frame(width: 60)
                    }
                    HStack {
                        Text("Daily cap")
                        Spacer()
                        Text("$")
                        decimalField($dailyCap, placeholder: "")
                            .multilineTextAlignment(.trailing)
                            .frame(width: 60)
                    }
                    Button("Save rule", action: saveAutoTopUp)
                } header: {
                    Text("Auto top-up (this device only)")
                } footer: {
                    Text("Your device will automatically contribute when the group wallet drops below the threshold, up to the daily cap.")
                }

                Section("Ledger") {
                    if entries.isEmpty {
                        Text("No entries yet.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(entries.sorted(by: { $0.createdAt > $1.createdAt })) { entry in
                            ledgerRow(entry)
                        }
                    }
                }
            }
            .navigationTitle("Group Wallet")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .onAppear(perform: load)
        }
    }

    private func ledgerRow(_ entry: WalletLedgerEntry) -> some View {
        HStack(alignment: .top) {
            Image(systemName: icon(for: entry.kind))
                .foregroundStyle(color(for: entry.kind))
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.kind.rawValue.capitalized)
                    .font(.callout)
                if let memo = entry.memo {
                    Text(memo).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Text("\(entry.kind == .contribution ? "+" : "−")$\(String(format: "%.2f", entry.amount))")
                .font(.callout.weight(.semibold))
                .foregroundStyle(color(for: entry.kind))
        }
        .padding(.vertical, 4)
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

    @ViewBuilder
    private func decimalField(_ binding: Binding<String>, placeholder: String) -> some View {
        let field = TextField(placeholder, text: binding)
        #if os(iOS)
        field.keyboardType(.decimalPad)
        #else
        field
        #endif
    }

    private func load() {
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
                load()
            } else {
                errorMessage = "Contribution failed — insufficient funds?"
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
