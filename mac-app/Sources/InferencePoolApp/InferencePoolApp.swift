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

        Self.installStderrLog()

        // Run as a regular foreground app so the companion window gets focus.
        NSApplication.shared.setActivationPolicy(.regular)

        Self.installDockIcon()
        Self.patchAppMenuTitle("Teale")

        let state = AppState()
        state.updateChecker.startAutomaticChecks()
        _appState = State(initialValue: state)
    }

    private func handleIncomingURL(_ url: URL) {
        let handledByWebCompanion = DesktopCompanionBridge.shared.handleIncomingURL(url)
        if !handledByWebCompanion,
           url.host == "auth",
           url.path == "/callback",
           let authManager = appState.authManager {
            Task { await authManager.handleOAuthCallback(url: url) }
        }
    }

    /// Redirect stderr to a persistent log file. All diagnostics ([WAN],
    /// [PINChat], [PINLocal], engine errors) go to stderr, which is lost when
    /// the app is launched via `open -a` - leaving GUI-launched machines like
    /// Taylor's MBP with no logs at all.
    private static func installStderrLog() {
        let dir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/Teale", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let logURL = dir.appendingPathComponent("teale-stderr.log")
        if !FileManager.default.fileExists(atPath: logURL.path) {
            FileManager.default.createFile(atPath: logURL.path, contents: nil)
        }
        if let handle = try? FileHandle(forWritingTo: logURL) {
            handle.seekToEndOfFile()
            dup2(handle.fileDescriptor, FileHandle.standardError.fileDescriptor)
        }
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
        Window("Teale", id: "main") {
            DesktopCompanionRootView()
                .environment(appState)
                .frame(minWidth: 820, minHeight: 620)
                .onOpenURL { url in
                    handleIncomingURL(url)
                }
                .onAppear {
                    NSApp.activate(ignoringOtherApps: true)
                }
        }
        .defaultSize(width: 1040, height: 780)

        // Menu bar — windows-parity supply controls + quick access.
        MenuBarExtra {
            CompanionMenuBarView()
            .environment(appState)
            .frame(width: 360, height: 400)
        } label: {
            Label("Teale", systemImage: "brain.head.profile")
        }
        .menuBarExtraStyle(.window)
    }
}

// MARK: - Menu Bar (mirrors the simplified home view)

/// Polls the same localhost desktop/PIN APIs the simplified home view
/// uses, so the menu bar shows identical numbers. No auth: the server
/// binds 127.0.0.1 unless network access is enabled.
@MainActor
final class MenuBarViewModel: ObservableObject {
    @Published var earnedCredits: Int64 = 0
    @Published var ratePerMinute: Int64 = 0
    @Published var serving = false
    @Published var supplyEnabled = true
    @Published var supplyDetail = ""
    @Published var pinSummary = ""
    @Published var exitRouting: String?
    @Published var fetchedAt = Date()

    private var pollTask: Task<Void, Never>?
    private let port: Int

    init(port: Int) {
        self.port = port
    }

    func start() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(nanoseconds: 5 * 1_000_000_000)
            }
        }
    }

    private func get(_ path: String) async -> [String: Any]? {
        guard let url = URL(string: "http://127.0.0.1:\(port)\(path)"),
            let (data, _) = try? await URLSession.shared.data(from: url),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return json
    }

    func refresh() async {
        if let snapshot = await get("/v1/desktop/app") {
            let wallet = snapshot["wallet"] as? [String: Any] ?? [:]
            earnedCredits = (wallet["gateway_total_earned_credits"] as? NSNumber)?.int64Value
                ?? (wallet["gateway_total_earned_credits"] as? Int64) ?? earnedCredits
            serving = (snapshot["service_state"] as? String) == "serving"
            ratePerMinute = serving
                ? ((wallet["availability_rate_credits_per_minute"] as? NSNumber)?.int64Value ?? 0)
                : 0
            supplyEnabled = (snapshot["supply_enabled"] as? Bool) ?? supplyEnabled
            supplyDetail = supplyEnabled
                ? ((snapshot["state_reason"] as? String) ?? (snapshot["service_state"] as? String) ?? "")
                : "Off. This machine is not serving inference."
            fetchedAt = Date()
        }
        if let overview = await get("/v1/app/pins") {
            let networks = overview["networks"] as? [[String: Any]] ?? []
            let active = networks.filter { ($0["membership"] as? String) == "active" }.count
            let settings = overview["settings"] as? [String: Any] ?? [:]
            let offering = (settings["exitNodePins"] as? [String])?.count ?? 0
            var parts: [String] = []
            parts.append(active == 1 ? "1 network" : "\(active) networks")
            if offering > 0 {
                parts.append(offering == 1 ? "exit offered to 1" : "exit offered to \(offering)")
            }
            pinSummary = parts.joined(separator: " · ")
        }
        if let status = await get("/v1/app/pins/exit/status"),
            (status["state"] as? String) == "listening" {
            let via = status["viaDevice"] as? String ?? "exit node"
            let host = status["host"] as? String ?? "127.0.0.1"
            let portNum = (status["port"] as? NSNumber)?.intValue ?? 0
            exitRouting = "routing via \(via) · \(host):\(portNum)"
        } else {
            exitRouting = nil
        }
    }

    func setSupply(_ enabled: Bool) async {
        supplyEnabled = enabled
        guard let url = URL(string: "http://127.0.0.1:\(port)/v1/desktop/app/supply") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["enabled": enabled])
        _ = try? await URLSession.shared.data(for: request)
        await refresh()
    }
}

