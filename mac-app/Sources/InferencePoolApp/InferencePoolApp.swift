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
        Self.rejectCLIArguments()

        // LaunchServices alone does not serialize a login item against the
        // LaunchAgent or a direct executable launch (#344). Claim the
        // kernel-backed per-user lock before AppState starts API, updater, or
        // relay services. A crashed owner cannot leave a stale lock.
        guard AppInstanceLock.shared.acquire() else {
            Self.activateExistingInstance()
            exit(0)
        }

        // Disable Hub library's NetworkMonitor offline mode detection
        // which incorrectly reports "expensive" connections and blocks downloads
        setenv("CI_DISABLE_NETWORK_MONITOR", "1", 1)

        Self.installStderrLog()

        // Fleet boxes (teale.fleetSupply persisted by --fleet-supply) must
        // never surface a GUI: the auto-updater relaunches the bare binary
        // with no argv, and a bare boot used to appear as a full Dock app
        // whose process then owned the relay registration (#222 - fleet's
        // Air/16 stray-GUI incidents, Sep 6). Run accessory: no Dock icon,
        // no menu bar presence; the supply stack still boots via the
        // persisted-prefs restore.
        let isFleetSupply = UserDefaults.standard.bool(forKey: "teale.fleetSupply")
        NSApplication.shared.setActivationPolicy(isFleetSupply ? .accessory : .regular)

        Self.patchAppMenuTitle("Teale")

        let state = AppState()
        Self.enableFleetSupplyModeIfRequested()
        state.updateChecker.startAutomaticChecks()
        // #335: if an update swaps the bundle under this process (the
        // updater can run in ANY Teale process on this Mac), notice the
        // stale image and exit so the updated build can own :11435.
        StaleImageWatchdog.shared.start()
        _appState = State(initialValue: state)
    }

    /// `--fleet-supply`: fleet Macs boot this binary headless via LaunchAgent
    /// (fleet-deploy-mac.sh) and must join the network without UI toggles.
    /// Until this landed the flag was silently ignored, so fleet boxes booted
    /// with WAN off and never registered with the relay - they only served
    /// while a wan-enabled process (teale-cli up/serve, or a UI toggle)
    /// happened to be alive.
    ///
    /// Implemented by persisting the toggle prefs rather than setting the
    /// in-memory properties: the auto-updater relaunches the bare binary
    /// with no arguments (UpdateChecker), while AppState's initializeAsync
    /// restores these prefs and enables WAN/cluster through the normal
    /// didSet path on every boot - one enable, no double-toggle, and the
    /// intent survives relaunches that drop argv.
    private static func enableFleetSupplyModeIfRequested() {
        guard CommandLine.arguments.dropFirst().contains("--fleet-supply") else { return }
        FileHandle.standardError.write(Data(
            "[Fleet] --fleet-supply: persisting wanEnabled/clusterEnabled so boot restore joins the network\n".utf8))
        UserDefaults.standard.set(true, forKey: "teale.fleetSupply")
        UserDefaults.standard.set(true, forKey: "teale.clusterEnabled")
        UserDefaults.standard.set(true, forKey: "teale.wanEnabled")
    }

    /// The app binary ignores CLI arguments and boots the full SwiftUI app,
    /// which reads as a HANG when someone runs `teale wallet balance` etc.
    /// over SSH (fleet evidence: #199 - AppKit event loop, zero network
    /// activity, looked like a network stall). Fail loudly instead and point
    /// at the real CLI.
    private static func rejectCLIArguments() {
        guard let hit = cliSubcommand(in: Array(CommandLine.arguments.dropFirst())) else { return }
        FileHandle.standardError.write(Data("""
        teale: '\(hit)' is a command for the teale-cli binary, not the Teale app.
        Use `teale-cli \(hit) ...` (the app binary always launches the GUI).

        """.utf8))
        exit(2)
    }

    /// The app takes no positional arguments, so any bare first word
    /// (`supply`, `settings`, `mcp`, `assess`, ... - whatever the Rust
    /// teale-cli grows) is a misdirected CLI invocation. LaunchServices,
    /// Xcode and the fleet LaunchAgent only pass dash-prefixed arguments
    /// (`-psn_...`, `-NSDocumentRevisionsDebugMode YES`, `--fleet-supply`),
    /// so a first argument starting with "-" is tolerated.
    static func cliSubcommand(in arguments: [String]) -> String? {
        guard let first = arguments.first?.trimmingCharacters(in: .whitespaces),
              !first.isEmpty,
              !first.hasPrefix("-") else { return nil }
        return first
    }

    /// `teale://` deep links. The gateway magic link
    /// (`teale://auth/session?token=...`) is adopted natively by AuthManager
    /// - the token is never handed to the web view - and the page is then
    /// told to re-poll so it shows the signed-in state. Nothing else is
    /// routed on macOS (no invite handler exists in this app).
    private func handleIncomingURL(_ url: URL) {
        guard url.scheme?.lowercased() == "teale" else { return }
        if AuthManager.isSessionDeepLink(url) {
            guard let authManager = appState.authManager else { return }
            Task { @MainActor in
                if await authManager.handleOAuthCallback(url: url) {
                    DesktopCompanionBridge.shared.refreshSnapshotInPage()
                }
            }
            return
        }
        FileHandle.standardError.write(Data(
            "[DeepLink] ignoring unsupported teale:// link (host=\(url.host ?? "-"))\n".utf8))
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

    private static func activateExistingInstance() {
        NSRunningApplication.runningApplications(
            withBundleIdentifier: "com.teale.app"
        )
        .first(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier })?
        .activate(options: [.activateAllWindows])
    }

    static var menuBarIcon: Image {
        guard let url = Bundle.module.url(
            forResource: "MenuBarIcon",
            withExtension: "png"
        ), let image = NSImage(contentsOf: url) else {
            return Image(systemName: "leaf")
        }
        image.isTemplate = true
        return Image(nsImage: image)
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
            Self.menuBarIcon
                .accessibilityLabel("Teale")
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
    // When the gateway wallet total was last synced; the earnings display
    // interpolates from this anchor so it never rubber-bands between polls.
    @Published var syncedAt: Date?
    @Published var stateReason: String?
    @Published var serviceState: String?

    /// Earnings caption: the accrual rate while serving; why not while
    /// supply is on but not serving yet; the "turn on" hint only when
    /// supply is actually off.
    var earningsCaption: String {
        if serving {
            return "accruing ~\(ratePerMinute.formatted()) credits/min from availability"
        }
        guard supplyEnabled else {
            return "turn on supply inference to start earning"
        }
        if let stateReason, !stateReason.isEmpty {
            return "not earning yet: \(stateReason)"
        }
        return "not earning yet (\(serviceState ?? "starting"))"
    }

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
            if let syncedSecs = (wallet["gateway_synced_at"] as? NSNumber)?.doubleValue {
                syncedAt = Date(timeIntervalSince1970: syncedSecs)
            }
            serving = (snapshot["service_state"] as? String) == "serving"
            ratePerMinute = serving
                ? ((wallet["availability_rate_credits_per_minute"] as? NSNumber)?.int64Value ?? 0)
                : 0
            supplyEnabled = (snapshot["supply_enabled"] as? Bool) ?? supplyEnabled
            stateReason = snapshot["state_reason"] as? String
            serviceState = snapshot["service_state"] as? String
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

    private static var menuBarBrandMark: some View {
        TealeApp.menuBarIcon
            .frame(width: 18, height: 18)
            .foregroundStyle(TealeDesign.teale)
    }

    var body: some View {
        ZStack {
            TealeDesign.pageBackground
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Self.menuBarBrandMark
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
                        Text(model.earningsCaption)
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
        // Anchor to the wallet sync time, not the poll time: the synced base
        // only moves on gateway sync, so a fetch-time anchor snaps the count
        // back whenever a poll lands without a new sync. Cap the horizon so
        // a dead sync reads as stale, not as runaway accrual.
        let anchor = model.syncedAt ?? model.fetchedAt
        let elapsed = min(max(0, Date().timeIntervalSince(anchor)), 600)
        let earned = model.earnedCredits + Int64((Double(model.ratePerMinute) / 60.0) * elapsed)
        if earningsUnit == "usd" {
            return String(format: "$%.4f USD", Double(earned) / 1_000_000.0)
        }
        return "\(earned.formatted()) credits"
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
