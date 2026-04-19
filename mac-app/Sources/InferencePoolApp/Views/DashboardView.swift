import SwiftUI
import AppCore
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

                // Inference Stats
                InferenceStatsSection()

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
        .navigationTitle(appState.loc("dashboard.title"))
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
                Label("API: \(String(appState.serverPort))", systemImage: "network")
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
            Text(appState.loc("dashboard.hardware"))
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
                    text: thermalText,
                    color: thermalColor
                )
                InfoPill(
                    icon: appState.throttler.powerMonitor.powerState.isOnACPower ? "bolt.fill" : "battery.50",
                    text: powerText,
                    color: powerColor
                )
                InfoPill(
                    icon: "speedometer",
                    text: "\(appState.loc("dashboard.throttle")): \(appState.throttler.throttleLevel.rawValue)%"
                )
            }
        }
    }

    private var thermalText: String {
        switch appState.throttler.thermalMonitor.thermalLevel {
        case .nominal: return appState.loc("thermal.nominal")
        case .fair: return appState.loc("thermal.fair")
        case .serious: return appState.loc("thermal.serious")
        case .critical: return appState.loc("thermal.critical")
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
        if power.isOnACPower { return appState.loc("power.ac") }
        if let battery = power.batteryLevel {
            return "\(Int(battery * 100))% \(appState.loc("power.battery"))"
        }
        return appState.loc("power.battery")
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
            Text(appState.loc("dashboard.engine"))
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
                    Button(appState.loc("dashboard.unload")) {
                        Task { await appState.unloadModel() }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            } else {
                Text(appState.loc("dashboard.noModelLoaded"))
                    .foregroundStyle(.secondary)
                Button(appState.loc("dashboard.browseModels")) {
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
            Text(appState.loc("dashboard.quickActions"))
                .font(.subheadline)
                .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                Button {
                    appState.currentView = .chat
                } label: {
                    Label(appState.loc("dashboard.newChat"), systemImage: "plus.bubble")
                }
                .buttonStyle(.bordered)

                Button {
                    if let port = Optional(appState.serverPort) {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString("http://localhost:\(port)/v1", forType: .string)
                    }
                } label: {
                    Label(appState.loc("dashboard.copyAPIURL"), systemImage: "doc.on.doc")
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
                Text(appState.loc("dashboard.cluster"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(appState.loc("dashboard.view")) {
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
                        text: String(format: appState.loc("dashboard.devices"), state.connectedPeerCount + 1),
                        color: .green
                    )
                    InfoPill(
                        icon: "memorychip",
                        text: String(format: appState.loc("dashboard.total"), Int(state.totalClusterRAMGB + appState.hardware.totalRAMGB))
                    )
                }
            } else {
                HStack {
                    ProgressView()
                        .controlSize(.small)
                    Text(appState.loc("dashboard.searchingPeers"))
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
                Text(appState.loc("dashboard.wan"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(appState.loc("dashboard.view")) {
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
                        text: String(format: appState.loc("dashboard.wanPeers"), wanState.connectedPeers.count),
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
                    Text(appState.loc("dashboard.connectingWAN"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

// MARK: - Inference Stats

private struct InferenceStatsSection: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Inference Stats")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                InfoPill(
                    icon: "arrow.up.arrow.down",
                    text: "\(appState.totalRequestsServed) requests served",
                    color: appState.totalRequestsServed > 0 ? .blue : .secondary
                )
                InfoPill(
                    icon: "text.word.spacing",
                    text: formatTokens(appState.totalTokensGenerated) + " tokens",
                    color: appState.totalTokensGenerated > 0 ? .blue : .secondary
                )
            }
        }
    }

    private func formatTokens(_ count: Int) -> String {
        if count >= 1_000_000 { return String(format: "%.1fM", Double(count) / 1_000_000) }
        if count >= 1_000 { return String(format: "%.1fK", Double(count) / 1_000) }
        return "\(count)"
    }
}

// MARK: - Credit Balance

private struct CreditBalanceSection: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(appState.loc("dashboard.credits"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(appState.loc("sidebar.wallet")) {
                    appState.currentView = .wallet
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
            }

            HStack(spacing: 12) {
                InfoPill(
                    icon: "dollarsign.circle",
                    text: appState.wallet.balance.description + " USDC",
                    color: appState.wallet.balance.value > 0.001 ? .green : .orange
                )
                InfoPill(
                    icon: "arrow.down.circle",
                    text: "+" + appState.wallet.totalEarned.description + " earned",
                    color: .green
                )
            }
        }
    }
}
