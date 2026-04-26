import SwiftUI
import AppCore
import CreditKit
import GatewayKit
import AppKit

struct CompanionWalletView: View {
    @Environment(AppState.self) private var appState
    @Environment(CompanionGatewayState.self) private var gatewayState
    @State private var recipient = ""
    @State private var amount = ""
    @State private var memo = ""
    @State private var isSending = false
    @State private var sendStatus = ""
    @State private var sendStatusIsError = false
    @State private var exportStatus = ""
    @State private var deviceIDCopied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            balancesSection
            sendSection
            ledgerSection
        }
        .onAppear {
            applyPendingRecipientIfNeeded()
        }
        .onChange(of: gatewayState.pendingWalletRecipient) { _, _ in
            applyPendingRecipientIfNeeded()
        }
    }

    private var balancesSection: some View {
        TealeSection(prompt: appState.companionText("wallet.balances", fallback: "balances")) {
            VStack(alignment: .leading, spacing: 10) {
                TealeStats {
                    TealeStatRow(
                        label: appState.companionDisplayUnitTitle,
                        value: appState.companionDisplayAmountString(amount: appState.wallet.balance),
                        note: appState.companionText("wallet.balanceNote", fallback: "Balance goes up while supply is on.")
                    )
                    TealeStatRow(
                        label: appState.companionText("wallet.usdc", fallback: "USDC"),
                        value: appState.wallet.balance.description
                    )
                    TealeStatRow(
                        label: appState.companionText("wallet.session", fallback: "Session"),
                        value: "\(appState.totalTokensGenerated) tokens served",
                        note: appState.companionText("wallet.sessionNote", fallback: "Availability earnings begin once a compatible model is loaded and serving.")
                    )
                    TealeStatRow(
                        label: appState.companionText("wallet.lifetimeEarned", fallback: "Lifetime earned"),
                        value: appState.companionDisplayAmountString(amount: appState.wallet.totalEarned)
                    )
                    TealeStatRow(
                        label: appState.companionText("wallet.lifetimeSpent", fallback: "Lifetime spent"),
                        value: appState.companionDisplayAmountString(amount: appState.wallet.totalSpent)
                    )
                    TealeStatRow(
                        label: appState.companionText("wallet.requests", fallback: "Requests"),
                        value: "\(appState.totalRequestsServed)"
                    )
                    TealeStatRow(
                        label: appState.companionText("common.state", fallback: "State"),
                        value: appState.companionState.displayText,
                        valueColor: appState.companionState.chipColor
                    )
                }

                deviceIDRow
            }
        }
    }

    private var sendSection: some View {
        TealeSection(prompt: appState.companionText("wallet.send", fallback: "send")) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 12) {
                    CompanionFormField(title: appState.companionText("wallet.recipient", fallback: "Recipient")) {
                        TextField(appState.companionText("wallet.recipientPlaceholder", fallback: "device id, phone, email, or github username"), text: $recipient)
                            .textFieldStyle(.plain)
                            .font(TealeDesign.mono)
                            .foregroundStyle(TealeDesign.text)
                    }

                    CompanionFormField(title: appState.companionText("wallet.amount", fallback: "Amount")) {
                        TextField(appState.companionDisplayAmountPlaceholder, text: $amount)
                            .textFieldStyle(.plain)
                            .font(TealeDesign.mono)
                            .foregroundStyle(TealeDesign.text)
                    }
                    .frame(width: 180)
                }

                CompanionFormField(title: appState.companionText("wallet.memo", fallback: "Memo")) {
                    TextField(appState.companionText("wallet.memoPlaceholder", fallback: "optional note"), text: $memo)
                        .textFieldStyle(.plain)
                        .font(TealeDesign.mono)
                        .foregroundStyle(TealeDesign.text)
                }

                HStack(spacing: 10) {
                    TealeActionButton(
                        title: isSending
                            ? appState.companionText("wallet.sending", fallback: "sending...")
                            : appState.companionText("wallet.sendAction", fallback: "send"),
                        primary: true,
                        disabled: !canSend
                    ) {
                        Task {
                            await sendCredits()
                        }
                    }
                    Text(appState.companionText("wallet.sendNote", fallback: "Sends from this Mac's device wallet through the Teale gateway."))
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
        TealeSection(prompt: appState.companionText("wallet.ledger", fallback: "ledger")) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Spacer()
                    TealeActionButton(
                        title: appState.companionText("wallet.exportCSV", fallback: "export csv"),
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
                    Text(appState.companionText("wallet.noTransactions", fallback: "No transactions yet. Supply a model to start earning."))
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
        appState.companionParseDisplayAmountToCredits(amount)
    }

    private var currentCreditBalance: Int {
        max(0, Int((appState.wallet.balance.value * 1_000_000).rounded()))
    }

    private var deviceIDRow: some View {
        HStack(alignment: .top, spacing: 20) {
            Text(appState.companionText("wallet.deviceID", fallback: "Device ID").uppercased())
                .font(TealeDesign.monoSmall)
                .tracking(0.9)
                .foregroundStyle(TealeDesign.muted)
                .frame(width: 150, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Button(action: copyDeviceID) {
                    Text(companionTruncatedIdentifier(gatewayState.localDeviceID))
                        .font(TealeDesign.mono)
                        .foregroundStyle(TealeDesign.teale)
                }
                .buttonStyle(.plain)

                Text(deviceIDCopied
                    ? appState.companionText("wallet.deviceIDCopied", fallback: "Device ID copied.")
                    : appState.companionText("wallet.deviceIDNote", fallback: "Use this Teale device ID to receive credits into this device wallet."))
                    .font(TealeDesign.monoSmall)
                    .foregroundStyle(TealeDesign.muted)
            }
            Spacer(minLength: 0)
        }
    }

    @MainActor
    private func sendCredits() async {
        guard let amountCredits = parsedAmountCredits else {
            sendStatus = appState.companionDisplayUnit == .credits
                ? appState.companionText("wallet.enterCredits", fallback: "Enter a whole-number credit amount.")
                : appState.companionText("wallet.enterUSD", fallback: "Enter a USD amount greater than 0.")
            sendStatusIsError = true
            return
        }
        let trimmedRecipient = recipient.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedRecipient.isEmpty else {
            sendStatus = appState.companionText("wallet.enterRecipient", fallback: "Enter a recipient first.")
            sendStatusIsError = true
            return
        }
        guard amountCredits <= currentCreditBalance else {
            sendStatus = appState.companionText("wallet.exceedsBalance", fallback: "That exceeds this device wallet balance.")
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
            let client = GatewayAuthClient(baseURL: companionGatewayRootURL(for: appState.gatewayFallbackURL))
            let token = try await client.bearer()
            let _: GatewayTransferReceipt = try await client.postJSON(
                path: "/v1/wallet/send",
                body: request,
                bearerToken: token
            )

            let localDebit = USDCAmount(Double(amountCredits) / 1_000_000.0)
            let sentLabel = appState.companionDisplayAmountString(credits: amountCredits)
            let description = request.memo.map { "Sent \(sentLabel): \($0)" }
                ?? "Sent \(sentLabel)"
            await appState.wallet.recordAdjustmentDebit(
                amount: localDebit,
                description: description,
                peerNodeID: trimmedRecipient
            )

            recipient = ""
            amount = ""
            memo = ""
            sendStatus = "\(appState.companionText("wallet.sentPrefix", fallback: "Sent")) \(appState.companionDisplayAmountString(credits: amountCredits))."
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
            exportStatus = "\(appState.companionText("wallet.exportedCSV", fallback: "Exported CSV to")) \(destination.path)"
        } catch {
            exportStatus = "\(appState.companionText("wallet.exportFailed", fallback: "Could not export CSV:")) \(error.localizedDescription)"
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

    private func copyDeviceID() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(gatewayState.localDeviceID, forType: .string)
        deviceIDCopied = true
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            deviceIDCopied = false
        }
    }

    private func applyPendingRecipientIfNeeded() {
        guard let pendingRecipient = gatewayState.consumePendingWalletRecipient() else { return }
        recipient = pendingRecipient
        sendStatus = ""
        sendStatusIsError = false
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

private struct LedgerRow: View {
    @Environment(AppState.self) private var appState
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
        let amount = appState.companionDisplayAmountString(amount: transaction.amount)
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