struct CompanionMenuBarView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.openWindow) private var openWindow
    @StateObject private var model = MenuBarViewModel(port: 11435)
    @AppStorage("teale.menuBarEarningsUnit") private var earningsUnit = "credits"

    var body: some View {
        ZStack {
            TealeDesign.pageBackground
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Image(systemName: "brain.head.profile")
                        .foregroundStyle(TealeDesign.teale)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Teale")
                            .font(TealeDesign.mono)
                            .foregroundStyle(TealeDesign.text)
                        Text(BuildVersion.display)
                            .font(TealeDesign.monoTiny)
                            .foregroundStyle(TealeDesign.muted)
                    }
                    Spacer()
                    TealeActionButton(title: "Open Teale", primary: true) {
                        openMainWindow()
                    }
                }

                Rectangle()
                    .fill(TealeDesign.border)
                    .frame(height: 1)

                // earnings - ticks up with availability, like the home view
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(earningsDisplay)
                                .font(TealeDesign.mono)
                                .foregroundStyle(TealeDesign.text)
                            Spacer()
                            Picker("", selection: $earningsUnit) {
                                Text("credits").tag("credits")
                                Text("USD").tag("usd")
                            }
                            .pickerStyle(.segmented)
                            .frame(width: 120)
                        }
                        Text(model.serving
                            ? "accruing ~\(formattedRate) credits/min from availability"
                            : "turn on supply inference to start earning")
                            .font(TealeDesign.monoTiny)
                            .foregroundStyle(TealeDesign.muted)
                    }
                }

                Rectangle()
                    .fill(TealeDesign.border)
                    .frame(height: 1)

                // supply inference
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("supply inference")
                            .font(TealeDesign.mono)
                            .foregroundStyle(TealeDesign.text)
                        Text(model.supplyDetail)
                            .font(TealeDesign.monoTiny)
                            .foregroundStyle(TealeDesign.muted)
                            .lineLimit(2)
                    }
                    Spacer()
                    Toggle("", isOn: Binding(
                        get: { model.supplyEnabled },
                        set: { enabled in Task { await model.setSupply(enabled) } }
                    ))
                    .toggleStyle(.switch)
                    .tint(TealeDesign.teale)
                    .labelsHidden()
                }

                // private inference networks
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("private inference network(s)")
                            .font(TealeDesign.mono)
                            .foregroundStyle(TealeDesign.text)
                        Text(model.pinSummary.isEmpty ? "none yet" : model.pinSummary)
                            .font(TealeDesign.monoTiny)
                            .foregroundStyle(TealeDesign.muted)
                        if let routing = model.exitRouting {
                            Text(routing)
                                .font(TealeDesign.monoTiny)
                                .foregroundStyle(TealeDesign.teale)
                        }
                    }
                    Spacer()
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
        .onAppear { model.start() }
    }

    private var earningsDisplay: String {
        let elapsed = max(0, Date().timeIntervalSince(model.fetchedAt))
        let earned = model.earnedCredits + Int64((Double(model.ratePerMinute) / 60.0) * elapsed)
        if earningsUnit == "usd" {
            return String(format: "$%.4f USD", Double(earned) / 1_000_000.0)
        }
        return "\(earned.formatted()) credits"
    }

    private var formattedRate: String {
        model.ratePerMinute.formatted()
    }

    private func openMainWindow() {
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            NSApp.windows
                .filter { $0.isVisible && $0.title == "Teale" }
                .forEach { window in
                    window.makeKeyAndOrderFront(nil)
                }
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

        observationTask?.cancel()
        observationTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                let isAuthenticated = authManager.authState.isAuthenticated
                if isAuthenticated {
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
