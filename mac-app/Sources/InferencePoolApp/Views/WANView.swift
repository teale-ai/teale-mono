import SwiftUI
import AppCore
import SharedTypes
import WANKit

struct WANView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var state = appState

        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Header with toggle
                HStack {
                    Text("WAN P2P Network")
                        .font(.headline)
                    Spacer()
                    Toggle("", isOn: $state.wanEnabled)
                        .toggleStyle(.switch)
                        .labelsHidden()
                }

                if appState.wanEnabled {
                    // WAN Status
                    WANStatusSection()

                    Divider()

                    // All WAN Peers (connected + discovered, auto-connected)
                    WANPeersSection()
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: "globe")
                            .font(.system(size: 40))
                            .foregroundStyle(.secondary)
                        Text("Enable WAN to connect with peers over the internet")
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.secondary)
                        Text("Uses QUIC protocol with NAT traversal for direct P2P connections")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .multilineTextAlignment(.center)

                        if let wanLastError = appState.wanLastError {
                            Label(wanLastError, systemImage: "exclamationmark.triangle.fill")
                                .font(.caption)
                                .foregroundStyle(.red)
                                .multilineTextAlignment(.center)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
                }
            }
            .padding()
        }
        .navigationTitle("WAN Network")
    }
}

// MARK: - WAN Status

private struct WANStatusSection: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        let wanState = appState.wanManager.state

        VStack(alignment: .leading, spacing: 8) {
            Text("Status")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            HStack(spacing: 16) {
                WANStatPill(
                    icon: "antenna.radiowaves.left.and.right",
                    value: wanState.relayStatus.displayName,
                    color: wanState.relayStatus == .connected ? .green : .orange
                )
                WANStatPill(
                    icon: "network",
                    value: wanState.natType.displayName,
                    color: wanState.natType.canHolePunch ? .green : .yellow
                )
                WANStatPill(
                    icon: "desktopcomputer",
                    value: "\(wanState.connectedPeers.count) device\(wanState.connectedPeers.count == 1 ? "" : "s")",
                    color: wanState.connectedPeers.isEmpty ? .secondary : .green
                )
            }

            if let endpoint = wanState.publicEndpoint {
                HStack(spacing: 4) {
                    Image(systemName: "mappin.circle")
                        .foregroundStyle(.secondary)
                    Text("Public: \(endpoint.publicIP):\(String(endpoint.publicPort))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 4) {
                Image(systemName: "binoculars")
                    .foregroundStyle(.secondary)
                Text("\(wanState.discoveredPeerCount) devices on network")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer()

                Button {
                    Task {
                        try? await appState.wanManager.refreshDiscovery()
                    }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
            }

            // Connection diagnostics (collapsible)
            if !wanState.diagnostics.isEmpty {
                DisclosureGroup("Connection Log") {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(wanState.diagnostics, id: \.self) { line in
                            Text(line)
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(line.contains("FAILED") ? .red : .secondary)
                        }
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Model Availability

/// Groups WAN peers by loaded model to show aggregate availability
private struct WANModelAvailability: Identifiable {
    var id: String { modelID }
    let modelID: String
    let deviceCount: Int
    let totalRAMGB: Double
    let chipNames: [String: Int]  // chip name -> count
}

private func buildModelAvailability(from peers: [WANPeerSummary]) -> [WANModelAvailability] {
    // Group by model
    var modelDevices: [String: [WANPeerSummary]] = [:]
    for peer in peers {
        for model in peer.loadedModels {
            modelDevices[model, default: []].append(peer)
        }
    }

    return modelDevices.map { modelID, devices in
        var chipCounts: [String: Int] = [:]
        for device in devices {
            chipCounts[device.hardware.chipName, default: 0] += 1
        }
        return WANModelAvailability(
            modelID: modelID,
            deviceCount: devices.count,
            totalRAMGB: devices.reduce(0) { $0 + $1.hardware.totalRAMGB },
            chipNames: chipCounts
        )
    }
    .sorted { $0.deviceCount > $1.deviceCount }
}

private struct WANPeersSection: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        let wanState = appState.wanManager.state
        let connectedPeers = wanState.connectedPeers
        let models = buildModelAvailability(from: connectedPeers)
        // Peers with no loaded models
        let idlePeerCount = connectedPeers.filter { $0.loadedModels.isEmpty }.count

        VStack(alignment: .leading, spacing: 8) {
            Text("Available Models")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            if models.isEmpty && connectedPeers.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "globe")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                    Text("No WAN models available yet")
                        .foregroundStyle(.secondary)
                    Text("Models will appear as devices join the network")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
            } else {
                ForEach(models) { model in
                    WANModelCard(model: model)
                }

                if idlePeerCount > 0 {
                    HStack(spacing: 6) {
                        Image(systemName: "desktopcomputer")
                            .foregroundStyle(.secondary)
                        Text("\(idlePeerCount) device\(idlePeerCount == 1 ? "" : "s") connected, no models loaded")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 4)
                }
            }
        }
    }
}

// MARK: - Model Card

private struct WANModelCard: View {
    let model: WANModelAvailability

    private var shortModelName: String {
        cleanModelDisplayName(model.modelID)
    }

    private var hardwareSummary: String {
        model.chipNames
            .sorted { $0.value > $1.value }
            .map { name, count in count > 1 ? "\(count)x \(name)" : name }
            .joined(separator: ", ")
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "cube.fill")
                .font(.title2)
                .foregroundStyle(.blue)

            VStack(alignment: .leading, spacing: 2) {
                Text(shortModelName)
                    .font(.body.bold())

                HStack(spacing: 8) {
                    Label("\(model.deviceCount)", systemImage: "desktopcomputer")
                    Text("\(Int(model.totalRAMGB)) GB total")
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                Text(hardwareSummary)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
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

// MARK: - Stat Pill

private struct WANStatPill: View {
    let icon: String
    let value: String
    var color: Color = .secondary

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .foregroundStyle(color)
            Text(value)
        }
        .font(.caption)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.quaternary)
        .clipShape(Capsule())
    }
}

// MARK: - Helper Extensions

extension RelayStatus {
    var displayName: String {
        switch self {
        case .connected: return "Relay Connected"
        case .connecting: return "Connecting..."
        case .disconnected: return "Disconnected"
        case .reconnecting: return "Reconnecting..."
        }
    }
}

extension NATType {
    var displayName: String {
        switch self {
        case .fullCone: return "Full Cone NAT"
        case .restrictedCone: return "Restricted Cone"
        case .portRestricted: return "Port Restricted"
        case .symmetric: return "Symmetric NAT"
        case .unknown: return "Detecting..."
        }
    }
}
