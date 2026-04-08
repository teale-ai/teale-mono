import SwiftUI
import ServiceManagement
import SharedTypes
import ClusterKit
import WANKit
import CreditKit
import LocalAPI
import InferenceEngine
import AuthKit

struct SettingsView: View {
    @Environment(AppState.self) private var appState
    @State private var launchAtLogin = false
    @State private var maxStorage: Double = 50.0
    @State private var apiPort: String = "11435"
    @State private var clusterPasscode: String = ""
    @State private var wanRelayURL: String = "wss://relay.teale.network/ws"
    @State private var orgReservation: Double = 60

    var body: some View {
        @Bindable var state = appState

        Form {
            // Account
            Section("Account") {
                if let authManager = appState.authManager {
                    switch authManager.authState {
                    case .signedIn(let user):
                        if let phone = user.phone {
                            LabeledContent("Phone", value: phone)
                        }
                        if let email = user.email {
                            LabeledContent("Email", value: email)
                        }
                        LabeledContent("Devices", value: "\(authManager.devices.count)")
                        Button("Sign Out") {
                            Task { await authManager.signOut() }
                        }
                    case .signingIn:
                        HStack(spacing: 8) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Signing in...")
                                .font(.subheadline)
                        }
                    default:
                        HStack {
                            Image(systemName: "person.crop.circle.badge.questionmark")
                                .foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Not signed in")
                                    .font(.subheadline)
                                Text("Sign in to sync devices and back up your wallet")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Button("Sign In") {
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
                            Text("Local mode")
                                .font(.subheadline)
                            Text("Configure Supabase to enable sign-in and device sync")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            // General
            Section("General") {
                Toggle("Launch at Login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, newValue in
                        setLaunchAtLogin(newValue)
                    }
            }

            // Connect Your Agent
            ConnectAgentSection()

            // LAN Cluster
            Section("LAN Cluster") {
                Toggle("Enable LAN Discovery", isOn: $state.clusterEnabled)

                if appState.clusterEnabled {
                    HStack {
                        Text("Cluster Passcode:")
                        SecureField("Optional", text: $clusterPasscode)
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
                        Text(peerCount > 0 ? "\(peerCount) peer(s) connected" : "Searching for peers...")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    VStack(alignment: .leading) {
                        Text("Org capacity reservation: \(Int(orgReservation))%")
                            .font(.caption)
                        Slider(value: $orgReservation, in: 0...100, step: 10)
                            .onChange(of: orgReservation) { _, newValue in
                                appState.clusterManager.orgCapacityReservation = newValue / 100.0
                            }
                    }
                    Text("Nodes with the same passcode form your organization. Reserved capacity serves org members first.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            // WAN P2P
            Section("WAN P2P Network") {
                Toggle("Enable WAN", isOn: $state.wanEnabled)

                if appState.wanEnabled {
                    HStack {
                        Text("Relay Server:")
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
                             "\(wanState.connectedPeers.count) WAN peer(s)" :
                             "Connecting to relay...")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    LabeledContent("NAT Type", value: wanState.natType.rawValue)
                        .font(.caption)
                }
            }

            // Contribution Schedule
            ContributionScheduleSection()

            // Credits
            Section("Credits") {
                LabeledContent("Balance", value: String(format: "%.2f credits", appState.wallet.balance.value))
                LabeledContent("Total Earned", value: String(format: "%.2f", appState.wallet.totalEarned.value))
                LabeledContent("Total Spent", value: String(format: "%.2f", appState.wallet.totalSpent.value))

                Button("View Wallet") {
                    appState.currentView = .wallet
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            // Storage & Model Management
            Section("Model Management") {
                Toggle("Auto-manage models", isOn: $state.autoManageModels)
                Text("Automatically download and load in-demand models so your node serves what the network needs. Models are swapped based on request patterns from connected peers.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)

                VStack(alignment: .leading) {
                    Text("Maximum storage: \(Int(maxStorage)) GB")
                    Slider(value: $maxStorage, in: 5...200, step: 5)
                }
            }

            // Hardware Info
            Section("Hardware") {
                LabeledContent("Chip", value: appState.hardware.chipName)
                LabeledContent("RAM", value: "\(Int(appState.hardware.totalRAMGB)) GB")
                LabeledContent("GPU Cores", value: "\(appState.hardware.gpuCoreCount)")
                LabeledContent("Memory Bandwidth", value: String(format: "%.0f GB/s", appState.hardware.memoryBandwidthGBs))
                LabeledContent("Device Tier", value: tierDescription)
            }

            // About
            Section("About") {
                LabeledContent("Version", value: "0.1.0")
                LabeledContent("Engine", value: "MLX")
                Link("Source Code", destination: URL(string: "https://github.com/taylorhou/teale-mac-app")!)
            }

            // Quit
            Section {
                Button("Quit Teale", role: .destructive) {
                    NSApplication.shared.terminate(nil)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
        .onAppear {
            maxStorage = appState.maxStorageGB
            apiPort = String(appState.serverPort)
            orgReservation = appState.clusterManager.orgCapacityReservation * 100
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
            DisclosureGroup("Advanced", isExpanded: $showAdvanced) {
                advancedSection
            }
        } header: {
            Label("Connect Your Agent", systemImage: "link")
        } footer: {
            Text("Works with any OpenAI-compatible client — Claude Code, Cursor, Hermes, OpenClaw, Python SDK, and more.")
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
                Text(appState.isServerRunning ? "API Server Running" : "API Server Starting...")
                    .font(.callout.weight(.medium))
                Text(endpoint)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            Spacer()
            copyButton(text: endpoint, item: .endpoint, label: "Copy")
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
                Text("Generate API Key")
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
                    copyButton(text: key.key, item: .key, label: "Copy Key")
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
                Text("Save this key — it won't be shown again")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.orange)
            }
            HStack {
                Text(key)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .lineLimit(1)
                Spacer()
                copyButton(text: key, item: .key, label: "Copy")
            }
        }
        .padding(10)
        .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Quick Copy Snippets

    private var quickCopySnippets: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Quick Setup")
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
                Text(copied == item ? "Copied" : title)
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
                            Text("Revoked")
                                .font(.caption2)
                                .foregroundStyle(.red)
                        } else {
                            Button("Revoke") {
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
            Button("Generate Another Key") {
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
            Toggle("Allow Network Access", isOn: $state.allowNetworkAccess)
            Text(appState.allowNetworkAccess
                 ? "Accepting requests from other devices on the network"
                 : "Only accepting requests from this Mac (localhost)")
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
                Text(copied == item ? "Copied" : label)
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
        Section("Contribution Schedule") {
            Picker("Preset", selection: $selectedPreset) {
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

            Toggle("Only when plugged in", isOn: $onlyWhenPluggedIn)
                .onChange(of: onlyWhenPluggedIn) { _, newValue in
                    var schedule = appState.throttler.contributionSchedule
                    schedule.onlyWhenPluggedIn = newValue
                    appState.throttler.updateSchedule(schedule)
                }

            Toggle("Only on Wi-Fi", isOn: $onlyOnWiFi)
                .onChange(of: onlyOnWiFi) { _, newValue in
                    var schedule = appState.throttler.contributionSchedule
                    schedule.onlyOnWiFi = newValue
                    appState.throttler.updateSchedule(schedule)
                }

            Button(showGrid ? "Hide Schedule" : "Edit Schedule") {
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

            Text("Controls when your machine serves network requests. Local inference is always available.")
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
    @Binding var schedule: ContributionSchedule

    private let days = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]

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
