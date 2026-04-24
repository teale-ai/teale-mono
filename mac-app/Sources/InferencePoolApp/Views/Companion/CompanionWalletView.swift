import SwiftUI
import AppCore
import CreditKit
import GatewayKit

struct CompanionWalletView: View {
    @Environment(AppState.self) private var appState
    @State private var recipient = ""
    @State private var amount = ""
    @State private var memo = ""
    @State private var isSending = false
    @State private var sendStatus = ""
    @State private var sendStatusIsError = false
    @State private var exportStatus = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            balancesSection
            sendSection
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

    private var sendSection: some View {
        TealeSection(prompt: "send") {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 12) {
                    CompanionFormField(title: "Recipient") {
                        TextField("device id, phone, email, or github username", text: $recipient)
                            .textFieldStyle(.plain)
                            .font(TealeDesign.mono)
                            .foregroundStyle(TealeDesign.text)
                    }

                    CompanionFormField(title: "Amount") {
                        TextField("0", text: $amount)
                            .textFieldStyle(.plain)
                            .font(TealeDesign.mono)
                            .foregroundStyle(TealeDesign.text)
                    }
                    .frame(width: 180)
                }

                CompanionFormField(title: "Memo") {
                    TextField("optional note", text: $memo)
                        .textFieldStyle(.plain)
                        .font(TealeDesign.mono)
                        .foregroundStyle(TealeDesign.text)
                }

                HStack(spacing: 10) {
                    TealeActionButton(
                        title: isSending ? "sending..." : "send",
                        primary: true,
                        disabled: !canSend
                    ) {
                        Task {
                            await sendCredits()
                        }
                    }
                    Text("Sends from this Mac's device wallet through the Teale gateway.")
                        .font(TealeDesign.monoSmall)
                        .foregroundStyle(TealeDesign.muted)
                }

                if !sendStatus.isEmpty {
                    Text(sendStatus)
                        .font(TealeDesign.monoSmall)
                        .foregroundStyle(sendStatusIsError ? TealeDesign.fail : TealeDesign.muted)
                }
            }
        }
    }

    private var ledgerSection: some View {
        TealeSection(prompt: "ledger") {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Spacer()
                    TealeActionButton(
                        title: "export csv",
                        disabled: appState.wallet.recentTransactions.isEmpty
                    ) {
                        exportLedgerCSV()
                    }
                }

                if !exportStatus.isEmpty {
                    Text(exportStatus)
                        .font(TealeDesign.monoSmall)
                        .foregroundStyle(TealeDesign.muted)
                }

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
    }

    private var canSend: Bool {
        !isSending && !recipient.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && parsedAmountCredits != nil
            && parsedAmountCredits ?? 0 <= currentCreditBalance
    }

    private var parsedAmountCredits: Int? {
        let trimmed = amount.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.allSatisfy(\.isNumber), let value = Int(trimmed), value > 0 else {
            return nil
        }
        return value
    }

    private var currentCreditBalance: Int {
        max(0, Int((appState.wallet.balance.value * 1_000_000).rounded()))
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

    @MainActor
    private func sendCredits() async {
        guard let amountCredits = parsedAmountCredits else {
            sendStatus = "Enter a whole-number credit amount."
            sendStatusIsError = true
            return
        }
        let trimmedRecipient = recipient.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedRecipient.isEmpty else {
            sendStatus = "Enter a recipient first."
            sendStatusIsError = true
            return
        }
        guard amountCredits <= currentCreditBalance else {
            sendStatus = "That exceeds this device wallet balance."
            sendStatusIsError = true
            return
        }

        isSending = true
        sendStatus = ""
        sendStatusIsError = false

        do {
            let memoText = memo.trimmingCharacters(in: .whitespacesAndNewlines)
            let request = GatewayWalletSendRequest(
                asset: "credits",
                recipient: trimmedRecipient,
                amount: amountCredits,
                memo: memoText.isEmpty ? nil : memoText
            )
            let client = GatewayAuthClient(baseURL: companionGatewayBaseURL())
            let token = try await client.bearer()
            let _: GatewayTransferReceipt = try await client.postJSON(
                path: "/v1/wallet/send",
                body: request,
                bearerToken: token
            )

            let localDebit = USDCAmount(Double(amountCredits) / 1_000_000.0)
            let description = request.memo.map { "Sent \(amountCredits) credits: \($0)" }
                ?? "Sent \(amountCredits) credits"
            await appState.wallet.recordAdjustmentDebit(
                amount: localDebit,
                description: description,
                peerNodeID: trimmedRecipient
            )

            recipient = ""
            amount = ""
            memo = ""
            sendStatus = "Sent \(amountCredits) credits."
            sendStatusIsError = false
        } catch {
            sendStatus = error.localizedDescription
            sendStatusIsError = true
        }

        isSending = false
    }

    private func exportLedgerCSV() {
        let formatter = ISO8601DateFormatter()
        let rows = appState.wallet.recentTransactions.map { tx in
            [
                tx.id.uuidString,
                formatter.string(from: tx.timestamp),
                tx.type.rawValue,
                String(tx.amount.value),
                tx.description,
                tx.peerNodeID ?? "",
                tx.modelID ?? "",
                tx.tokenCount.map(String.init) ?? "",
            ]
            .map(csvEscape)
            .joined(separator: ",")
        }

        let csv = ([
            "id,timestamp,type,amount_usdc,description,peer_node_id,model_id,token_count",
        ] + rows)
        .joined(separator: "\n")

        let filename = "teale-ledger-\(timestampSlug()).csv"
        let destination = preferredExportDirectory().appendingPathComponent(filename)

        do {
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: nil
            )
            try csv.write(to: destination, atomically: true, encoding: .utf8)
            exportStatus = "Exported CSV to \(destination.path)"
        } catch {
            exportStatus = "Could not export CSV: \(error.localizedDescription)"
        }
    }

    private func preferredExportDirectory() -> URL {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
    }

    private func timestampSlug() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HH-mm-ss"
        return formatter.string(from: Date())
    }

    private func csvEscape(_ value: String) -> String {
        "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
    }
}

private struct GatewayWalletSendRequest: Encodable {
    let asset: String
    let recipient: String
    let amount: Int
    let memo: String?
}

private struct GatewayTransferReceipt: Decodable {
    let asset: String
    let amount: Int64
}

private struct CompanionFormField<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased())
                .font(TealeDesign.monoSmall)
                .tracking(0.9)
                .foregroundStyle(TealeDesign.muted)
            content()
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(TealeDesign.cardStrong.opacity(0.85))
                .overlay(
                    Rectangle().stroke(TealeDesign.border.opacity(0.9), lineWidth: 1)
                )
        }
    }
}

private func companionGatewayBaseURL() -> URL {
    let fallback = URL(string: "https://gateway.teale.com")!
    let defaults = UserDefaults.standard
    let relayOverride = defaults.string(forKey: "teale.wanRelayURL")
        ?? defaults.string(forKey: "teale.wan_relay_url")
    guard
        let relayOverride,
        var components = URLComponents(string: relayOverride.replacingOccurrences(of: "wss://", with: "https://"))
    else {
        return fallback
    }

    if components.scheme == "ws" {
        components.scheme = "http"
    }
    if let host = components.host, host.hasPrefix("relay.") {
        components.host = host.replacingOccurrences(of: "relay.", with: "gateway.", options: .anchored)
    }
    components.path = ""
    components.query = nil
    components.fragment = nil
    return components.url ?? fallback
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
