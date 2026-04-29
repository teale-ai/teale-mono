import SwiftUI
import AppKit
import AppCore
import AuthKit
import SharedTypes

struct CompanionAccountView: View {
    @Environment(AppState.self) private var appState
    @State private var authNotice: String?
    @State private var accountState = CompanionAccountState()
    @State private var recipient = ""
    @State private var amount = ""
    @State private var memo = ""
    @State private var apiKeyLabel = ""
    let refreshNonce: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            accountSection
            accountWalletSection
            apiKeysSection
            sendSection
            detailsSection
            devicesSection
            ledgerSection
        }
        .task(id: accountRefreshKey) {
            await accountState.refresh(appState: appState, authManager: authManager)
        }
        .task(id: refreshNonce) {
            guard refreshNonce > 0 else { return }
            await accountState.refresh(appState: appState, authManager: authManager)
        }
    }

    private var apiKeysSection: some View {
        TealeSection(prompt: appState.companionText("account.apiKeys", fallback: "direct gateway api keys")) {
            if !isSignedIn {
                signedOutMessage
            } else if accountState.snapshot == nil {
                unavailableWalletMessage
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    Text(appState.companionText(
                        "account.apiKeysNote",
                        fallback: "Create revocable API keys for direct demand traffic to gateway.teale.com. These keys belong to your human account and stay valid until you revoke them."
                    ))
                    .font(TealeDesign.monoSmall)
                    .foregroundStyle(TealeDesign.muted)

                    HStack(alignment: .bottom, spacing: 12) {
                        AccountFormField(title: appState.companionText("account.apiKeyLabel", fallback: "Label")) {
                            TextField(
                                appState.companionText("account.apiKeyLabelPlaceholder", fallback: "optional name like claude code"),
                                text: $apiKeyLabel
                            )
                            .textFieldStyle(.plain)
                            .font(TealeDesign.mono)
                            .foregroundStyle(TealeDesign.text)
                        }

                        TealeActionButton(
                            title: accountState.isCreatingAPIKey
                                ? appState.companionText("account.creatingAPIKey", fallback: "creating...")
                                : appState.companionText("account.createAPIKey", fallback: "create api key"),
                            primary: true,
                            disabled: accountState.isCreatingAPIKey
                        ) {
                            Task { await createAPIKey() }
                        }
                    }

                    if let createdAPIToken = accountState.createdAPIToken, !createdAPIToken.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(appState.companionText(
                                "account.apiKeyShownOnce",
                                fallback: "This raw API key is only shown once. Copy it now for direct gateway clients."
                            ))
                            .font(TealeDesign.monoSmall)
                            .foregroundStyle(TealeDesign.muted)
                            TealeCodeBlock(text: createdAPIToken)
                            HStack(spacing: 10) {
                                TealeActionButton(title: appState.companionText("account.copyAPIKey", fallback: "copy api key")) {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(createdAPIToken, forType: .string)
                                }
                            }
                        }
                    }

                    if !accountState.apiKeys.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(accountState.apiKeys) { apiKey in
                                AccountAPIKeyRow(
                                    apiKey: apiKey,
                                    isRevoking: accountState.revokingAPIKeyID == apiKey.keyID,
                                    onRevoke: {
                                        Task {
                                            await accountState.revokeAPIKey(
                                                keyID: apiKey.keyID,
                                                appState: appState,
                                                authManager: authManager
                                            )
                                        }
                                    }
                                )
                            }
                        }
                    } else {
                        Text(appState.companionText(
                            "account.noAPIKeys",
                            fallback: "No direct gateway API keys created yet."
                        ))
                        .font(TealeDesign.monoSmall)
                        .foregroundStyle(TealeDesign.muted)
                    }

                    if !accountState.apiKeyStatus.isEmpty {
                        Text(accountState.apiKeyStatus)
                            .font(TealeDesign.monoSmall)
                            .foregroundStyle(accountState.apiKeyStatusIsError ? TealeDesign.fail : TealeDesign.muted)
                    }
                }
            }
        }
    }

    private var authManager: AuthManager? { appState.authManager }
    private var authState: AuthState { authManager?.authState ?? .signedOut }
    private var isSignedIn: Bool { authState.isAuthenticated }
    private var authIsConfigured: Bool { authManager != nil }

    private var accountRefreshKey: String {
        if let user = authManager?.currentUser, isSignedIn {
            return user.id.uuidString
        }
        return "signed-out"
    }

    private var currentAccountBalance: Int {
        max(0, Int(accountState.snapshot?.balanceCredits ?? 0))
    }

    private var parsedAmountCredits: Int? {
        appState.companionParseDisplayAmountToCredits(amount)
    }

    private var canSend: Bool {
        !accountState.isSending &&
        !recipient.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        parsedAmountCredits != nil &&
        parsedAmountCredits ?? 0 <= currentAccountBalance &&
        accountState.snapshot != nil
    }

    private var accountStatus: String {
        if isSignedIn {
            return appState.companionText("account.signedIn", fallback: "Signed in")
        }
        return authIsConfigured
            ? appState.companionText("account.notSignedIn", fallback: "Not signed in")
            : appState.companionText("account.authUnavailable", fallback: "Auth unavailable")
    }

    private var statusNote: String {
        if let authNotice, !authNotice.isEmpty {
            return authNotice
        }
        if let user = authManager?.currentUser {
            return user.email ?? user.phone ?? user.id.uuidString
        }
        if authIsConfigured {
            return appState.companionText("account.notSignedIn", fallback: "Not signed in")
        }
        return appState.companionText("account.authUnavailableDetail", fallback: "Sign-in is unavailable in this build.")
    }

    private var accountSection: some View {
        TealeSection(prompt: appState.companionText("account.account", fallback: "account")) {
            TealeStats {
                TealeStatRow(
                    label: appState.companionText("account.status", fallback: "Status"),
                    value: accountStatus,
                    note: statusNote
                )
            }

            if authIsConfigured {
                if !isSignedIn {
                    HStack(spacing: 10) {
                        TealeActionButton(title: appState.companionText("account.signIn", fallback: "Sign in"), primary: true) {
                            openSignIn()
                        }
                    }
                    .padding(.top, 6)
                } else {
                    HStack(spacing: 10) {
                        TealeActionButton(title: appState.companionText("account.signOut", fallback: "Sign out")) {
                            Task {
                                await authManager?.signOut()
                            }
                        }
                    }
                    .padding(.top, 6)
                }
            }

            Text(appState.companionText(
                "account.linkNote",
                fallback: "Sign in to link this machine to a person. Device wallet earnings continue working without human sign-in."
            ))
            .font(TealeDesign.monoSmall)
            .foregroundStyle(TealeDesign.muted)
            .padding(.top, 8)

            if let syncNotice = accountState.syncNotice, !syncNotice.isEmpty {
                Text(syncNotice)
                    .font(TealeDesign.monoSmall)
                    .foregroundStyle(accountState.syncNoticeIsError ? TealeDesign.fail : TealeDesign.muted)
                    .padding(.top, 6)
            }
        }
    }

    private var accountWalletSection: some View {
        TealeSection(prompt: appState.companionText("account.wallet", fallback: "account wallet")) {
            if !isSignedIn {
                signedOutMessage
            } else if accountState.loading && accountState.snapshot == nil {
                loadingMessage
            } else if let snapshot = accountState.snapshot {
                TealeStats {
                    TealeStatRow(
                        label: appState.companionText("account.walletBalance", fallback: "Account balance"),
                        value: appState.companionDisplayAmountString(credits: snapshot.balanceCredits),
                        note: appState.companionText(
                            "account.walletBalanceNote",
                            fallback: "Sweeps from linked device wallets land here first."
                        )
                    )
                    TealeStatRow(
                        label: appState.companionText("account.walletUSDC", fallback: "USDC"),
                        value: accountUSDCLabel(snapshot.usdcCents)
                    )
                }
                .padding(.bottom, 10)

                CopyableIdentifierRow(
                    label: appState.companionText("account.accountWalletID", fallback: "Account wallet ID"),
                    value: snapshot.accountUserID,
                    copiedLabel: appState.companionText("account.accountWalletCopied", fallback: "Account wallet ID copied."),
                    note: appState.companionText(
                        "account.accountWalletIDNote",
                        fallback: "Click to copy. Share this full account wallet ID when someone should send credits into the account wallet."
                    )
                )
            } else {
                unavailableWalletMessage
            }
        }
    }

    private var sendSection: some View {
        TealeSection(prompt: appState.companionText("account.send", fallback: "send from account wallet")) {
            if !isSignedIn {
                signedOutMessage
            } else if accountState.snapshot == nil {
                unavailableWalletMessage
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .top, spacing: 12) {
                        AccountFormField(title: appState.companionText("wallet.recipient", fallback: "Recipient")) {
                            TextField(
                                appState.companionText(
                                    "account.recipientPlaceholder",
                                    fallback: "full device wallet id or account wallet id"
                                ),
                                text: $recipient
                            )
                            .textFieldStyle(.plain)
                            .font(TealeDesign.mono)
                            .foregroundStyle(TealeDesign.text)
                        }

                        AccountFormField(title: appState.companionText("wallet.amount", fallback: "Amount")) {
                            TextField(appState.companionDisplayAmountPlaceholder, text: $amount)
                                .textFieldStyle(.plain)
                                .font(TealeDesign.mono)
                                .foregroundStyle(TealeDesign.text)
                        }
                        .frame(width: 180)
                    }

                    AccountFormField(title: appState.companionText("wallet.memo", fallback: "Memo")) {
                        TextField(appState.companionText("wallet.memoPlaceholder", fallback: "optional note"), text: $memo)
                            .textFieldStyle(.plain)
                            .font(TealeDesign.mono)
                            .foregroundStyle(TealeDesign.text)
                    }

                    HStack(spacing: 10) {
                        TealeActionButton(
                            title: accountState.isSending
                                ? appState.companionText("wallet.sending", fallback: "sending...")
                                : appState.companionText("wallet.sendAction", fallback: "send"),
                            primary: true,
                            disabled: !canSend
                        ) {
                            Task { await sendFromAccountWallet() }
                        }

                        Text(appState.companionText(
                            "account.sendNote",
                            fallback: "Use full wallet IDs only. This account wallet can send to a full account wallet ID or a 64-char device wallet ID."
                        ))
                        .font(TealeDesign.monoSmall)
                        .foregroundStyle(TealeDesign.muted)
                    }

                    if !accountState.sendStatus.isEmpty {
                        Text(accountState.sendStatus)
                            .font(TealeDesign.monoSmall)
                            .foregroundStyle(accountState.sendStatusIsError ? TealeDesign.fail : TealeDesign.muted)
                    }
                }
            }
        }
    }

    private var detailsSection: some View {
        TealeSection(prompt: appState.companionText("account.details", fallback: "details")) {
            TealeStats {
                TealeStatRow(label: appState.companionText("account.userID", fallback: "User ID"), value: authManager?.currentUser?.id.uuidString ?? "-")
                TealeStatRow(label: appState.companionText("account.email", fallback: "Email"), value: authManager?.currentUser?.email ?? "-")
                TealeStatRow(label: appState.companionText("account.phone", fallback: "Phone"), value: authManager?.currentUser?.phone ?? "-")
                TealeStatRow(label: appState.companionText("account.device", fallback: "Device"), value: appState.companionDeviceName)
                TealeStatRow(label: appState.companionText("account.hardware", fallback: "Hardware"), value: appState.companionRAMLabel)
            }
        }
    }

    private var devicesSection: some View {
        TealeSection(prompt: appState.companionText("account.devices", fallback: "devices")) {
            if !isSignedIn {
                signedOutMessage
            } else if accountState.loading && accountState.snapshot == nil {
                loadingMessage
            } else if let devices = accountState.snapshot?.devices, !devices.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(devices) { device in
                        AccountWalletDeviceRow(
                            device: device,
                            balanceText: appState.companionDisplayAmountString(credits: device.walletBalanceCredits),
                            isSweeping: accountState.sweepingDeviceID == device.deviceID,
                            onSweep: {
                                Task {
                                    await accountState.sweep(
                                        deviceID: device.deviceID,
                                        appState: appState,
                                        authManager: authManager
                                    )
                                }
                            }
                        )
                    }
                }

                if !accountState.sweepStatus.isEmpty {
                    Text(accountState.sweepStatus)
                        .font(TealeDesign.monoSmall)
                        .foregroundStyle(accountState.sweepStatusIsError ? TealeDesign.fail : TealeDesign.muted)
                        .padding(.top, 10)
                }
            } else {
                Text(appState.companionText("account.noDevices", fallback: "No linked devices found yet."))
                    .font(TealeDesign.monoSmall)
                    .foregroundStyle(TealeDesign.muted)
            }
        }
    }

    private var ledgerSection: some View {
        TealeSection(prompt: appState.companionText("account.ledger", fallback: "account ledger")) {
            if !isSignedIn {
                signedOutMessage
            } else if accountState.loading && accountState.snapshot == nil {
                loadingMessage
            } else if let transactions = accountState.snapshot?.transactions, !transactions.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(transactions.prefix(25))) { transaction in
                        AccountLedgerRow(transaction: transaction)
                    }
                }
            } else {
                Text(appState.companionText(
                    "account.noTransactions",
                    fallback: "No account-wallet transfers or sweeps have landed yet."
                ))
                .font(TealeDesign.monoSmall)
                .foregroundStyle(TealeDesign.muted)
            }
        }
    }

    private var signedOutMessage: some View {
        Text(appState.companionText("account.signInForWallet", fallback: "Sign in to load the account wallet."))
            .font(TealeDesign.monoSmall)
            .foregroundStyle(TealeDesign.muted)
    }

    private var loadingMessage: some View {
        Text(appState.companionText(
            "account.loadingWallet",
            fallback: "Syncing the gateway account wallet for this signed-in device."
        ))
        .font(TealeDesign.monoSmall)
        .foregroundStyle(TealeDesign.muted)
    }

    private var unavailableWalletMessage: some View {
        Text(
            accountState.syncNotice
                ?? appState.companionText(
                    "account.unavailableWallet",
                    fallback: "The gateway account wallet is not available yet for this device."
                )
        )
        .font(TealeDesign.monoSmall)
        .foregroundStyle(accountState.syncNoticeIsError ? TealeDesign.fail : TealeDesign.muted)
    }

    private func openSignIn() {
        guard let authManager else {
            authNotice = appState.companionText("account.authUnavailableDetail", fallback: "Sign-in is unavailable in this build.")
            return
        }

        authNotice = nil
        appState.showSignIn = true
        LoginWindowController.shared.show(authManager: authManager, appState: appState)
    }

    @MainActor
    private func sendFromAccountWallet() async {
        guard let amountCredits = parsedAmountCredits else {
            accountState.sendStatus = appState.companionDisplayUnit == .credits
                ? appState.companionText("wallet.enterCredits", fallback: "Enter a whole-number credit amount.")
                : appState.companionText("wallet.enterUSD", fallback: "Enter a USD amount greater than 0.")
            accountState.sendStatusIsError = true
            return
        }

        let trimmedRecipient = recipient.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedRecipient.isEmpty else {
            accountState.sendStatus = appState.companionText("wallet.enterRecipient", fallback: "Enter a recipient first.")
            accountState.sendStatusIsError = true
            return
        }

        guard amountCredits <= currentAccountBalance else {
            accountState.sendStatus = appState.companionText(
                "account.exceedsBalance",
                fallback: "That exceeds this account wallet balance."
            )
            accountState.sendStatusIsError = true
            return
        }

        await accountState.send(
            recipient: trimmedRecipient,
            amountCredits: amountCredits,
            memo: memo,
            appState: appState,
            authManager: authManager
        )

        if !accountState.sendStatusIsError {
            recipient = ""
            amount = ""
            memo = ""
        }
    }

    private func accountUSDCLabel(_ usdcCents: Int64) -> String {
        String(format: "$%.2f", Double(usdcCents) / 100.0)
    }

    @MainActor
    private func createAPIKey() async {
        await accountState.createAPIKey(
            label: apiKeyLabel,
            appState: appState,
            authManager: authManager
        )
        if !accountState.apiKeyStatusIsError, accountState.createdAPIToken != nil {
            apiKeyLabel = ""
        }
    }
}

