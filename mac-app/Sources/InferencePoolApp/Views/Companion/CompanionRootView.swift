import SwiftUI
import AppCore
#if canImport(AppKit)
import AppKit
#endif

struct CompanionRootView: View {
    @Environment(AppState.self) private var appState
    @State private var activeTab: CompanionTab = .home

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
        .task {
            await appState.startServer()
            await appState.initializeAsync()
            await appState.updateChecker.checkIfNeeded()
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
                    Text(tab.label)
                        .font(TealeDesign.mono)
                        .tracking(0.6)
                        .foregroundStyle(activeTab == tab ? TealeDesign.text : TealeDesign.muted)
                        .fontWeight(activeTab == tab ? .bold : .medium)
                }
                .buttonStyle(.plain)
            }
            Spacer()
            languagePicker
            HeaderToolButton(title: "x.com") {
                openURL(URL(string: "https://x.com/teale_ai")!)
            }
            HeaderToolButton(title: shareButtonLabel) {
                copyShareText()
            }
            CursorBlink()
        }
    }

    private var languagePicker: some View {
        Picker(
            appState.loc("settings.language"),
            selection: Binding(
                get: { appState.language },
                set: { appState.language = $0 }
            )
        ) {
            ForEach(AppLanguage.allCases) { language in
                Text(language.displayName).tag(language)
            }
        }
        .labelsHidden()
        .pickerStyle(.menu)
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
    let activeTab: CompanionTab

    var body: some View {
        Text(headerText)
            .font(TealeDesign.mono)
            .foregroundStyle(TealeDesign.text)
            .padding(.top, 10)
    }

    private var headerText: String {
        switch activeTab {
        case .home: return "distributed ai inference supply and demand"
        case .supply: return "earn teale credits by supplying ai inference to users around the world"
        case .demand: return "use local models for free or buy and spend credits for more powerful models"
        case .wallet: return "device balances, send assets, and ledger history"
        case .account: return "account details, balances, and linked devices"
        }
    }
}

private struct TealeFooter: View {
    var body: some View {
        HStack {
            Spacer()
            Text("teale.com - distributed ai inference for the world")
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
