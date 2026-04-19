import SwiftUI
import AppKit
import AppCore
import ChatKit
import SharedTypes
import AuthKit

// MARK: - Main App Entry

@main
struct TealeApp: App {
    @State private var appState: AppState

    init() {
        // Disable Hub library's NetworkMonitor offline mode detection
        // which incorrectly reports "expensive" connections and blocks downloads
        setenv("CI_DISABLE_NETWORK_MONITOR", "1", 1)

        // Make sure the app runs as a regular foreground app so the window
        // receives keyboard focus — when launched via CLI without a proper
        // bundled Info.plist the activation policy can default to .accessory.
        NSApplication.shared.setActivationPolicy(.regular)

        // Dock icon — match the menu-bar symbol (brain.head.profile, teal).
        Self.installDockIcon()

        // Patch the application menu so the first menu reads "Teale" even when
        // launched from CLI without a bundled Info.plist (macOS would otherwise
        // derive the name from the executable filename / process).
        Self.patchAppMenuTitle("Teale")

        // Create AppState eagerly so the HTTP server starts immediately.
        let state = AppState()
        _appState = State(initialValue: state)
    }

    /// Handle `teale://invite/<token>` deep links by joining the group locally,
    /// then fall back to OAuth callback handling for the auth flow.
    private func handleIncomingURL(_ url: URL) {
        let invitationService = InvitationService(currentUserID: appState.currentUserID)
        if let token = invitationService.parseDeepLink(url), !token.isExpired {
            Task { @MainActor in
                // If the invited group isn't already local, create a stub conversation
                // with the same ID so the recipient can see incoming messages.
                if !appState.chatService.conversations.contains(where: { $0.id == token.groupID }) {
                    var stub = Conversation(
                        id: token.groupID,
                        type: .group,
                        title: token.groupTitle,
                        createdBy: token.inviterID,
                        agentConfig: AgentConfig(autoRespond: false, mentionOnly: true, persona: "assistant")
                    )
                    _ = stub
                    _ = await appState.chatService.createGroup(
                        title: token.groupTitle,
                        memberIDs: [],
                        agentConfig: AgentConfig(autoRespond: false, mentionOnly: true, persona: "assistant")
                    )
                }
                appState.currentView = .chat
            }
            return
        }
        // Fall through to OAuth callbacks.
        Task { await appState.authManager?.handleOAuthCallback(url: url) }
    }

    /// Replace the auto-generated app menu title (derived from the process name)
    /// with an explicit string. Runs after a short delay so SwiftUI has created
    /// the main menu we can mutate.
    private static func patchAppMenuTitle(_ name: String) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            guard let mainMenu = NSApp.mainMenu,
                  let appMenuItem = mainMenu.items.first else { return }
            appMenuItem.title = name
            if let appMenu = appMenuItem.submenu {
                appMenu.title = name
                for item in appMenu.items {
                    let updated = item.title
                        .replacingOccurrences(of: "InferencePoolApp", with: name)
                    if updated != item.title { item.title = updated }
                }
            }
        }
    }

    /// Render the SF Symbol used in the menu bar as an NSImage and assign it
    /// as the app's dock icon. Works for both CLI-launched binaries and
    /// bundled apps (and overrides any AppIcon.icns if present).
    private static func installDockIcon() {
        let size: CGFloat = 512
        let symbolConfig = NSImage.SymbolConfiguration(pointSize: size * 0.7, weight: .regular)
        let colorConfig = NSImage.SymbolConfiguration(paletteColors: [.white])
        let combined = symbolConfig.applying(colorConfig)

        guard let symbol = NSImage(
            systemSymbolName: "brain.head.profile",
            accessibilityDescription: "Teale"
        )?.withSymbolConfiguration(combined) else { return }

        // Draw the symbol centered on a rounded purple tile so the icon reads
        // clearly at dock scale against any desktop background.
        let icon = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            let cornerRadius: CGFloat = size * 0.22
            let path = NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius)
            // Teale brand color (matches Color.teale on iOS): teal.
            NSColor(red: 0.0, green: 0.6, blue: 0.6, alpha: 1.0).setFill()
            path.fill()

            let symbolSize = symbol.size
            let origin = NSPoint(
                x: (rect.width - symbolSize.width) / 2,
                y: (rect.height - symbolSize.height) / 2
            )
            symbol.draw(
                in: NSRect(origin: origin, size: symbolSize),
                from: .zero,
                operation: .sourceOver,
                fraction: 1.0
            )
            return true
        }

        NSApplication.shared.applicationIconImage = icon
    }

    var body: some Scene {
        // Claude-app-style main window — chat, groups, dashboard, models, etc.
        WindowGroup(id: "main") {
            MainWindowView()
                .environment(appState)
                .frame(minWidth: 900, minHeight: 600)
                .onOpenURL { url in
                    handleIncomingURL(url)
                }
        }
        .defaultSize(width: 1100, height: 720)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Chat") {
                    appState.currentView = .chat
                }
                .keyboardShortcut("n", modifiers: .command)
            }
        }

        // Menu bar — settings-focused quick access only.
        MenuBarExtra {
            MenuBarSettingsView()
                .environment(appState)
                .frame(width: 440, height: 620)
        } label: {
            Label("Teale", systemImage: "brain.head.profile")
        }
        .menuBarExtraStyle(.window)
    }
}

