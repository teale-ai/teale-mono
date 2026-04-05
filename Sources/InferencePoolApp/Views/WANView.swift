import SwiftUI
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

                    // Connected WAN Peers
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
                    icon: "person.2",
                    value: "\(wanState.connectedPeers.count) connected",
                    color: wanState.connectedPeers.isEmpty ? .secondary : .green
                )
            }

            if let endpoint = wanState.publicEndpoint {
                HStack(spacing: 4) {
                    Image(systemName: "mappin.circle")
                        .foregroundStyle(.secondary)
                    Text("Public: \(endpoint.publicIP):\(endpoint.publicPort)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 4) {
                Image(systemName: "binoculars")
                    .foregroundStyle(.secondary)
                Text("\(wanState.discoveredPeerCount) peers discovered on network")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - WAN Peers

private struct WANPeersSection: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        let peers = appState.wanManager.state.connectedPeers

        VStack(alignment: .leading, spacing: 8) {
            Text("Connected Peers")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            if peers.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                    Text("No WAN peers connected yet")
                        .foregroundStyle(.secondary)
                    Text("Peers will appear as they join the network")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
            } else {
                ForEach(peers) { peer in
                    WANPeerCard(peer: peer)
                }
            }
        }
    }
}

// MARK: - WAN Peer Card

private struct WANPeerCard: View {
    let peer: WANPeerSummary

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "globe")
                .font(.title2)
                .foregroundStyle(.blue)

            VStack(alignment: .leading, spacing: 2) {
                Text(peer.displayName)
                    .font(.body.bold())

                HStack(spacing: 8) {
                    Text(peer.hardware.chipName)
                    Text("\(Int(peer.hardware.totalRAMGB)) GB")
                    Text(peer.connectionType == .direct ? "Direct" : "Relayed")
                        .foregroundStyle(peer.connectionType == .direct ? .green : .orange)
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                if !peer.loadedModels.isEmpty {
                    Text("Models: \(peer.loadedModels.joined(separator: ", "))")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 4) {
                Circle()
                    .fill(.green)
                    .frame(width: 8, height: 8)
                if let latency = peer.latencyMs {
                    Text("\(Int(latency))ms")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
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
