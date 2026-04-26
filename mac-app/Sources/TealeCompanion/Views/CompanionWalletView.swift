import SwiftUI
import CreditKit
import GatewayKit
#if os(iOS)
import UIKit
#else
import AppKit
#endif

struct CompanionWalletView: View {
    var appState: CompanionAppState

    @State private var gatewayBalance: GwBalance?
    @State private var gatewayTransactions: [GwLedgerEntry] = []
    @State private var gatewayError: String?
    @State private var isLoadingGateway = false
    @State private var recipient = ""
    @State private var amount = ""
    @State private var memo = ""
    @State private var isSending = false
    @State private var sendStatus = ""
    @State private var sendStatusIsError = false
    @State private var deviceIDCopied = false

    var body: some View {
        NavigationStack {
            List {
                gatewayWalletSection
                gatewaySendSection
                accountDevicesSection

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

                Section("Activity") {
                    earningsChart
                }

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

                Section {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: "lightbulb.fill")
                            .foregroundStyle(.yellow)
                            .font(.title3)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("How credits work")
                                .font(.subheadline)
                                .fontWeight(.medium)
                            Text("You earn credits by contributing inference compute on your Mac. Spending credits lets you use other nodes from this iOS app. Run the Teale macOS app to start earning.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
            .navigationTitle("Wallet")
            .onAppear {
                applyPendingRecipientIfNeeded()
                Task {
                    await refreshGatewayData(force: false)
                }
            }
            .refreshable {
                await refreshGatewayData(force: true)
            }
            .onChange(of: appState.gatewayAccount.pendingWalletRecipient) { _, _ in
                applyPendingRecipientIfNeeded()
            }
        }
    }

    private var gatewayWalletSection: some View {
        Section("Teale Device Wallet") {
            if let gatewayBalance {
                LabeledContent("Device ID") {
                    Button {
                        copyDeviceID()
                    } label: {
                        Text(shortDeviceID(gatewayBalance.deviceID))
                            .font(.system(.body, design: .monospaced).weight(.semibold))
                            .foregroundStyle(Color.teale)
                    }
                    .buttonStyle(.plain)
                }

                if deviceIDCopied {
                    Text("Device ID copied.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Tap the device ID to copy the full Teale recipient for this device wallet.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                LabeledContent("Balance") {
                    Text(formatCredits(gatewayBalance.balance_credits))
                        .monospacedDigit()
                }
                LabeledContent("Earned") {
                    Text(formatCredits(gatewayBalance.total_earned_credits))
                        .monospacedDigit()
                }
                LabeledContent("Spent") {
                    Text(formatCredits(gatewayBalance.total_spent_credits))
                        .monospacedDigit()
                }
                LabeledContent("USDC") {
                    Text(String(format: "$%.2f", Double(gatewayBalance.usdc_cents) / 100.0))
                        .monospacedDigit()
                }

                if gatewayTransactions.isEmpty {
                    Text("No gateway wallet activity yet.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(gatewayTransactions.prefix(10)) { tx in
                        GatewayTransactionRow(tx: tx)
                    }
                }
            } else if isLoadingGateway {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Loading gateway wallet...")
                        .foregroundStyle(.secondary)
                }
            } else if let gatewayError {
                Label(gatewayError, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
            } else {
                Text("Waiting for the gateway wallet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var gatewaySendSection: some View {
        Section("Send Credits") {
            TextField("Recipient device ID, phone, email, or GitHub username", text: $recipient)
                .font(Font.system(.body, design: .monospaced))

            TextField("Credits", text: $amount)
                #if os(iOS)
                .keyboardType(.numberPad)
                #endif
                .font(Font.system(.body, design: .monospaced))

            TextField("Memo (optional)", text: $memo)

            Button(isSending ? "Sending..." : "Send") {
                Task {
                    await sendCredits()
                }
            }
            .disabled(!canSend)

            Text("Sends route through this device bearer and land in the target device wallet when the recipient is a Teale device ID.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if !sendStatus.isEmpty {
                Text(sendStatus)
                    .font(.caption)
                    .foregroundStyle(sendStatusIsError ? .red : .secondary)
            }
        }
    }

    private var accountDevicesSection: some View {
        Section("Account Devices") {
            if appState.gatewayAccount.isLoading && appState.gatewayAccount.summary == nil {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Loading Teale device wallets...")
                        .foregroundStyle(.secondary)
                }
            } else if let error = appState.gatewayAccount.errorMessage,
                      appState.gatewayAccount.summary == nil {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
            } else if let devices = appState.gatewayAccount.summary?.devices,
                      !devices.isEmpty {
                ForEach(devices) { device in
                    GatewayAccountDeviceRow(
                        device: device,
                        localDeviceID: appState.gatewayAccount.localDeviceID,
                        onUseRecipient: { deviceID in
                            recipient = deviceID
                            sendStatus = ""
                            sendStatusIsError = false
                        }
                    )
                }
            } else {
                Text("No Teale device wallets linked to this account yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var totalEarned: Double {
        appState.transactions.filter(\.isEarning).reduce(0) { $0 + $1.amount }
    }

    private var totalSpent: Double {
        appState.transactions.filter { !$0.isEarning }.reduce(0) { $0 + $1.amount }
    }

    private var canSend: Bool {
        !isSending
            && !recipient.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && parsedAmountCredits != nil
            && (parsedAmountCredits ?? 0) > 0
            && (parsedAmountCredits ?? 0) <= (gatewayBalance?.balance_credits ?? 0)
    }

    private var parsedAmountCredits: Int64? {
        let trimmed = amount
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ",", with: "")
        return Int64(trimmed)
    }

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

            GeometryReader { geo in
                let maxVal = max(totalEarned, totalSpent, 1)
                HStack(spacing: 4) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(.green.opacity(0.7))
                        .frame(width: geo.size.width * 0.48 * (totalEarned / maxVal))

                    Spacer()

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

    @MainActor
    private func refreshGatewayData(force: Bool) async {
        isLoadingGateway = true
        defer { isLoadingGateway = false }

        await appState.gatewayAccount.refreshIfNeeded(
            authManager: appState.authManager,
            deviceName: appState.displayName,
            force: force
        )

        let client = GatewayWalletClient(auth: GatewayAuthClient())
        do {
            async let balanceTask = client.balance()
            async let txTask = client.transactions(limit: 25)
            gatewayBalance = try await balanceTask
            gatewayTransactions = try await txTask
            gatewayError = nil
        } catch {
            gatewayError = error.localizedDescription
        }
    }

    @MainActor
    private func sendCredits() async {
        guard let amountCredits = parsedAmountCredits, amountCredits > 0 else {
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

        guard amountCredits <= gatewayBalance?.balance_credits ?? 0 else {
            sendStatus = "That exceeds this device wallet balance."
            sendStatusIsError = true
            return
        }

        isSending = true
        sendStatus = ""
        sendStatusIsError = false

        do {
            let client = GatewayWalletClient(auth: GatewayAuthClient())
            let memoText = memo.trimmingCharacters(in: .whitespacesAndNewlines)
            try await client.send(
                GwWalletSendRequest(
                    asset: "credits",
                    recipient: trimmedRecipient,
                    amount: amountCredits,
                    memo: memoText.isEmpty ? nil : memoText
                )
            )
            recipient = ""
            amount = ""
            memo = ""
            sendStatus = "Sent \(formatCredits(amountCredits))."
            await refreshGatewayData(force: true)
        } catch {
            sendStatus = error.localizedDescription
            sendStatusIsError = true
        }

        isSending = false
    }

    private func applyPendingRecipientIfNeeded() {
        guard let pendingRecipient = appState.gatewayAccount.consumePendingWalletRecipient() else { return }
        recipient = pendingRecipient
        sendStatus = ""
        sendStatusIsError = false
    }

    private func copyDeviceID() {
        copyText(gatewayBalance?.deviceID ?? appState.gatewayAccount.localDeviceID)
        deviceIDCopied = true
        Task {
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            deviceIDCopied = false
        }
    }

    private func shortDeviceID(_ value: String) -> String {
        guard value.count > 16 else { return value }
        return "\(value.prefix(8))...\(value.suffix(8))"
    }

    private func formatCredits(_ credits: Int64) -> String {
        "\(credits.formatted()) credits"
    }

    private func copyText(_ value: String) {
        #if os(iOS)
        UIPasteboard.general.string = value
        #else
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
        #endif
    }
}

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

            Text("\(transaction.isEarning ? "+" : "-")\(USDCAmount(transaction.amount).description)")
                .font(.subheadline)
                .fontWeight(.medium)
                .foregroundStyle(transaction.isEarning ? .green : .orange)
        }
    }
}

private struct GatewayTransactionRow: View {
    let tx: GwLedgerEntry

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(tx.type.replacingOccurrences(of: "_", with: " ").capitalized)
                    .font(.subheadline.weight(.medium))
                Text(tx.note ?? "—")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Text("\(tx.amount >= 0 ? "+" : "")\(tx.amount.formatted())")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(tx.amount >= 0 ? .green : .orange)
                .monospacedDigit()
        }
    }
}

private struct GatewayAccountDeviceRow: View {
    let device: CompanionGatewayAccountDevice
    let localDeviceID: String
    let onUseRecipient: (String) -> Void

    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(device.deviceName ?? shortDeviceID(device.deviceID))
                        .font(.subheadline.weight(.semibold))
                    Text(platformLine)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text("\(device.walletBalanceCredits.formatted()) credits")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Color.teale)
                    .monospacedDigit()
            }

            Button {
                copyText(device.deviceID)
                copied = true
                Task {
                    try? await Task.sleep(nanoseconds: 1_200_000_000)
                    copied = false
                }
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(shortDeviceID(device.deviceID))
                        .font(.system(.body, design: .monospaced).weight(.semibold))
                    Text(copied ? "Device ID copied." : "Tap to copy the full Teale device ID.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)

            Button("Send Credits") {
                onUseRecipient(device.deviceID)
            }
            .buttonStyle(.bordered)
        }
        .padding(.vertical, 4)
    }

    private var platformLine: String {
        let platform = device.platform ?? "device"
        if device.deviceID == localDeviceID {
            return "\(platform) · this device"
        }
        return platform
    }

    private func shortDeviceID(_ value: String) -> String {
        guard value.count > 16 else { return value }
        return "\(value.prefix(8))...\(value.suffix(8))"
    }

    private func copyText(_ value: String) {
        #if os(iOS)
        UIPasteboard.general.string = value
        #else
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
        #endif
    }
}
