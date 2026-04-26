import SwiftUI
import AppCore
import AuthKit
import AppKit
import SharedTypes

struct CompanionAccountView: View {
    @Environment(AppState.self) private var appState
    @Environment(CompanionGatewayState.self) private var gatewayState
    @Environment(\.openURL) private var openURL
    @State private var authNotice: String?

    let onSendDevice: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            accountSection
            updateSection
            detailsSection
            devicesSection
        }
    }

    private var authManager: AuthManager? { appState.authManager }
    private var authState: AuthState { authManager?.authState ?? .signedOut }
    private var isSignedIn: Bool { authState.isAuthenticated }
    private var authIsConfigured: Bool { authManager != nil }

    // MARK: account

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
                    HStack {
                        TealeActionButton(title: appState.companionText("account.signOut", fallback: "Sign out")) {
                            Task {
                                await authManager?.signOut()
                            }
                        }
                    }
                    .padding(.top, 6)
                }
            }
            Text(appState.companionText("account.linkNote", fallback: "Sign in to link this machine to a person. Device wallet earnings continue working without human sign-in."))
                .font(TealeDesign.monoSmall)
                .foregroundStyle(TealeDesign.muted)
                .padding(.top, 8)
            if let authNotice, !authNotice.isEmpty {
                Text(authNotice)
                    .font(TealeDesign.monoSmall)
                    .foregroundStyle(TealeDesign.warn)
                    .padding(.top, 6)
            }
        }
    }

    private var userNote: String {
        if let user = authManager?.currentUser {
            return user.email ?? user.phone ?? user.id.uuidString
        }
        return appState.companionText("account.notSignedIn", fallback: "Not signed in")
    }

    private var accountStatus: String {
        if isSignedIn { return appState.companionText("account.signedIn", fallback: "Signed in") }
        return authIsConfigured
            ? appState.companionText("account.notSignedIn", fallback: "Not signed in")
            : appState.companionText("account.authUnavailable", fallback: "Auth unavailable")
    }

    private var statusNote: String {
        if let authNotice, !authNotice.isEmpty {
            return authNotice
        }
        if authIsConfigured {
            return userNote
        }
        return appState.companionText("account.authUnavailableDetail", fallback: "Sign-in is unavailable in this build.")
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

    // MARK: details

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

    // MARK: updates

    private var updateSection: some View {
        TealeSection(prompt: appState.companionText("account.updates", fallback: "updates")) {
            TealeStats {
                TealeStatRow(
                    label: appState.companionText("account.currentVersion", fallback: "Current version"),
                    value: checker.currentVersionLabel
                )
                TealeStatRow(
                    label: appState.companionText("account.updateStatus", fallback: "Update status"),
                    value: checker.statusSummary,
                    note: appState.companionText(
                        "account.updateSchedule",
                        fallback: "Teale checks GitHub releases every 4 hours while the mac app is running."
                    )
                )
            }

            VStack(alignment: .leading, spacing: 12) {
                TealeToggleRow(
                    title: appState.companionText(
                        "account.autoDownloadUpdates",
                        fallback: "download updates automatically"
                    ),
                    detail: appState.companionText(
                        "account.autoDownloadUpdatesDetail",
                        fallback: "New macOS builds download in the background as soon as Teale sees them."
                    ),
                    isOn: Binding(
                        get: { checker.autoDownloadEnabled },
                        set: { checker.autoDownloadEnabled = $0 }
                    )
                )

                TealeToggleRow(
                    title: appState.companionText(
                        "account.autoInstallUpdates",
                        fallback: "install after download"
                    ),
                    detail: appState.companionText(
                        "account.autoInstallUpdatesDetail",
                        fallback: "After download finishes, replace Teale.app and relaunch automatically."
                    ),
                    isOn: Binding(
                        get: { checker.autoInstallEnabled },
                        set: { checker.autoInstallEnabled = $0 }
                    )
                )
            }
            .padding(.top, 10)

            HStack(spacing: 10) {
                TealeActionButton(
                    title: checker.checking ? "checking..." : appState.companionText("account.checkUpdates", fallback: "check now"),
                    primary: true,
                    disabled: checker.checking || checker.installing
                ) {
                    Task {
                        await checker.check()
                    }
                }

                if checker.updateAvailable || checker.downloadedUpdateReady {
                    TealeActionButton(
                        title: installButtonTitle,
                        disabled: checker.installing || checker.downloading
                    ) {
                        Task {
                            _ = await checker.installUpdate()
                        }
                    }
                }

                if let releaseURL = checker.releaseURL {
                    TealeActionButton(title: appState.companionText("account.viewRelease", fallback: "view release")) {
                        openURL(releaseURL)
                    }
                }
            }
            .padding(.top, 10)
        }
    }

    // MARK: devices

    private var devicesSection: some View {
        TealeSection(prompt: appState.companionText("account.devices", fallback: "devices")) {
            if !isSignedIn {
                Text(appState.companionText("account.viewDevicesSignedOut", fallback: "Sign in to view devices on this account."))
                    .font(TealeDesign.monoSmall)
                    .foregroundStyle(TealeDesign.muted)
            } else if gatewayState.isLoadingAccountDevices && gatewayState.accountSummary == nil && gatewayState.lastAccountRefreshError == nil {
                Text(appState.companionText("account.gatewayDevicesLoading", fallback: "Loading Teale device wallets for this account..."))
                    .font(TealeDesign.monoSmall)
                    .foregroundStyle(TealeDesign.muted)
            } else if let error = gatewayState.lastAccountRefreshError, gatewayState.accountSummary == nil {
                Text("\(appState.companionText("account.gatewayDevicesUnavailable", fallback: "Could not load Teale device wallets for this account.")) \(error)")
                    .font(TealeDesign.monoSmall)
                    .foregroundStyle(TealeDesign.warn)
            } else if let devices = gatewayState.accountSummary?.devices, !devices.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    if let error = gatewayState.lastAccountRefreshError, !error.isEmpty {
                        Text("\(appState.companionText("account.gatewayDevicesUnavailable", fallback: "Could not load Teale device wallets for this account.")) \(error)")
                            .font(TealeDesign.monoSmall)
                            .foregroundStyle(TealeDesign.warn)
                    }
                    ForEach(devices, id: \.id) { device in
                        GatewayDeviceRow(device: device, onSendDevice: onSendDevice)
                    }
                }
            } else {
                Text(appState.companionText("account.noGatewayDevices", fallback: "No Teale device wallets are linked to this account yet."))
                    .font(TealeDesign.monoSmall)
                    .foregroundStyle(TealeDesign.muted)
            }
        }
    }

    private var checker: UpdateChecker { appState.updateChecker }

    private var installButtonTitle: String {
        if checker.installing {
            return appState.companionText("account.installingUpdate", fallback: "installing...")
        }
        if checker.downloading {
            return appState.companionText("account.downloadingUpdate", fallback: "downloading...")
        }
        if checker.downloadedUpdateReady {
            return appState.companionText("account.installDownloadedUpdate", fallback: "install downloaded update")
        }
        return appState.companionText("account.installUpdate", fallback: "download + install")
    }
}

