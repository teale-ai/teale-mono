import SwiftUI
import AppCore
import PrivacyFilterKit
#if canImport(AppKit)
import AppKit
#endif

struct CompanionRootView: View {
    @Environment(AppState.self) private var appState
    @State private var activeTab: CompanionTab = .home
    @State private var gatewayState = CompanionGatewayState()
    @State private var refreshNonce = 0
    @State private var headerRefreshInFlight = false

    var body: some View {
        ZStack {
            TealeDesign.pageBackground
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    TealeNavBar(
                        activeTab: $activeTab,
                        isRefreshing: headerRefreshInFlight,
                        onRefresh: {
                            Task { await refreshFromHeader() }
                        }
                    )
                    TealeHeaderLine(activeTab: activeTab)
                    if shouldShowUpdateBanner {
                        CompanionUpdateBanner()
                            .padding(.top, 16)
                    }
                    Rectangle()
                        .fill(TealeDesign.tealeDim)
                        .frame(height: 1)
                        .padding(.vertical, 16)
                    content
                    TealeFooter()
                        .padding(.top, 16)
                }
                .frame(maxWidth: 980)
                .padding(.horizontal, 24)
                .padding(.vertical, 28)
                .frame(maxWidth: .infinity, alignment: .center)
            }
        }
        .preferredColorScheme(.dark)
        .environment(gatewayState)
        .task {
            await appState.startServer()
            await appState.initializeAsync()
            await gatewayState.refresh(appState: appState, force: true)
        }
        .task(id: appState.gatewayFallbackURL) {
            while !Task.isCancelled {
                await gatewayState.refresh(appState: appState)
                try? await Task.sleep(for: .seconds(12))
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch activeTab {
        case .home:
            CompanionHomeView(onNavigate: { activeTab = $0 })
        case .supply:
            CompanionSupplyView(onNavigate: { activeTab = $0 })
        case .demand:
            CompanionDemandView()
        case .wallet:
            CompanionWalletView(refreshNonce: refreshNonce)
        case .account:
            CompanionAccountView(refreshNonce: refreshNonce)
        }
    }

    @MainActor
    private func refreshFromHeader() async {
        guard !headerRefreshInFlight else { return }
        headerRefreshInFlight = true
        await gatewayState.refresh(appState: appState, force: true)
        refreshNonce &+= 1
        headerRefreshInFlight = false
    }
}

private extension CompanionRootView {
    var shouldShowUpdateBanner: Bool {
        let checker = appState.updateChecker
        return checker.updateAvailable ||
            checker.downloading ||
            checker.installing ||
            checker.downloadedUpdateReady ||
            checker.lastError != nil
    }
}

private struct CompanionUpdateBanner: View {
    @Environment(AppState.self) private var appState
    @Environment(\.openURL) private var openURL

    private var checker: UpdateChecker {
        appState.updateChecker
    }

    var body: some View {
        TealeCard {
            VStack(alignment: .leading, spacing: 12) {
                Text("update available")
                    .font(TealeDesign.monoSmall)
                    .tracking(0.8)
                    .foregroundStyle(TealeDesign.warn)

                Text(messageText)
                    .font(TealeDesign.mono)
                    .foregroundStyle(TealeDesign.text)

                if let error = checker.lastError, !error.isEmpty {
                    Text(error)
                        .font(TealeDesign.monoSmall)
                        .foregroundStyle(TealeDesign.fail)
                }

                HStack(spacing: 10) {
                    if checker.updateAvailable {
                        TealeActionButton(
                            title: primaryButtonTitle,
                            primary: true,
                            disabled: checker.installing || checker.checking || checker.downloading
                        ) {
                            Task {
                                let installed = await checker.installUpdate()
                                if !installed, let url = checker.releaseURL {
                                    await MainActor.run {
                                        openURL(url)
                                    }
                                }
                            }
                        }

                        if let releaseURL = checker.releaseURL {
                            TealeActionButton(title: "view release") {
                                openURL(releaseURL)
                            }
                        }

                        TealeActionButton(title: "later") {
                            checker.dismissUpdate()
                        }
                    } else if let releaseURL = checker.releaseURL {
                        TealeActionButton(title: "view release") {
                            openURL(releaseURL)
                        }
                    }
                }
            }
        }
    }

