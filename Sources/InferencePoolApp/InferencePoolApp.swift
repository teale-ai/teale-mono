import SwiftUI
import AppCore
import SharedTypes
import AuthKit

// MARK: - Main App Entry

@main
struct InferencePoolApp: App {
    @State private var appState: AppState

    init() {
        // Disable Hub library's NetworkMonitor offline mode detection
        // which incorrectly reports "expensive" connections and blocks downloads
        setenv("CI_DISABLE_NETWORK_MONITOR", "1", 1)

        // Create AppState eagerly so the HTTP server starts immediately.
        let state = AppState()
        _appState = State(initialValue: state)
    }

    var body: some Scene {
        MenuBarExtra {
            ContentView()
                .environment(appState)
                .frame(width: 480, height: 600)
                .onOpenURL { url in
                    Task { await appState.authManager?.handleOAuthCallback(url: url) }
                }
        } label: {
            Label("Teale", systemImage: "brain.head.profile")
        }
        .menuBarExtraStyle(.window)
    }
}

// MARK: - Content View (root navigation)

struct ContentView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        let authState = appState.authManager?.authState
        let shouldShowMainApp = (authState?.canUseApp ?? true) || appState.showSignIn

        Group {
            if shouldShowMainApp {
                NavigationSplitView {
                    SidebarView()
                } detail: {
                    switch appState.currentView {
                    case .dashboard:
                        DashboardView()
                    case .chat:
                        ChatView()
                    case .models:
                        ModelBrowserView()
                    case .cluster:
                        ClusterView()
                    case .wan:
                        WANView()
                    case .wallet:
                        WalletView()
                    case .agents:
                        AgentView()
                    case .devices:
                        if let authManager = appState.authManager {
                            DevicesView(authManager: authManager)
                        } else {
                            Text(appState.loc("settings.signInSubtitle"))
                        }
                    case .settings:
                        SettingsView()
                    }
                }
                .sheet(isPresented: Binding(
                    get: { appState.showSignIn },
                    set: { appState.showSignIn = $0 }
                )) {
                    if let authManager = appState.authManager {
                        LoginView(authManager: authManager)
                            .frame(width: 400, height: 500)
                    }
                }
            } else if let authManager = appState.authManager {
                LoginView(authManager: authManager)
            } else {
                Text("Authentication unavailable")
                    .foregroundStyle(.secondary)
            }
        }
        .onChange(of: appState.authManager?.authState.isAuthenticated ?? false) { _, isAuthenticated in
            if isAuthenticated {
                appState.showSignIn = false
            }
        }
        .task {
            await appState.startServer()
            await appState.initializeAsync()
        }
    }
}

// MARK: - Sidebar

struct SidebarView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var state = appState

        List(selection: Binding(get: { appState.currentView }, set: { appState.currentView = $0 })) {
            Label(appState.loc("sidebar.dashboard"), systemImage: "gauge")
                .tag(AppView.dashboard)
            Label(appState.loc("sidebar.chat"), systemImage: "bubble.left.and.bubble.right")
                .tag(AppView.chat)
            Label(appState.loc("sidebar.models"), systemImage: "square.stack.3d.up")
                .tag(AppView.models)

            Section(appState.loc("sidebar.network")) {
                Label(appState.loc("sidebar.cluster"), systemImage: "desktopcomputer.and.arrow.down")
                    .tag(AppView.cluster)
                Label(appState.loc("sidebar.wan"), systemImage: "globe")
                    .tag(AppView.wan)
            }

            Section {
                Label(appState.loc("sidebar.wallet"), systemImage: "creditcard")
                    .tag(AppView.wallet)
                if appState.authManager?.authState.isAuthenticated ?? false {
                    Label(appState.loc("sidebar.devices"), systemImage: "laptopcomputer.and.iphone")
                        .tag(AppView.devices)
                }
                Label(appState.loc("sidebar.settings"), systemImage: "gear")
                    .tag(AppView.settings)
            }
        }
        .listStyle(.sidebar)
        .frame(minWidth: 140)
    }
}