private struct GatewayDeviceRow: View {
    @Environment(AppState.self) private var appState
    @Environment(CompanionGatewayState.self) private var gatewayState

    let device: CompanionGatewayAccountDevice
    let onSendDevice: (String) -> Void

    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(device.deviceName ?? companionTruncatedIdentifier(device.deviceID))
                        .font(TealeDesign.mono)
                        .foregroundStyle(TealeDesign.text)
                    Text(platformLine)
                        .font(TealeDesign.monoTiny)
                        .foregroundStyle(TealeDesign.muted)
                }
                Spacer(minLength: 8)
                Text(appState.companionDisplayAmountString(credits: device.walletBalanceCredits, compact: true))
                    .font(TealeDesign.mono)
                    .foregroundStyle(TealeDesign.teale)
            }

            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(appState.companionText("account.gatewayDeviceID", fallback: "Teale device ID").uppercased())
                        .font(TealeDesign.monoSmall)
                        .tracking(0.9)
                        .foregroundStyle(TealeDesign.muted)
                    Button(action: copyDeviceID) {
                        Text(companionTruncatedIdentifier(device.deviceID))
                            .font(TealeDesign.mono)
                            .foregroundStyle(TealeDesign.teale)
                    }
                    .buttonStyle(.plain)

                    Text(copied
                        ? appState.companionText("account.gatewayDeviceCopied", fallback: "Device ID copied.")
                        : appState.companionText("account.gatewayDeviceNote", fallback: "Use this ID as the wallet recipient for bearer-token devices on your account."))
                        .font(TealeDesign.monoSmall)
                        .foregroundStyle(TealeDesign.muted)
                }

                Spacer(minLength: 12)

                TealeActionButton(title: appState.companionText("account.sendToDevice", fallback: "send credits")) {
                    onSendDevice(device.deviceID)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(Rectangle().stroke(TealeDesign.border.opacity(0.6), lineWidth: 1))
    }

    private var platformLine: String {
        let platform = device.platform ?? "device"
        let relativeText = RelativeDateTimeFormatter().localizedString(for: lastSeenDate, relativeTo: Date())
        if device.deviceID == gatewayState.localDeviceID {
            return "\(platform) · \(appState.companionText("account.thisDevice", fallback: "This device")) · \(relativeText)"
        }
        return "\(platform) · \(relativeText)"
    }

    private var lastSeenDate: Date {
        Date(timeIntervalSince1970: TimeInterval(device.lastSeen))
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