    private var messageText: String {
        if checker.installing {
            return "Installing the latest macOS build and relaunching Teale."
        }
        if checker.downloading, let version = checker.latestVersionLabel {
            if checker.autoInstallEnabled {
                return "Teale \(version) is downloading in the background and will relaunch automatically when ready."
            }
            return "Teale \(version) is downloading in the background for this Mac."
        }
        if checker.downloadedUpdateReady, let version = checker.latestVersionLabel ?? checker.latestTag?.replacingOccurrences(of: "mac-v", with: "") {
            if checker.autoInstallEnabled {
                return "Teale \(version) is downloaded and will install automatically on this Mac."
            }
            return "Teale \(version) is downloaded and ready to install."
        }
        if let version = checker.latestVersionLabel {
            if checker.autoDownloadEnabled && checker.autoInstallEnabled {
                return "Teale \(version) is available for macOS and will download and install automatically."
            }
            if checker.autoDownloadEnabled {
                return "Teale \(version) is available for macOS and is downloading automatically in the background."
            }
            return "Teale \(version) is available for macOS. Install in place and relaunch, or open the release notes first."
        }
        return "Teale found a newer macOS release, but the in-app installer needs the published release asset to finish."
    }

    private var primaryButtonTitle: String {
        if checker.installing {
            return "installing..."
        }
        if checker.downloading {
            return "downloading..."
        }
        if checker.downloadedUpdateReady {
            return "install downloaded update"
        }
        return "install update"
    }
}

private struct TealeNavBar: View {
    @Environment(AppState.self) private var appState
    @Environment(\.openURL) private var openURL
    @Binding var activeTab: CompanionTab
    let isRefreshing: Bool
    let onRefresh: () -> Void
    @State private var shareButtonLabel = "share"
    @State private var isSettingsMenuOpen = false
    @State private var privacyStatus = PrivacyHelperStatus(state: .disabled)

    var body: some View {
        HStack(spacing: 10) {
            ForEach(Array(CompanionTab.allCases.enumerated()), id: \.element) { index, tab in
                if index > 0 {
                    Text("|")
                        .foregroundStyle(TealeDesign.muted)
                        .font(TealeDesign.mono)
                }
                Button {
                    activeTab = tab
                } label: {
                    Text(tab.label(in: appState))
                        .font(TealeDesign.mono)
                        .tracking(0.6)
                        .foregroundStyle(activeTab == tab ? TealeDesign.text : TealeDesign.muted)
                        .fontWeight(activeTab == tab ? .bold : .medium)
                }
                .buttonStyle(.plain)
            }
            CursorBlink()
            Spacer()
            HeaderToolButton(title: "x.com") {
                isSettingsMenuOpen = false
                openURL(URL(string: "https://x.com/teale_ai")!)
            }
            HeaderToolButton(title: shareButtonLabel) {
                isSettingsMenuOpen = false
                copyShareText()
            }
            Button(action: onRefresh) {
                HeaderIconButton(systemImage: "arrow.clockwise")
                    .opacity(isRefreshing ? 0.6 : 1.0)
            }
            .buttonStyle(.plain)
            .disabled(isRefreshing)
            settingsMenu
        }
        .zIndex(20)
    }

    private var settingsMenu: some View {
        Button {
            isSettingsMenuOpen.toggle()
        } label: {
            HeaderIconButton(systemImage: "gearshape")
        }
        .buttonStyle(.plain)
        .task(id: isSettingsMenuOpen) {
            guard isSettingsMenuOpen else { return }
            await refreshPrivacyStatus()
        }
        .task(id: appState.privacyFilterMode) {
            guard isSettingsMenuOpen else { return }
            await refreshPrivacyStatus()
        }
        .overlay(alignment: .topTrailing) {
            if isSettingsMenuOpen {
                settingsPopover
                    .offset(x: -6, y: 42)
            }
        }
    }

    private var settingsPopover: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(AppLanguage.allCases) { language in
                Button {
                    appState.language = language
                    isSettingsMenuOpen = false
                } label: {
                    SettingsMenuItemLabel(
                        title: language.displayName,
                        isSelected: appState.language == language
                    )
                }
                .buttonStyle(.plain)
            }

            Rectangle()
                .fill(TealeDesign.border)
                .frame(height: 1)
                .padding(.vertical, 4)

