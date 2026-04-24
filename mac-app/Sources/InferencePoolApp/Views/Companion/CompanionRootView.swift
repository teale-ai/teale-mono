import SwiftUI
import AppCore
#if canImport(AppKit)
import AppKit
#endif

struct CompanionRootView: View {
    @Environment(AppState.self) private var appState
    @State private var activeTab: CompanionTab = .home
    @State private var gatewayState = CompanionGatewayState()

    var body: some View {
        ZStack {
            TealeDesign.pageBackground
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    TealeNavBar(activeTab: $activeTab)
                    TealeHeaderLine(activeTab: activeTab)
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
            await appState.updateChecker.checkIfNeeded()
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
            CompanionWalletView()
        case .account:
            CompanionAccountView()
        }
    }
}

private struct TealeNavBar: View {
    @Environment(AppState.self) private var appState
    @Environment(\.openURL) private var openURL
    @Binding var activeTab: CompanionTab
    @State private var shareButtonLabel = "share"

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
                openURL(URL(string: "https://x.com/teale_ai")!)
            }
            HeaderToolButton(title: shareButtonLabel) {
                copyShareText()
            }
            settingsMenu
        }
    }

    private var settingsMenu: some View {
        Menu {
            ForEach(AppLanguage.allCases) { language in
                Button {
                    appState.language = language
                } label: {
                    SettingsMenuItemLabel(
                        title: language.displayName,
                        isSelected: appState.language == language
                    )
                }
            }

            Divider()

            ForEach(CompanionDisplayUnit.allCases) { unit in
                Button {
                    appState.companionDisplayUnit = unit
                } label: {
                    SettingsMenuItemLabel(
                        title: appState.companionMenuLabel(for: unit),
                        isSelected: appState.companionDisplayUnit == unit
                    )
                }
            }
        } label: {
            HeaderIconButton(systemImage: "gearshape")
        }
        .menuStyle(.borderlessButton)
        .tint(TealeDesign.teale)
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
            if isSelected {
                Spacer(minLength: 8)
                Image(systemName: "checkmark")
            }
        }
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
            return appState.companionText("header.account", fallback: "account details, balances, and linked devices")
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
