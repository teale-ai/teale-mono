import SwiftUI
import AppKit
import AppCore
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

        // Run as a regular foreground app so the companion window gets focus.
        NSApplication.shared.setActivationPolicy(.regular)

        Self.installDockIcon()
        Self.patchAppMenuTitle("Teale")

        let state = AppState()
        _appState = State(initialValue: state)
    }

    private func handleIncomingURL(_ url: URL) {
        // Windows-parity: only the teale://auth/callback OAuth flow is wired.
        Task { await appState.authManager?.handleOAuthCallback(url: url) }
    }

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

    private static func installDockIcon() {
        let size: CGFloat = 512
        let symbolConfig = NSImage.SymbolConfiguration(pointSize: size * 0.7, weight: .regular)
        let colorConfig = NSImage.SymbolConfiguration(paletteColors: [.white])
        let combined = symbolConfig.applying(colorConfig)

        guard let symbol = NSImage(
            systemSymbolName: "brain.head.profile",
            accessibilityDescription: "Teale"
        )?.withSymbolConfiguration(combined) else { return }

        let icon = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            let cornerRadius: CGFloat = size * 0.22
            let path = NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius)
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
        // Windows-parity 5-view companion window.
        WindowGroup(id: "main") {
            CompanionRootView()
                .environment(appState)
                .frame(minWidth: 820, minHeight: 620)
                .onOpenURL { url in
                    handleIncomingURL(url)
                }
                .onAppear {
                    NSApp.activate(ignoringOtherApps: true)
                }
                .onChange(of: appState.showSignIn) { _, shouldShow in
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
        }
        .defaultSize(width: 1040, height: 780)

        // Menu bar — windows-parity supply controls + quick access.
        MenuBarExtra {
            CompanionMenuBarView(openMain: {
                NSApp.activate(ignoringOtherApps: true)
                // Bring the main window forward if it exists, otherwise it re-opens.
                NSApp.windows.first { $0.identifier?.rawValue.contains("main") == true }?.makeKeyAndOrderFront(nil)
            })
            .environment(appState)
            .frame(width: 360, height: 320)
        } label: {
            Label("Teale", systemImage: "brain.head.profile")
        }
        .menuBarExtraStyle(.window)
    }
}

// MARK: - Menu Bar (Windows-parity supply controls)

struct CompanionMenuBarView: View {
    @Environment(AppState.self) private var appState
    let openMain: () -> Void

    var body: some View {
        ZStack {
            TealeDesign.pageBackground
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Image(systemName: "brain.head.profile")
                        .foregroundStyle(TealeDesign.teale)
                    Text("Teale")
                        .font(TealeDesign.mono)
                        .foregroundStyle(TealeDesign.text)
                    Spacer()
                    TealeActionButton(title: "Open Teale", primary: true) {
                        openMain()
                    }
                }

                Rectangle()
                    .fill(TealeDesign.border)
                    .frame(height: 1)

                TealeStats {
                    TealeStatRow(
                        label: "State",
                        value: appState.companionState.displayText,
                        valueColor: appState.companionState.chipColor
                    )
                    TealeStatRow(
                        label: "Model",
                        value: appState.engineStatus.currentModel?.name ?? "No model loaded"
                    )
                    TealeStatRow(
                        label: "Wallet",
                        value: appState.wallet.balance.description
                    )
                }

                Spacer()

                HStack {
                    Spacer()
                    TealeActionButton(title: "Quit Teale") {
                        NSApp.terminate(nil)
                    }
                }
            }
            .padding(14)
        }
        .preferredColorScheme(.dark)
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

        observationTask?.cancel()
        observationTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                let canUse = authManager.authState.canUseApp
                if canUse {
                    self?.close()
                    break
                }
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