            Text("privacy")
                .font(TealeDesign.monoSmall)
                .foregroundStyle(TealeDesign.muted)

            ForEach(PrivacyFilterMode.allCases) { mode in
                Button {
                    appState.privacyFilterMode = mode
                    Task { await refreshPrivacyStatus() }
                } label: {
                    SettingsMenuItemLabel(
                        title: privacyModeLabel(mode),
                        isSelected: appState.privacyFilterMode == mode
                    )
                }
                .buttonStyle(.plain)
            }

            HStack(alignment: .top, spacing: 8) {
                Text("helper")
                    .font(TealeDesign.monoSmall)
                    .foregroundStyle(TealeDesign.muted)
                VStack(alignment: .leading, spacing: 2) {
                    Text(privacyStatusLabel)
                        .font(TealeDesign.monoSmall)
                        .foregroundStyle(privacyStatusColor)
                    if let detail = privacyStatus.detail, !detail.isEmpty {
                        Text(detail)
                            .font(TealeDesign.monoTiny)
                            .foregroundStyle(TealeDesign.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(.vertical, 4)

            Rectangle()
                .fill(TealeDesign.border)
                .frame(height: 1)
                .padding(.vertical, 4)

            ForEach(CompanionDisplayUnit.allCases) { unit in
                Button {
                    appState.companionDisplayUnit = unit
                    isSettingsMenuOpen = false
                } label: {
                    SettingsMenuItemLabel(
                        title: appState.companionMenuLabel(for: unit),
                        isSelected: appState.companionDisplayUnit == unit
                    )
                }
                .buttonStyle(.plain)
            }

            Rectangle()
                .fill(TealeDesign.border)
                .frame(height: 1)
                .padding(.vertical, 4)

            updaterSection
        }
        .padding(12)
        .background(
            LinearGradient(
                colors: [
                    Color(red: 0.05, green: 0.18, blue: 0.24, opacity: 0.98),
                    Color(red: 0.03, green: 0.10, blue: 0.14, opacity: 0.98)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color(red: 0.16, green: 0.34, blue: 0.39), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .fixedSize()
        .shadow(color: .black.opacity(0.25), radius: 16, x: 0, y: 8)
    }

    private var checker: UpdateChecker {
        appState.updateChecker
    }

    private var updaterSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(appState.companionText("settings.updates", fallback: "updates"))
                .font(TealeDesign.monoSmall)
                .foregroundStyle(TealeDesign.muted)

            VStack(alignment: .leading, spacing: 4) {
                Text(appState.companionText("account.currentVersion", fallback: "Current version").uppercased())
                    .font(TealeDesign.monoTiny)
                    .foregroundStyle(TealeDesign.muted)
                Text(checker.currentVersionLabel)
                    .font(TealeDesign.monoSmall)
                    .foregroundStyle(TealeDesign.text)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(appState.companionText("account.updateStatus", fallback: "Update status").uppercased())
                    .font(TealeDesign.monoTiny)
                    .foregroundStyle(TealeDesign.muted)
                Text(checker.statusSummary)
                    .font(TealeDesign.monoSmall)
                    .foregroundStyle(TealeDesign.text)
                    .fixedSize(horizontal: false, vertical: true)
            }

            TealeToggleRow(
                title: appState.companionText(
                    "account.autoDownloadUpdates",
                    fallback: "download updates automatically"
                ),
                detail: appState.companionText(
                    "settings.autoDownloadUpdatesDetail",
                    fallback: "Background download on new macOS releases."
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
                    "settings.autoInstallUpdatesDetail",
                    fallback: "Replace Teale.app and relaunch when the download finishes."
                ),
                isOn: Binding(
                    get: { checker.autoInstallEnabled },
                    set: { checker.autoInstallEnabled = $0 }
                )
            )

            HStack(spacing: 8) {
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
                        title: updaterInstallButtonTitle,
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
        }
    }

    private var updaterInstallButtonTitle: String {
        if checker.installing {
            return appState.companionText("account.installingUpdate", fallback: "installing...")
        }
        if checker.downloading {
            return appState.companionText("account.downloadingUpdate", fallback: "downloading...")
        }
        if checker.downloadedUpdateReady {
            return appState.companionText("account.installDownloadedUpdate", fallback: "install downloaded update")
        }
        return appState.companionText("account.installUpdate", fallback: "install update")
    }

    private func privacyModeLabel(_ mode: PrivacyFilterMode) -> String {
        switch mode {
        case .off:
            return "privacy: off"
        case .autoWAN:
            return "privacy: wan auto"
        case .always:
            return "privacy: always"
        }
    }

    private var privacyStatusLabel: String {
        switch privacyStatus.state {
        case .disabled:
            return "disabled"
        case .unsupported:
            return "unsupported"
        case .ready:
            return "ready"
        case .unavailable:
            return "unavailable"
        }
    }

    private var privacyStatusColor: Color {
        switch privacyStatus.state {
        case .ready:
            return TealeDesign.teale
        case .unavailable, .unsupported:
            return TealeDesign.warn
        case .disabled:
            return TealeDesign.muted
        }
    }

    private func refreshPrivacyStatus() async {
        privacyStatus = await DesktopPrivacyFilter.shared.status(for: appState.privacyFilterMode)
    }

    private func copyShareText() {
#if canImport(AppKit)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(
            "I've joined the global distributed ai inference network at teale.com - earn credits to use on ai when you sleep. spend those credits to use ai for free.",
            forType: .string
        )
        shareButtonLabel = "copied"
        Task {
            try? await Task.sleep(for: .milliseconds(900))
            shareButtonLabel = "share"
        }
#else
        shareButtonLabel = "share"
#endif
    }
}

private struct SettingsMenuItemLabel: View {
    let title: String
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(TealeDesign.mono)
                .foregroundStyle(TealeDesign.text)
            if isSelected {
                Spacer(minLength: 8)
                Image(systemName: "checkmark")
                    .foregroundStyle(TealeDesign.teale)
            }
        }
        .frame(minWidth: 220, alignment: .leading)
        .padding(.vertical, 4)
    }
}

private struct CursorBlink: View {
    @State private var visible = true
    var body: some View {
        Rectangle()
            .fill(TealeDesign.teale)
            .frame(width: 8, height: 14)
            .opacity(visible ? 1 : 0)
            .onAppear {
                Task {
                    while !Task.isCancelled {
                        try? await Task.sleep(for: .milliseconds(550))
                        visible.toggle()
                    }
                }
            }
    }
}

private struct TealeHeaderLine: View {
    @Environment(AppState.self) private var appState
    let activeTab: CompanionTab