// MARK: - Main Window View (everything except settings)

struct MainWindowView: View {
    @Environment(AppState.self) private var appState

    private var needsSignIn: Bool {
        let authState = appState.authManager?.authState
        return !(authState?.canUseApp ?? true)
    }

    var body: some View {
        NavigationSplitView {
            MainSidebar()
        } detail: {
            detailContent
        }
        .preferredColorScheme(colorScheme(for: appState.appearance))
        .onChange(of: appState.showSignIn || needsSignIn) { _, shouldShow in
            if shouldShow, let authManager = appState.authManager {
                LoginWindowController.shared.show(authManager: authManager, appState: appState)
            } else {
                LoginWindowController.shared.close()
            }
        }
        .onChange(of: appState.authManager?.authState.isAuthenticated ?? false) { _, isAuthenticated in
            if isAuthenticated {
                appState.showSignIn = false
                LoginWindowController.shared.close()
            }
        }
        .task {
            await appState.startServer()
            await appState.initializeAsync()
            await appState.updateChecker.checkIfNeeded()
        }
        .onAppear {
            NSApp.activate(ignoringOtherApps: true)
            if needsSignIn, let authManager = appState.authManager {
                LoginWindowController.shared.show(authManager: authManager, appState: appState)
            }
        }
    }

    @ViewBuilder
    private var detailContent: some View {
        switch appState.currentView {
        case .chat:
            ChatView()
        case .dashboard:
            DashboardView()
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

    private func colorScheme(for appearance: AppAppearance) -> ColorScheme? {
        switch appearance {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

// MARK: - Main Window Sidebar (no Settings entry)

struct MainSidebar: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var state = appState

        List(selection: Binding(get: { appState.currentView }, set: { appState.currentView = $0 })) {
            Label(appState.loc("sidebar.chat"), systemImage: "bubble.left.and.bubble.right")
                .tag(AppView.chat)
            Label(appState.loc("sidebar.dashboard"), systemImage: "gauge")
                .tag(AppView.dashboard)
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
        .frame(minWidth: 180)
    }
}

// MARK: - Menu Bar Settings Panel

struct MenuBarSettingsView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: 8) {
                Image(systemName: "brain.head.profile")
                    .foregroundStyle(Color(red: 0.0, green: 0.6, blue: 0.6))
                Text("Teale")
                    .font(.headline)
                Spacer()
                Button {
                    openWindow(id: "main")
                    NSApp.activate(ignoringOtherApps: true)
                } label: {
                    Label("Open Teale", systemImage: "macwindow")
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .padding(12)

            Divider()

            ScrollView {
                SettingsView()
                    .frame(maxWidth: .infinity)
            }

            Divider()

            HStack {
                Spacer()
                Button("Quit Teale") {
                    NSApp.terminate(nil)
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
            }
            .padding(8)
        }
        .preferredColorScheme(colorScheme(for: appState.appearance))
    }

    private func colorScheme(for appearance: AppAppearance) -> ColorScheme? {
        switch appearance {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

// MARK: - Login Window (standalone NSWindow for text field support)

@MainActor
final class LoginWindowController {
    static let shared = LoginWindowController()

    private var window: NSWindow?
    private var observationTask: Task<Void, Never>?

    func show(authManager: AuthManager, appState: AppState) {
        if let existing = window, existing.isVisible { return }

        let loginView = LoginView(authManager: authManager)
            .environment(appState)
            .frame(width: 400, height: 500)

        let hostingController = NSHostingController(rootView: loginView)
        let win = NSWindow(contentViewController: hostingController)
        win.title = "Sign In — Teale"
        win.styleMask = [.titled, .closable]
        win.setContentSize(NSSize(width: 400, height: 500))
        win.center()
        win.isReleasedWhenClosed = false
        win.level = .floating

        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        self.window = win

        // Observe auth state directly so the window closes after sign-in
        observationTask?.cancel()
        observationTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                let canUse = authManager.authState.canUseApp
                if canUse {
                    self?.close()
                    break
                }
                // Wait for next change to authState
                await withCheckedContinuation { continuation in
                    withObservationTracking {
                        _ = authManager.authState
                    } onChange: {
                        continuation.resume()
                    }
                }
            }
        }
    }

    func close() {
        observationTask?.cancel()
        observationTask = nil
        window?.close()
        window = nil
    }
}