private struct CopyableIdentifierRow: View {
    let label: String
    let value: String
    let copiedLabel: String
    let note: String
    @State private var copied = false

    var body: some View {
        HStack(alignment: .top, spacing: 20) {
            Text(label.uppercased())
                .font(TealeDesign.monoSmall)
                .tracking(0.9)
                .foregroundStyle(TealeDesign.muted)
                .frame(width: 150, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Button(action: copyValue) {
                    Text(truncatedValue)
                        .font(TealeDesign.mono)
                        .foregroundStyle(TealeDesign.teale)
                }
                .buttonStyle(.plain)

                Text(copied ? copiedLabel : note)
                    .font(TealeDesign.monoSmall)
                    .foregroundStyle(TealeDesign.muted)
            }
            Spacer(minLength: 0)
        }
    }

    private var truncatedValue: String {
        guard value.count > 16 else { return value }
        return "\(value.prefix(8))...\(value.suffix(8))"
    }

    private func copyValue() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
        copied = true
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            copied = false
        }
    }
}

private struct AccountFormField<Content: View>: View {
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

private struct AccountWalletDeviceRow: View {
    @Environment(AppState.self) private var appState
    let device: CompanionAccountDeviceSnapshot
    let balanceText: String
    let isSweeping: Bool
    let onSweep: () -> Void
    @State private var copied = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(deviceLabel)
                    .font(TealeDesign.mono)
                    .foregroundStyle(TealeDesign.text)
                Text(detailLine)
                    .font(TealeDesign.monoTiny)
                    .foregroundStyle(TealeDesign.muted)
                Button(action: copyDeviceID) {
                    Text(truncatedDeviceID)
                        .font(TealeDesign.monoSmall)
                        .foregroundStyle(TealeDesign.teale)
                }
                .buttonStyle(.plain)
                Text(
                    copied
                        ? appState.companionText("wallet.deviceIDCopied", fallback: "Device wallet ID copied.")
                        : appState.companionText("account.deviceWalletIDNote", fallback: "Click to copy the full linked device wallet ID.")
                )
                .font(TealeDesign.monoTiny)
                .foregroundStyle(TealeDesign.muted)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 8) {
                Text(balanceText)
                    .font(TealeDesign.mono)
                    .foregroundStyle(TealeDesign.text)
                TealeActionButton(
                    title: isSweeping
                        ? appState.companionText("account.sweeping", fallback: "sweeping...")
                        : appState.companionText("account.sweep", fallback: "sweep"),
                    disabled: isSweeping
                ) {
                    onSweep()
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(Rectangle().stroke(TealeDesign.border.opacity(0.6), lineWidth: 1))
    }

    private var deviceLabel: String {
        device.deviceName ?? device.deviceID
    }

    private var detailLine: String {
        let platformLabel = (device.platform?.isEmpty == false ? device.platform! : "device").uppercased()
        return "\(platformLabel) · last seen \(Date(timeIntervalSince1970: TimeInterval(device.lastSeen)).formatted(date: .abbreviated, time: .shortened))"
    }

    private var truncatedDeviceID: String {
        guard device.deviceID.count > 16 else { return device.deviceID }
        return "\(device.deviceID.prefix(8))...\(device.deviceID.suffix(8))"
    }

    private func copyDeviceID() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(device.deviceID, forType: .string)
        copied = true
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            copied = false
        }
    }
}