    var body: some View {
        Text(headerText)
            .font(TealeDesign.mono)
            .foregroundStyle(TealeDesign.text)
            .padding(.top, 10)
    }

    private var headerText: String {
        switch activeTab {
        case .home:
            return appState.companionText("header.home", fallback: "distributed ai inference supply and demand")
        case .supply:
            return appState.companionDisplayUnit == .credits
                ? appState.companionText("header.supply.credits", fallback: "earn teale credits by supplying ai inference to users around the world")
                : appState.companionText("header.supply.usd", fallback: "earn usd-equivalent balance by supplying ai inference to users around the world")
        case .demand:
            return appState.companionDisplayUnit == .credits
                ? appState.companionText("header.demand.credits", fallback: "use local models for free or buy and spend credits for more powerful models")
                : appState.companionText("header.demand.usd", fallback: "use local models for free or buy and spend usd for more powerful models")
        case .wallet:
            return appState.companionText("header.wallet", fallback: "device balances, send assets, and ledger history")
        case .account:
            return appState.companionText("header.account", fallback: "account wallet, linked device wallets, and profile details")
        }
    }
}

private struct TealeFooter: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        HStack {
            Spacer()
            Text(appState.companionText("footer.tagline", fallback: "teale.com - distributed ai inference for the world"))
                .font(TealeDesign.monoTiny)
                .foregroundStyle(TealeDesign.muted)
                .tracking(0.6)
            Spacer()
        }
    }
}

private struct HeaderToolButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title.lowercased())
                .font(TealeDesign.monoSmall)
                .tracking(0.6)
                .foregroundStyle(TealeDesign.teale)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .overlay(
                    Rectangle().stroke(TealeDesign.tealeDim, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }
}

private struct HeaderIconButton: View {
    let systemImage: String

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(TealeDesign.teale)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .overlay(
                Rectangle().stroke(TealeDesign.tealeDim, lineWidth: 1)
            )
    }
}
