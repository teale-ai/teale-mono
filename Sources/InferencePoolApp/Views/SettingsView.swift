import SwiftUI
import ServiceManagement
import SharedTypes
import ClusterKit
import WANKit
import CreditKit
import LocalAPI
import InferenceEngine

struct SettingsView: View {
    @Environment(AppState.self) private var appState
    @State private var launchAtLogin = false
    @State private var maxStorage: Double = 50.0
    @State private var apiPort: String = "11435"
    @State private var clusterPasscode: String = ""
    @State private var wanRelayURL: String = "wss://relay.solair.network/ws"
    @State private var apiKeys: [APIKey] = []
    @State private var newKeyName: String = "Default"
    @State private var generatedKey: String?
    @State private var orgReservation: Double = 60

    var body: some View {
        @Bindable var state = appState

        Form {
            // General
            Section("General") {
                Toggle("Launch at Login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, newValue in
                        setLaunchAtLogin(newValue)
                    }
            }

            // Connect / API
            Section("Connect") {
                if appState.isServerRunning {
                    HStack {
                        Circle()
                            .fill(.green)
                            .frame(width: 8, height: 8)
                        Text("Running at http://localhost:\(appState.serverPort)/v1")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }

                HStack {
                    Text("Port:")
                    TextField("Port", text: $apiPort)
                        .frame(width: 80)
                        .textFieldStyle(.roundedBorder)
                }

                Toggle("Allow Network Access", isOn: $state.allowNetworkAccess)
                Text(appState.allowNetworkAccess
                     ? "Server binds to all interfaces — API key required for requests"
                     : "Server binds to localhost only — no API key needed")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)

                // API Keys
                if !apiKeys.isEmpty {
                    ForEach(apiKeys) { key in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
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

                if let generatedKey {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("New key (copy now — won't be shown again):")
                            .font(.caption)
                            .foregroundStyle(.orange)
                        HStack {
                            Text(generatedKey)
                                .font(.caption2.monospaced())
                                .textSelection(.enabled)
                                .lineLimit(1)
                            Button("Copy") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(generatedKey, forType: .string)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.mini)
                        }
                    }
                    .padding(8)
                    .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
                }

                HStack {
                    TextField("Key name", text: $newKeyName)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 120)
                    Button("Generate API Key") {
                        Task {
                            let key = await appState.apiKeyStore.generateKey(name: newKeyName)
                            generatedKey = key.key
                            newKeyName = "Default"
                            await refreshKeys()
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }

                Button("Copy for Terminal") {
                    let activeKey = apiKeys.first(where: { $0.isActive })?.key ?? "sk-solair-YOUR_KEY_HERE"
                    let snippet = """
                    export OPENAI_API_BASE=http://localhost:\(appState.serverPort)/v1
                    export OPENAI_API_KEY=\(activeKey)
                    """
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(snippet, forType: .string)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Text("Compatible with OpenAI SDK, ollama, conductor.build, and any OpenAI-compatible client")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

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

            // Storage
            Section("Model Storage") {
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
                Link("Source Code", destination: URL(string: "https://github.com/inference-pool")!)
            }

            // Quit
            Section {
                Button("Quit Inference Pool", role: .destructive) {
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
            Task { await refreshKeys() }
        }
    }

    private func refreshKeys() async {
        apiKeys = await appState.apiKeyStore.allKeys()
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
