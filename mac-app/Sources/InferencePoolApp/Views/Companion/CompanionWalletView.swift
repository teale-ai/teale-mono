import SwiftUI
import AppCore
import CreditKit
import GatewayKit

struct CompanionWalletView: View {
    @Environment(AppState.self) private var appState
    @State private var recipient = ""
    @State private var amount = ""
    @State private var memo = ""
    @State private var deviceCopied = false
    @State private var gatewayBalance: GatewayWalletBalanceSnapshot?
    @State private var gatewayTransactions: [GatewayWalletTransaction] = []
    @State private var gatewayWalletLoaded = false
    @State private var gatewayWalletError: String?
    @State private var isSending = false
    @State private var sendStatus = ""
    @State private var sendStatusIsError = false
    @State private var exportStatus = ""
    let refreshNonce: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            balancesSection
            sendSection
            ledgerSection
            if !appState.wallet.recentTransactions.isEmpty {
                localActivitySection
            }
        }
        .task(id: deviceID) {
            await refreshGatewayWallet()
        }
        .task(id: refreshNonce) {
            guard refreshNonce > 0 else { return }
            await refreshGatewayWallet()
        }
    }

    private var balancesSection: some View {
        TealeSection(prompt: appState.companionText("wallet.balances", fallback: "balances")) {
            TealeStats {
                TealeStatRow(
                    label: appState.companionDisplayUnitTitle,
                    value: appState.companionDisplayAmountString(credits: displayedBalanceCredits),
                    note: appState.companionSupplyIdentityStatus.walletBalanceNote
                )
                TealeStatRow(
                    label: appState.companionText("wallet.usdc", fallback: "USDC"),
                    value: displayedUSDCBalance
                )
                TealeStatRow(
                    label: appState.companionText("wallet.session", fallback: "Session"),
                    value: "\(appState.totalTokensGenerated) tokens served",
                    note: appState.companionSupplyIdentityStatus.sessionNote
                )
                TealeStatRow(
                    label: appState.companionText("wallet.lifetimeEarned", fallback: "Lifetime earned"),
                    value: appState.companionDisplayAmountString(credits: displayedEarnedCredits)
                )
                TealeStatRow(
                    label: appState.companionText("wallet.lifetimeSpent", fallback: "Lifetime spent"),
                    value: appState.companionDisplayAmountString(credits: displayedSpentCredits)
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
                TealeStatRow(
                    label: appState.companionText("wallet.gatewayEligibility", fallback: "Gateway eligibility"),
                    value: appState.companionSupplyIdentityStatus.eligibilityLabel,
                    note: appState.companionSupplyIdentityStatus.summary
                )
                TealeStatRow(
                    label: appState.companionText("wallet.relay", fallback: "Relay"),
                    value: appState.companionSupplyIdentityStatus.relayLabel,
                    note: "WAN node \(companionTruncatedIdentifier(appState.companionSupplyIdentityStatus.wanNodeID)) · identity \(appState.companionSupplyIdentityStatus.identityLabel)"
                )
                deviceIDRow
            }
        }
    }

    private var deviceIDRow: some View {
        HStack(alignment: .top, spacing: 20) {
            Text(appState.companionText("wallet.deviceWalletID", fallback: "Device wallet ID (to receive credits)").uppercased())
                .font(TealeDesign.monoSmall)
                .tracking(0.9)
                .foregroundStyle(TealeDesign.muted)
                .frame(width: 150, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Button(action: copyDeviceID) {
                    Text(truncatedDeviceID)
                        .font(TealeDesign.mono)
                        .foregroundStyle(TealeDesign.teale)
                }
                .buttonStyle(.plain)

                Text(deviceIDNote)
                    .font(TealeDesign.monoSmall)
                    .foregroundStyle(TealeDesign.muted)
            }
            Spacer(minLength: 0)
        }
    }

    private var sendSection: some View {
        TealeSection(prompt: appState.companionText("wallet.send", fallback: "send")) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 12) {
                    CompanionFormField(title: appState.companionText("wallet.recipient", fallback: "Recipient")) {
                        TextField(appState.companionText("wallet.recipientPlaceholder", fallback: "full device wallet id or account wallet id"), text: $recipient)
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
                    Text(appState.companionText("wallet.sendNote", fallback: "Use full wallet IDs only. This device wallet can send to a 64-char device wallet ID or a full account wallet ID through the Teale gateway."))
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
                        disabled: !gatewayWalletLoaded || displayedTransactions.isEmpty
                    ) {
                        exportLedgerCSV()
                    }
                }

                if !exportStatus.isEmpty {
                    Text(exportStatus)
                        .font(TealeDesign.monoSmall)
                        .foregroundStyle(TealeDesign.muted)
                }

                if let gatewayWalletError, !gatewayWalletError.isEmpty {
                    Text(gatewayWalletError)
                        .font(TealeDesign.monoSmall)
                        .foregroundStyle(TealeDesign.fail)
                } else if !gatewayWalletLoaded {
                    Text(appState.companionText("wallet.loadingGateway", fallback: "Loading the gateway-backed device wallet..."))
                        .font(TealeDesign.monoSmall)
                        .foregroundStyle(TealeDesign.muted)
                } else if displayedTransactions.isEmpty {
                    Text(appState.companionText("wallet.noTransactions", fallback: "No transactions yet. Supply a model to start earning."))
                        .font(TealeDesign.monoSmall)
                        .foregroundStyle(TealeDesign.muted)
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(displayedTransactions) { transaction in
                            if let gatewayTransaction = transaction.gateway {
                                GatewayLedgerRow(transaction: gatewayTransaction)
                            } else if let localTransaction = transaction.local {
                                LedgerRow(transaction: localTransaction)
                            }
                        }
                    }
                }
            }
        }
    }

    private var localActivitySection: some View {
        TealeSection(prompt: appState.companionText("wallet.localActivity", fallback: "local / lan activity")) {
            VStack(alignment: .leading, spacing: 12) {
                Text(appState.companionText(
                    "wallet.localActivityNote",
                    fallback: "These are device-local ledger events such as LAN transfers and local adjustments. They are shown separately from the gateway-backed Teale device wallet above."
                ))
                .font(TealeDesign.monoSmall)
                .foregroundStyle(TealeDesign.muted)

                VStack(alignment: .leading, spacing: 8) {
                    ForEach(appState.wallet.recentTransactions.prefix(10)) { transaction in
                        LedgerRow(transaction: transaction)
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
        max(0, Int(displayedBalanceCredits))
    }

    private var deviceID: String {
        GatewayIdentity.shared.deviceID
    }

    private var displayedBalanceCredits: Int64 {
        gatewayBalance?.balanceCredits ?? 0
    }

    private var displayedEarnedCredits: Int64 {
        gatewayBalance?.totalEarnedCredits ?? 0
    }

    private var displayedSpentCredits: Int64 {
        gatewayBalance?.totalSpentCredits ?? 0
    }

    private var displayedUSDCBalance: String {
        String(format: "$%.6f", Double(displayedBalanceCredits) / 1_000_000.0)
    }

    private var displayedTransactions: [WalletDisplayTransaction] {
        gatewayTransactions.prefix(25).map { WalletDisplayTransaction(gateway: $0) }
    }

    private var truncatedDeviceID: String {
        guard deviceID.count > 16 else { return deviceID }
        return "\(deviceID.prefix(8))...\(deviceID.suffix(8))"
    }

    private var deviceIDNote: String {
        if deviceCopied {
            return appState.companionText("wallet.deviceIDCopied", fallback: "Device wallet ID copied.")
        }
        return appState.companionText(
            "wallet.deviceIDNote",
            fallback: "Click to copy. Share this public device wallet ID when someone wants to send credits to this wallet."
        )
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
            await refreshGatewayWallet()
            sendStatus = "\(appState.companionText("wallet.sentPrefix", fallback: "Sent")) \(appState.companionDisplayAmountString(credits: amountCredits))."
            sendStatusIsError = false
        } catch {
            sendStatus = errorMessage(error)
            sendStatusIsError = true
        }

        isSending = false
    }

    private func exportLedgerCSV() {
        let formatter = ISO8601DateFormatter()
        let rows: [String]
        let header: String

        if gatewayWalletLoaded {
            header = "id,timestamp,type,amount_credits,note,ref_request_id"
            rows = gatewayTransactions.map { tx in
                [
                    String(tx.id),
                    formatter.string(from: tx.date),
                    tx.type,
                    String(tx.amount),
                    tx.note ?? "",
                    tx.refRequestID ?? "",
                ]
                .map(csvEscape)
                .joined(separator: ",")
            }
        } else {
            header = "id,timestamp,type,amount_usdc,description,peer_node_id,model_id,token_count"
            rows = appState.wallet.recentTransactions.map { tx in
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
        }

        let csv = ([header] + rows)
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

    private func copyDeviceID() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(deviceID, forType: .string)
        deviceCopied = true
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            deviceCopied = false
        }
    }

    @MainActor
    private func refreshGatewayWallet() async {
        do {
            let client = GatewayAuthClient(baseURL: companionGatewayRootURL(for: appState.gatewayFallbackURL))
            let token = try await walletBearer(using: client)
            var balance: GatewayWalletBalanceSnapshot
            do {
                balance = try await client.getJSON(
                    path: "/v1/wallet/balance",
                    bearerToken: token
                )
            } catch let GatewayAuthError.http(code, _) where code == 401 {
                appState.gatewayAPIKey = ""
                let refreshedToken = try await client.bearer()
                appState.gatewayAPIKey = refreshedToken
                balance = try await client.getJSON(
                    path: "/v1/wallet/balance",
                    bearerToken: refreshedToken
                )
            }
            gatewayBalance = balance
            gatewayWalletLoaded = true
            gatewayWalletError = nil

            do {
                gatewayTransactions = try await gatewayWalletTransactions(
                    using: client,
                    bearerToken: appState.gatewayAPIKey.isEmpty ? token : appState.gatewayAPIKey
                )
            } catch {
                gatewayTransactions = []
            }
        } catch {
            gatewayWalletLoaded = false
            gatewayBalance = nil
            gatewayTransactions = []
            gatewayWalletError = errorMessage(error)
        }
    }

    private func walletBearer(using client: GatewayAuthClient) async throws -> String {
        if !appState.gatewayAPIKey.isEmpty {
            return appState.gatewayAPIKey
        }
        let token = try await client.bearer()
        appState.gatewayAPIKey = token
        return token
    }

    private func errorMessage(_ error: Error) -> String {
        if let gatewayError = error as? GatewayAuthError {
            return gatewayError.description
        }
        return error.localizedDescription
    }

    private func gatewayWalletTransactions(
        using client: GatewayAuthClient,
        bearerToken: String
    ) async throws -> [GatewayWalletTransaction] {
        var components = URLComponents(url: client.base.appendingPathComponent("/v1/wallet/transactions"), resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "limit", value: "50"),
            URLQueryItem(name: "include_availability", value: "true"),
        ]
        guard let url = components?.url else {
            throw GatewayAuthError.network("invalid wallet transactions url")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await client.urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw GatewayAuthError.network("non-http response")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw GatewayAuthError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }

        return try JSONDecoder().decode(GatewayWalletTransactionsResponse.self, from: data).transactions
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

private struct GatewayWalletBalanceSnapshot: Decodable {
    let deviceID: String
    let balanceCredits: Int64
    let totalEarnedCredits: Int64
    let totalSpentCredits: Int64
    let usdcCents: Int64

    enum CodingKeys: String, CodingKey {
        case deviceID
        case balanceCredits = "balance_credits"
        case totalEarnedCredits = "total_earned_credits"
        case totalSpentCredits = "total_spent_credits"
        case usdcCents = "usdc_cents"
    }
}

private struct GatewayWalletTransactionsResponse: Decodable {
    let transactions: [GatewayWalletTransaction]
}

private struct GatewayWalletTransaction: Decodable, Identifiable {
    let id: Int64
    let deviceID: String
    let type: String
    let amount: Int64
    let timestamp: Int64
    let refRequestID: String?
    let note: String?

    enum CodingKeys: String, CodingKey {
        case id
        case deviceID = "device_id"
        case type
        case amount
        case timestamp
        case refRequestID
        case note
    }

    var date: Date {
        Date(timeIntervalSince1970: TimeInterval(timestamp))
    }
}

private struct WalletDisplayTransaction: Identifiable {
    let id = UUID()
    let local: USDCTransaction?
    let gateway: GatewayWalletTransaction?

    init(local: USDCTransaction) {
        self.local = local
        self.gateway = nil
    }

    init(gateway: GatewayWalletTransaction) {
        self.local = nil
        self.gateway = gateway
    }
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

private struct GatewayLedgerRow: View {
    @Environment(AppState.self) private var appState
    let transaction: GatewayWalletTransaction

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(descriptionText)
                    .font(TealeDesign.mono)
                    .foregroundStyle(TealeDesign.text)
                    .lineLimit(2)
                Text(transaction.date.formatted(date: .abbreviated, time: .shortened))
                    .font(TealeDesign.monoTiny)
                    .foregroundStyle(TealeDesign.muted)
            }
            Spacer(minLength: 8)
            Text(signedAmountText)
                .font(TealeDesign.mono)
                .foregroundStyle(transaction.amount >= 0 ? TealeDesign.teale : TealeDesign.text)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(Rectangle().stroke(TealeDesign.border.opacity(0.6), lineWidth: 1))
    }

    private var descriptionText: String {
        if let note = transaction.note, !note.isEmpty {
            return note
        }
        return transaction.type.replacingOccurrences(of: "_", with: " ")
    }

    private var signedAmountText: String {
        let amount = appState.companionDisplayAmountString(credits: abs(transaction.amount))
        return transaction.amount >= 0 ? "+\(amount)" : "-\(amount)"
    }
}