private struct AccountAPIKeyRow: View {
    @Environment(AppState.self) private var appState
    let apiKey: CompanionAccountAPIKey
    let isRevoking: Bool
    let onRevoke: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(apiKey.label?.isEmpty == false ? apiKey.label! : appState.companionText("account.unnamedAPIKey", fallback: "Unnamed API key"))
                    .font(TealeDesign.mono)
                    .foregroundStyle(TealeDesign.text)
                Text(apiKey.tokenPreview)
                    .font(TealeDesign.monoSmall)
                    .foregroundStyle(TealeDesign.teale)
                Text(detailLine)
                    .font(TealeDesign.monoTiny)
                    .foregroundStyle(TealeDesign.muted)
            }
            Spacer(minLength: 8)
            if apiKey.isRevoked {
                Text(appState.companionText("account.apiKeyRevokedState", fallback: "revoked"))
                    .font(TealeDesign.monoSmall)
                    .foregroundStyle(TealeDesign.fail)
            } else {
                TealeActionButton(
                    title: isRevoking
                        ? appState.companionText("account.revokingAPIKey", fallback: "revoking...")
                        : appState.companionText("account.revokeAPIKey", fallback: "revoke"),
                    disabled: isRevoking
                ) {
                    onRevoke()
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(Rectangle().stroke(TealeDesign.border.opacity(0.6), lineWidth: 1))
    }

    private var detailLine: String {
        var parts = [
            "created \(Date(timeIntervalSince1970: TimeInterval(apiKey.createdAt)).formatted(date: .abbreviated, time: .shortened))"
        ]
        if let lastUsedAt = apiKey.lastUsedAt {
            parts.append("last used \(Date(timeIntervalSince1970: TimeInterval(lastUsedAt)).formatted(date: .abbreviated, time: .shortened))")
        } else {
            parts.append(appState.companionText("account.apiKeyNeverUsed", fallback: "never used"))
        }
        return parts.joined(separator: " · ")
    }
}

private struct AccountLedgerRow: View {
    @Environment(AppState.self) private var appState
    let transaction: CompanionAccountLedgerEntry

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(descriptionText)
                    .font(TealeDesign.mono)
                    .foregroundStyle(TealeDesign.text)
                    .lineLimit(2)
                Text(detailLine)
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
        return transaction.entryType.replacingOccurrences(of: "_", with: " ")
    }

    private var detailLine: String {
        var parts = [transaction.asset.uppercased()]
        if let deviceID = transaction.deviceID, !deviceID.isEmpty {
            parts.append(deviceID.prefix(8).description)
        }
        parts.append(Date(timeIntervalSince1970: TimeInterval(transaction.timestamp)).formatted(date: .abbreviated, time: .shortened))
        return parts.joined(separator: " · ")
    }

    private var signedAmountText: String {
        let amount = appState.companionDisplayAmountString(credits: abs(transaction.amount))
        return transaction.amount >= 0 ? "+\(amount)" : "-\(amount)"
    }
}
