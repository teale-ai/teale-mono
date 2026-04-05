import SwiftUI
import SharedTypes
import HardwareProfile
import ClusterKit
import WANKit
import CreditKit

struct DashboardView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Status Header
                StatusHeaderView()

                Divider()

                // Hardware Info
                HardwareInfoSection()

                // Cluster Summary (if enabled)
                if appState.clusterEnabled {
                    Divider()
                    ClusterSummarySection()
                }

                // WAN Summary (if enabled)
                if appState.wanEnabled {
                    Divider()
                    WANSummarySection()
                }

                Divider()

                // Credit Balance
                CreditBalanceSection()

                Divider()

                // Engine Status
                EngineStatusSection()

                Divider()

                // Quick Actions
                QuickActionsSection()
            }
            .padding()
        }
        .navigationTitle("Dashboard")
    }
}

// MARK: - Status Header

private struct StatusHeaderView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        HStack {
            Circle()
                .fill(statusColor)
                .frame(width: 10, height: 10)
            Text(appState.engineStatus.displayText)
                .font(.headline)
            Spacer()
            if appState.isServerRunning {
                Label("API: \(appState.serverPort)", systemImage: "network")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var statusColor: Color {
        switch appState.engineStatus {
        case .ready: return .green
        case .generating: return .blue
        case .loadingModel: return .orange
        case .error: return .red
        case .paused: return .yellow
        case .idle: return .gray
        }
    }
}

// MARK: - Hardware Info

private struct HardwareInfoSection: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Hardware")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            HStack(spacing: 16) {
                InfoPill(icon: "cpu", text: appState.hardware.chipName)
                InfoPill(icon: "memorychip", text: "\(Int(appState.hardware.totalRAMGB)) GB RAM")
                InfoPill(icon: "gpu", text: "\(appState.hardware.gpuCoreCount) GPU cores")
            }

            HStack(spacing: 16) {
                InfoPill(
                    icon: "thermometer",
                    text: appState.throttler.thermalMonitor.thermalLevel.rawValue.capitalized,
                    color: thermalColor
                )
                InfoPill(
                    icon: appState.throttler.powerMonitor.powerState.isOnACPower ? "bolt.fill" : "battery.50",
                    text: powerText,
                    color: powerColor
                )
                InfoPill(
                    icon: "speedometer",
                    text: "Throttle: \(appState.throttler.throttleLevel.rawValue)%"
                )
            }
        }
    }

    private var thermalColor: Color {
        switch appState.throttler.thermalMonitor.thermalLevel {
        case .nominal: return .green
        case .fair: return .yellow
        case .serious: return .orange
        case .critical: return .red
        }
    }

    private var powerText: String {
        let power = appState.throttler.powerMonitor.powerState
        if power.isOnACPower { return "AC Power" }
        if let battery = power.batteryLevel {
            return "\(Int(battery * 100))% Battery"
        }
        return "Battery"
    }

    private var powerColor: Color {
        let power = appState.throttler.powerMonitor.powerState
        if power.isOnACPower { return .green }
        if let battery = power.batteryLevel, battery < 0.2 { return .red }
        return .yellow
    }
}

// MARK: - Info Pill

private struct InfoPill: View {
    let icon: String
    let text: String
    var color: Color = .secondary

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .foregroundStyle(color)
            Text(text)
        }
        .font(.caption)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.quaternary)
        .clipShape(Capsule())
    }
}

// MARK: - Engine Status

private struct EngineStatusSection: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Engine")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            if let model = appState.selectedModel {
                HStack {
                    VStack(alignment: .leading) {
                        Text(model.name)
                            .font(.body.bold())
                        Text("\(model.parameterCount) \(model.quantization.displayName)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Unload") {
                        Task { await appState.unloadModel() }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            } else {
                Text("No model loaded")
                    .foregroundStyle(.secondary)
                Button("Browse Models") {
                    appState.currentView = .models
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }
}

// MARK: - Quick Actions

private struct QuickActionsSection: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Quick Actions")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                Button {
                    appState.currentView = .chat
                } label: {
                    Label("New Chat", systemImage: "plus.bubble")
                }
                .buttonStyle(.bordered)

                Button {
                    if let port = Optional(appState.serverPort) {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString("http://localhost:\(port)/v1", forType: .string)
                    }
                } label: {
                    Label("Copy API URL", systemImage: "doc.on.doc")
                }
                .buttonStyle(.bordered)
            }
        }
    }
}

// MARK: - Cluster Summary

private struct ClusterSummarySection: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Cluster")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("View") {
                    appState.currentView = .cluster
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
            }

            let state = appState.clusterManager.clusterState
            if state.connectedPeerCount > 0 {
                HStack(spacing: 12) {
                    InfoPill(
                        icon: "desktopcomputer",
                        text: "\(state.connectedPeerCount + 1) devices",
                        color: .green
                    )
                    InfoPill(
                        icon: "memorychip",
                        text: "\(Int(state.totalClusterRAMGB + appState.hardware.totalRAMGB)) GB total"
                    )
                }
            } else {
                HStack {
                    ProgressView()
                        .controlSize(.small)
                    Text("Searching for peers...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

// MARK: - WAN Summary

private struct WANSummarySection: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("WAN Network")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("View") {
                    appState.currentView = .wan
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
            }

            let wanState = appState.wanManager.state
            if !wanState.connectedPeers.isEmpty {
                HStack(spacing: 12) {
                    InfoPill(
                        icon: "globe",
                        text: "\(wanState.connectedPeers.count) WAN peers",
                        color: .blue
                    )
                    InfoPill(
                        icon: "bolt.horizontal",
                        text: wanState.natType.rawValue
                    )
                }
            } else {
                HStack {
                    ProgressView()
                        .controlSize(.small)
                    Text("Connecting to WAN network...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

// MARK: - Credit Balance

private struct CreditBalanceSection: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Credits")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Wallet") {
                    appState.currentView = .wallet
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
            }

            HStack(spacing: 12) {
                InfoPill(
                    icon: "creditcard",
                    text: String(format: "%.1f credits", appState.wallet.balance.value),
                    color: appState.wallet.balance.value > 10 ? .green : .orange
                )
                InfoPill(
                    icon: "arrow.down.circle",
                    text: String(format: "+%.1f earned", appState.wallet.totalEarned.value),
                    color: .green
                )
            }
        }
    }
}
