import SwiftUI
import AppCore
import SharedTypes
import ClusterKit

struct ClusterView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var state = appState

        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Header with toggle
                HStack {
                    Text("LAN Cluster")
                        .font(.headline)
                    Spacer()
                    Toggle("", isOn: $state.clusterEnabled)
                        .toggleStyle(.switch)
                        .labelsHidden()
                }

                if appState.clusterEnabled {
                    // Cluster stats
                    ClusterStatsView()

                    Divider()

                    // This device
                    ThisDeviceCard()

                    DiscoveryControlsView()

                    if let connectionNotice = appState.clusterManager.connectionNotice {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.yellow)
                            Text(connectionNotice)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(12)
                        .background(.quaternary.opacity(0.6))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }

                    // Peer devices
                    if appState.clusterManager.peerSummaries.isEmpty {
                        VStack(spacing: 8) {
                            Image(systemName: appState.clusterManager.isScanning ? "magnifyingglass" : "desktopcomputer")
                                .font(.largeTitle)
                                .foregroundStyle(.secondary)
                            Text(appState.clusterManager.isScanning ? "Scanning your network..." : "No connected devices yet")
                                .foregroundStyle(.secondary)
                            Text(
                                appState.clusterManager.isScanning
                                ? "Looking for nearby Macs running Teale"
                                : "Teale is available on this Mac and waiting for nearby devices to connect"
                            )
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 24)
                    } else {
                        ForEach(appState.clusterManager.peerSummaries) { peer in
                            PeerCardView(peer: peer)
                        }
                    }
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: "desktopcomputer.and.arrow.down")
                            .font(.system(size: 40))
                            .foregroundStyle(.secondary)
                        Text("Enable LAN Cluster to connect your Macs into a unified inference network")
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.secondary)
                        Text("Devices on the same network can discover each other when Local Network access is allowed")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
                }
            }
            .padding()
        }
        .navigationTitle("Cluster")
        .onAppear {
            guard appState.clusterEnabled else { return }
            appState.clusterManager.scanForPeers()
        }
    }
}

private struct DiscoveryControlsView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        HStack(spacing: 12) {
            if appState.clusterManager.isScanning {
                ProgressView()
                    .controlSize(.small)
                Text("Scanning for devices...")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Stop") {
                    appState.clusterManager.stopScanning()
                }
                .buttonStyle(.bordered)
            } else {
                Text("Teale keeps scanning while LAN Cluster is enabled.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Scan Again") {
                    appState.clusterManager.scanForPeers()
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }
}

// MARK: - Cluster Stats

private struct ClusterStatsView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        let state = appState.clusterManager.clusterState

        HStack(spacing: 16) {
            StatPill(icon: "desktopcomputer", value: "\(state.connectedPeerCount + 1)", label: "Devices")
            StatPill(icon: "memorychip", value: "\(Int(state.totalClusterRAMGB + appState.hardware.totalRAMGB)) GB", label: "Total RAM")
            StatPill(icon: "bolt.horizontal", value: String(format: "%.0f GB/s", state.totalClusterBandwidthGBs + appState.hardware.memoryBandwidthGBs), label: "Bandwidth")
        }
    }
}

private struct StatPill: View {
    let icon: String
    let value: String
    let label: String

    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                Text(value)
                    .font(.headline)
            }
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.quaternary)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - This Device Card

private struct ThisDeviceCard: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "desktopcomputer")
                .font(.title2)
                .foregroundStyle(.blue)

            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(ProcessInfo.processInfo.hostName)
                        .font(.body.bold())
                    Text("(This Mac)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text("\(appState.hardware.chipName) \u{2022} \(Int(appState.hardware.totalRAMGB)) GB")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Build: \(Bundle.main.object(forInfoDictionaryKey: "TealeBuildDate") as? String ?? "dev")")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            Spacer()

            Circle()
                .fill(.green)
                .frame(width: 8, height: 8)
        }
        .padding(12)
        .background(.quaternary.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - Peer Card

struct PeerCardView: View {
    @Environment(AppState.self) private var appState
    let peer: PeerSummary

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: peerIcon)
                .font(.title2)
                .foregroundStyle(statusColor)

            VStack(alignment: .leading, spacing: 2) {
                Text(peer.name)
                    .font(.body.bold())

                HStack(spacing: 8) {
                    Text(peer.hardware.chipName)
                    Text("\(Int(peer.hardware.totalRAMGB)) GB")
                    if let quality = connectionIcon {
                        Image(systemName: quality)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                if let model = peer.loadedModel {
                    Text("Model: \(model)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 4) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
                Text(peer.status.rawValue.capitalized)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Button(appState.loc("wallet.sendCredits")) {
                    appState.pendingWalletTransferPeerID = peer.id
                    appState.currentView = .wallet
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var peerIcon: String {
        switch peer.hardware.tier {
        case .tier1: return "desktopcomputer"
        case .tier2: return "laptopcomputer"
        case .tier3: return "ipad"
        case .tier4: return "iphone"
        }
    }

    private var statusColor: Color {
        switch peer.status {
        case .connected: return .green
        case .degraded: return .yellow
        case .connecting, .discovered: return .orange
        case .disconnected: return .red
        }
    }

    private var connectionIcon: String? {
        switch peer.connectionQuality {
        case .thunderbolt: return "bolt.fill"
        case .tenGigabit, .gigabit: return "cable.connector"
        case .wifi: return "wifi"
        case .unknown: return nil
        }
    }
}
