import SwiftUI
import AppCore
import ServiceManagement
import SharedTypes
import ClusterKit
import WANKit
import CreditKit
import LocalAPI
import InferenceEngine
import AuthKit
import WalletKit

struct SettingsView: View {
    @Environment(AppState.self) private var appState
    @State private var launchAtLogin = false
    @State private var apiPort: String = "11435"
    @State private var clusterPasscode: String = ""
    @State private var orgReservation: Double = 60
    @State private var exoBaseURL: String = "http://localhost:52415"
    @State private var exoPreferredModelID: String = ""
    @State private var wanRelayURL: String = "wss://teale-relay.fly.dev/ws"
    @State private var maxStorage: Double = 50

    var body: some View {
        @Bindable var state = appState

        Form {
            // Account
            Section(appState.loc("settings.account")) {
                if let authManager = appState.authManager {
                    switch authManager.authState {
                    case .signedIn(let user):
                        if let phone = user.phone {
                            LabeledContent(appState.loc("common.phone"), value: phone)
                        }
                        if let email = user.email {
                            LabeledContent(appState.loc("common.email"), value: email)
                        }
                        LabeledContent(appState.loc("common.devices"), value: "\(authManager.devices.count)")
                        Button(appState.loc("settings.signOut")) {
                            Task { await authManager.signOut() }
                        }
                    case .signingIn:
                        HStack(spacing: 8) {
                            ProgressView()
                                .controlSize(.small)
                            Text(appState.loc("common.signingIn"))
                                .font(.subheadline)
                        }
                    default:
                        HStack {
                            Image(systemName: "person.crop.circle.badge.questionmark")
                                .foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(appState.loc("settings.notSignedIn"))
                                    .font(.subheadline)
                                Text(appState.loc("settings.signInSubtitle"))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Button(appState.loc("settings.signIn")) {
                            appState.currentView = .settings
                            appState.showSignIn = true
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    }
                } else {
                    HStack {
                        Image(systemName: "person.crop.circle")
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(appState.loc("settings.localMode"))
                                .font(.subheadline)
                            Text(appState.loc("settings.localModeSubtitle"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            // General
            Section(appState.loc("settings.general")) {
                Toggle(appState.loc("settings.launchAtLogin"), isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, newValue in
                        setLaunchAtLogin(newValue)
                    }

                Picker(appState.loc("settings.language"), selection: $state.language) {
                    ForEach(AppLanguage.allCases) { lang in
                        Text(lang.displayName).tag(lang)
                    }
                }

                Toggle(appState.loc("settings.keepAwake"), isOn: $state.keepAwake)
                Text(appState.loc("settings.keepAwakeHelp"))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            Section("Inference Backend") {
                Picker("Backend", selection: $state.inferenceBackend) {
                    ForEach(InferenceBackend.allCases) { backend in
                        Text(backend.displayName).tag(backend)
                    }
                }

                if appState.inferenceBackend == .exo {
                    HStack {
                        Text("Exo URL")
                        TextField("http://localhost:52415", text: $exoBaseURL)
                            .textFieldStyle(.roundedBorder)
                    }

                    HStack {
                        Text("Preferred Model")
                        TextField("Optional model ID", text: $exoPreferredModelID)
                            .textFieldStyle(.roundedBorder)
                    }

                    HStack(spacing: 8) {
                        Circle()
                            .fill(appState.engineStatus.isReady ? .green : .orange)
                            .frame(width: 8, height: 8)
                        Text(appState.exoStatusMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    if !appState.exoRunningModels.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Running in Exo")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            Text(appState.exoRunningModels.joined(separator: ", "))
                                .font(.caption)
                                .textSelection(.enabled)
                        }
                    }

                    if !appState.exoAvailableModels.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Available via Exo")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            Text(appState.exoAvailableModels.prefix(8).joined(separator: ", "))
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                                .textSelection(.enabled)
                        }
                    }

                    Button("Apply Exo Settings") {
                        applyExoSettings()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)

                    Text("Teale will proxy inference through Exo on this Mac. Start and shard the model in Exo itself, then use Teale for chat, credits, and peer routing.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            // Connect Your Agent
            ConnectAgentSection()

            // LAN Cluster
            Section(appState.loc("settings.lanCluster")) {
                Toggle(appState.loc("settings.enableLAN"), isOn: $state.clusterEnabled)

                if appState.clusterEnabled {
                    HStack {
                        Text(appState.loc("settings.clusterPasscode"))
                        SecureField(appState.loc("settings.optional"), text: $clusterPasscode)
                            .frame(width: 150)
                            .textFieldStyle(.roundedBorder)
                            .onChange(of: clusterPasscode) { _, newValue in
                                appState.clusterManager.passcode = newValue.isEmpty ? nil : newValue
                            }
                    }

                    let peerCount = appState.clusterManager.clusterState.connectedPeerCount
                    HStack {
                        Circle()
                            .fill(peerCount > 0 ? .green : .orange)
                            .frame(width: 8, height: 8)
                        Text(peerCount > 0 ? String(format: appState.loc("settings.peersConnected"), peerCount) : appState.loc("settings.searchingPeers"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    VStack(alignment: .leading) {
                        Text(String(format: appState.loc("settings.orgReservation"), Int(orgReservation)))
                            .font(.caption)
                        Slider(value: $orgReservation, in: 0...100, step: 10)
                            .onChange(of: orgReservation) { _, newValue in
                                appState.clusterManager.orgCapacityReservation = newValue / 100.0
                            }
                    }
                    Text(appState.loc("settings.orgReservationHelp"))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            // WAN P2P
            Section(appState.loc("settings.wanP2P")) {
                Toggle(appState.loc("settings.enableWAN"), isOn: $state.wanEnabled)

                if appState.wanEnabled {
                    HStack {
                        Text(appState.loc("settings.relayServer"))
                        TextField("URL", text: $wanRelayURL)
                            .frame(width: 200)
                            .textFieldStyle(.roundedBorder)
                            .onChange(of: wanRelayURL) { _, newValue in
                                appState.wanRelayURL = newValue
                            }
                    }

                    let wanState = appState.wanManager.state
                    HStack {
                        Circle()
                            .fill(wanState.relayStatus == .connected ? .green : .orange)
                            .frame(width: 8, height: 8)
                        Text(wanState.relayStatus == .connected ?
                             String(format: appState.loc("settings.wanPeers"), wanState.connectedPeers.count) :
                             appState.loc("settings.connectingRelay"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    LabeledContent(appState.loc("settings.natType"), value: wanState.natType.rawValue)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let wanLastError = appState.wanLastError {
                    Label(wanLastError, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                LabeledContent("Relay", value: appState.wanManager.state.relayStatus.displayName)
                    .font(.caption)
                LabeledContent("NAT Type", value: appState.wanManager.state.natType.displayName)
                    .font(.caption)
            }

            // Contribution Schedule
            ContributionScheduleSection()

            // Credits
            Section(appState.loc("settings.credits")) {
                LabeledContent(appState.loc("settings.balance"), value: String(format: "%.2f credits", appState.wallet.balance.value))
                LabeledContent(appState.loc("settings.totalEarned"), value: String(format: "%.2f", appState.wallet.totalEarned.value))
                LabeledContent(appState.loc("settings.totalSpent"), value: String(format: "%.2f", appState.wallet.totalSpent.value))

                Button(appState.loc("settings.viewWallet")) {
                    appState.currentView = .wallet
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            // Model Management
            Section(appState.loc("settings.modelStorage")) {
                Toggle("Auto-manage models", isOn: $state.autoManageModels)
                Text("Automatically download and load in-demand models so your node serves what the network needs.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)

                VStack(alignment: .leading) {
                    Text(String(format: appState.loc("settings.maxStorage"), Int(maxStorage)))
                    Slider(value: $maxStorage, in: 5...200, step: 5)
                        .onChange(of: maxStorage) { _, newValue in
                            appState.maxStorageGB = newValue
                        }
                }
            }

            // Hardware Info
            Section(appState.loc("settings.hardware")) {
                LabeledContent(appState.loc("settings.chip"), value: appState.hardware.chipName)
                LabeledContent(appState.loc("settings.ram"), value: "\(Int(appState.hardware.totalRAMGB)) GB")
                LabeledContent(appState.loc("settings.gpuCores"), value: "\(appState.hardware.gpuCoreCount)")
                LabeledContent(appState.loc("settings.memBandwidth"), value: String(format: "%.0f GB/s", appState.hardware.memoryBandwidthGBs))
                LabeledContent(appState.loc("settings.deviceTier"), value: tierDescription)
            }

            // About
            Section(appState.loc("settings.about")) {
                LabeledContent(appState.loc("settings.version"), value: displayVersion)
                LabeledContent(appState.loc("settings.engine"), value: appState.inferenceEngineName)
                Link(appState.loc("settings.sourceCode"), destination: URL(string: "https://github.com/taylorhou/teale-mac-app")!)
            }

            // Quit
            Section {
                Button(appState.loc("settings.quit"), role: .destructive) {
                    NSApplication.shared.terminate(nil)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(appState.loc("settings.title"))
        .onAppear {
            apiPort = String(appState.serverPort)
            orgReservation = appState.clusterManager.orgCapacityReservation * 100
            wanRelayURL = appState.wanRelayURL
            exoBaseURL = appState.exoBaseURL
            exoPreferredModelID = appState.exoPreferredModelID
        }
    }

    private var displayVersion: String {
        let info = Bundle.main.infoDictionary ?? [:]
        if let buildDate = info["TealeBuildDate"] as? String, !buildDate.isEmpty {
            return buildDate
        }

        let short = info["CFBundleShortVersionString"] as? String
        let build = info["CFBundleVersion"] as? String

        switch (short, build) {
        case let (short?, build?) where short != build:
            return "\(short) (\(build))"
        case let (short?, _):
            return short
        case let (_, build?):
            return build
        default:
            return "Unknown"
        }
    }

    private var tierDescription: String {
        switch appState.hardware.tier {
        case .tier1: return "Tier 1 — Desktop (backbone)"
        case .tier2: return "Tier 2 — Laptop"
        case .tier3: return "Tier 3 — Tablet"
        case .tier4: return "Tier 4 — Mobile"
        }
    }

    private var wanStatusText: String {
        if appState.isWANBusy {
            return "Connecting to relay..."
        }
        if appState.wanEnabled {
            let peerCount = appState.wanManager.state.connectedPeers.count
            return peerCount == 0 ? "WAN enabled, no peers connected" : "\(peerCount) WAN peer(s)"
        }
        if appState.wanLastError != nil {
            return "WAN failed to enable"
        }
        return "WAN is off"
    }

    private var wanStatusColor: Color {
        if appState.isWANBusy {
            return .orange
        }
        if appState.wanEnabled {
            return appState.wanManager.state.relayStatus == .connected ? .green : .orange
        }
        return appState.wanLastError == nil ? .secondary : .red
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            launchAtLogin = !enabled
        }
    }

    private func applyExoSettings() {
        appState.exoBaseURL = exoBaseURL
        appState.exoPreferredModelID = exoPreferredModelID
        Task { await appState.refreshStatus() }
    }
}

// MARK: - Connect Your Agent Section

private struct ConnectAgentSection: View {
    @Environment(AppState.self) private var appState
    @State private var apiKeys: [APIKey] = []
    @State private var generatedKey: String?
    @State private var copied: CopiedItem?
    @State private var showAdvanced = false

    private enum CopiedItem: Equatable {
        case key, endpoint, python, curl, envVars
    }

    var body: some View {
        Section {
            // Server status
            serverStatus

            // One-click key generation or show existing key
            if apiKeys.filter(\.isActive).isEmpty {
                generateKeyButton
            } else {
                activeKeyDisplay
            }

            // Just-generated key (shown once)
            if let generatedKey {
                newKeyBanner(key: generatedKey)
            }

            // Quick-copy snippets
            quickCopySnippets

            // Advanced
            DisclosureGroup(appState.loc("agent.advanced"), isExpanded: $showAdvanced) {
                advancedSection
            }
        } header: {
            Label(appState.loc("agent.connect"), systemImage: "link")
        } footer: {
            Text(appState.loc("agent.footer"))
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .onAppear {
            Task { await refreshKeys() }
        }
    }

    // MARK: - Server Status

    private var serverStatus: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(appState.isServerRunning ? .green : .red)
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 1) {
                Text(appState.isServerRunning ? appState.loc("agent.serverRunning") : appState.loc("agent.serverStarting"))
                    .font(.callout.weight(.medium))
                Text(endpoint)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            Spacer()
            copyButton(text: endpoint, item: .endpoint, label: appState.loc("common.copy"))
        }
    }

    // MARK: - Generate Key

    private var generateKeyButton: some View {
        Button {
            Task {
                let key = await appState.apiKeyStore.generateKey(name: "My Agent")
                generatedKey = key.key
                await refreshKeys()
            }
        } label: {
            HStack {
                Image(systemName: "key.fill")
                Text(appState.loc("agent.generateKey"))
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.regular)
    }

    // MARK: - Active Key

    private var activeKeyDisplay: some View {
        Group {
            if let key = apiKeys.first(where: \.isActive) {
                HStack(spacing: 8) {
                    Image(systemName: "key.fill")
                        .foregroundStyle(.green)
                        .frame(width: 20)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(key.name)
                            .font(.callout.weight(.medium))
                        Text(key.truncatedKey)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    copyButton(text: key.key, item: .key, label: appState.loc("common.copy"))
                }
            }
        }
    }

    // MARK: - New Key Banner

    private func newKeyBanner(key: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.caption)
                Text(appState.loc("agent.saveKeyWarning"))
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.orange)
            }
            HStack {
                Text(key)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .lineLimit(1)
                Spacer()
                copyButton(text: key, item: .key, label: appState.loc("common.copy"))
            }
        }
        .padding(10)
        .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Quick Copy Snippets

    private var quickCopySnippets: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(appState.loc("agent.quickSetup"))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            HStack(spacing: 6) {
                snippetButton(
                    title: "Python",
                    icon: "chevron.left.forwardslash.chevron.right",
                    item: .python
                ) {
                    pythonSnippet
                }
                snippetButton(
                    title: "cURL",
                    icon: "terminal",
                    item: .curl
                ) {
                    curlSnippet
                }
                snippetButton(
                    title: "Env Vars",
                    icon: "doc.text",
                    item: .envVars
                ) {
                    envVarsSnippet
                }
            }
        }
    }

    private func snippetButton(title: String, icon: String, item: CopiedItem, snippet: @escaping () -> String) -> some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(snippet(), forType: .string)
            withAnimation { copied = item }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                withAnimation { if copied == item { copied = nil } }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: copied == item ? "checkmark" : icon)
                    .frame(width: 14)
                Text(copied == item ? appState.loc("common.copied") : title)
            }
            .font(.caption)
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .tint(copied == item ? .green : nil)
    }

    // MARK: - Advanced

    private var advancedSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            // All keys list
            if apiKeys.count > 1 || apiKeys.contains(where: { !$0.isActive }) {
                ForEach(apiKeys) { key in
                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(key.name)
                                .font(.caption.weight(.medium))
                            Text(key.truncatedKey)
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if !key.isActive {
                            Text(appState.loc("agent.revoked"))
                                .font(.caption2)
                                .foregroundStyle(.red)
                        } else {
                            Button(appState.loc("agent.revoke")) {
                                Task {
                                    await appState.apiKeyStore.revokeKey(id: key.id)
                                    await refreshKeys()
                                }
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.mini)
                        }
                    }
                }
            }

            // Generate another key
            Button(appState.loc("agent.generateAnother")) {
                Task {
                    let key = await appState.apiKeyStore.generateKey(name: "Key \(apiKeys.count + 1)")
                    generatedKey = key.key
                    await refreshKeys()
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            Divider()

            // Network access toggle
            @Bindable var state = appState
            Toggle(appState.loc("agent.allowNetwork"), isOn: $state.allowNetworkAccess)
            Text(appState.allowNetworkAccess
                 ? appState.loc("agent.networkOn")
                 : appState.loc("agent.networkOff"))
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: - Helpers

    private var activeKey: String {
        apiKeys.first(where: \.isActive)?.key ?? "YOUR_API_KEY"
    }

    private var endpoint: String {
        "http://localhost:\(appState.serverPort)/v1"
    }

    private var pythonSnippet: String {
        """
        from openai import OpenAI

        client = OpenAI(
            base_url="\(endpoint)",
            api_key="\(activeKey)",
        )

        response = client.chat.completions.create(
            model="local",
            messages=[{"role": "user", "content": "Hello!"}],
        )
        print(response.choices[0].message.content)
        """
    }

    private var curlSnippet: String {
        """
        curl \(endpoint)/chat/completions \\
          -H "Authorization: Bearer \(activeKey)" \\
          -H "Content-Type: application/json" \\
          -d '{"model":"local","messages":[{"role":"user","content":"Hello!"}]}'
        """
    }

    private var envVarsSnippet: String {
        """
        export OPENAI_API_BASE=\(endpoint)
        export OPENAI_API_KEY=\(activeKey)
        """
    }

    private func copyButton(text: String, item: CopiedItem, label: String) -> some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            withAnimation { copied = item }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                withAnimation { if copied == item { copied = nil } }
            }
        } label: {
            HStack(spacing: 3) {
                Image(systemName: copied == item ? "checkmark" : "doc.on.doc")
                    .frame(width: 12)
                Text(copied == item ? appState.loc("common.copied") : label)
            }
            .font(.caption)
        }
        .buttonStyle(.bordered)
        .controlSize(.mini)
        .tint(copied == item ? .green : nil)
    }

    private func refreshKeys() async {
        apiKeys = await appState.apiKeyStore.allKeys()
    }
}

// MARK: - Contribution Schedule Section

private struct ContributionScheduleSection: View {
    @Environment(AppState.self) private var appState
    @State private var selectedPreset: SchedulePreset = .alwaysOn
    @State private var onlyWhenPluggedIn: Bool = false
    @State private var onlyOnWiFi: Bool = false
    @State private var showGrid: Bool = false

    var body: some View {
        Section(appState.loc("settings.contributionSchedule")) {
            Picker(appState.loc("settings.preset"), selection: $selectedPreset) {
                ForEach(SchedulePreset.allCases, id: \.self) { preset in
                    Text(preset.displayName).tag(preset)
                }
            }
            .onChange(of: selectedPreset) { _, newValue in
                var schedule = ContributionSchedule.fromPreset(newValue)
                schedule.onlyWhenPluggedIn = onlyWhenPluggedIn
                schedule.onlyOnWiFi = onlyOnWiFi
                appState.throttler.updateSchedule(schedule)
            }

            Toggle(appState.loc("settings.onlyPluggedIn"), isOn: $onlyWhenPluggedIn)
                .onChange(of: onlyWhenPluggedIn) { _, newValue in
                    var schedule = appState.throttler.contributionSchedule
                    schedule.onlyWhenPluggedIn = newValue
                    appState.throttler.updateSchedule(schedule)
                }

            Toggle(appState.loc("settings.onlyWiFi"), isOn: $onlyOnWiFi)
                .onChange(of: onlyOnWiFi) { _, newValue in
                    var schedule = appState.throttler.contributionSchedule
                    schedule.onlyOnWiFi = newValue
                    appState.throttler.updateSchedule(schedule)
                }

            Button(showGrid ? appState.loc("settings.hideSchedule") : appState.loc("settings.editSchedule")) {
                showGrid.toggle()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            if showGrid {
                ScheduleGridView(schedule: Binding(
                    get: { appState.throttler.contributionSchedule },
                    set: { appState.throttler.updateSchedule($0) }
                ))
            }

            Text(appState.loc("settings.scheduleHelp"))
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .onAppear {
            let schedule = appState.throttler.contributionSchedule
            selectedPreset = schedule.preset ?? .alwaysOn
            onlyWhenPluggedIn = schedule.onlyWhenPluggedIn
            onlyOnWiFi = schedule.onlyOnWiFi
        }
    }
}

// MARK: - Schedule Grid View

private struct ScheduleGridView: View {
    @Environment(AppState.self) private var appState
    @Binding var schedule: ContributionSchedule

    private var days: [String] {
        [appState.loc("day.mon"), appState.loc("day.tue"), appState.loc("day.wed"), appState.loc("day.thu"), appState.loc("day.fri"), appState.loc("day.sat"), appState.loc("day.sun")]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            // Hour headers
            HStack(spacing: 1) {
                Text("")
                    .frame(width: 30)
                ForEach(0..<24, id: \.self) { hour in
                    Text(hour % 6 == 0 ? "\(hour)" : "")
                        .font(.system(size: 7))
                        .frame(width: 12)
                }
            }

            ForEach(0..<7, id: \.self) { day in
                HStack(spacing: 1) {
                    // Day label (tappable to toggle row)
                    Text(days[day])
                        .font(.system(size: 9, weight: .medium))
                        .frame(width: 30, alignment: .trailing)
                        .onTapGesture {
                            let allOn = schedule.weeklyGrid[day].allSatisfy { $0 }
                            for hour in 0..<24 {
                                schedule.weeklyGrid[day][hour] = !allOn
                            }
                        }

                    // Hour cells
                    ForEach(0..<24, id: \.self) { hour in
                        Rectangle()
                            .fill(schedule.weeklyGrid[day][hour] ? Color.green.opacity(0.7) : Color.gray.opacity(0.2))
                            .frame(width: 12, height: 12)
                            .cornerRadius(2)
                            .onTapGesture {
                                schedule.weeklyGrid[day][hour].toggle()
                            }
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }
}
