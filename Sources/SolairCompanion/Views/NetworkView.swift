import SwiftUI
import SharedTypes

struct NetworkView: View {
    var appState: CompanionAppState
    @State private var isRefreshing = false

    var body: some View {
        NavigationStack {
            List {
                // Discovery status
                Section {
                    HStack {
                        Image(systemName: "antenna.radiowaves.left.and.right")
                            .foregroundStyle(.blue)
                        Text("Scanning for Teale nodes...")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Spacer()
                        ProgressView()
                            .controlSize(.small)
                    }
                }

                // LAN Nodes
                Section("Local Network") {
                    let lanNodes = appState.discoveredNodes.filter(\.isLAN)
                    if lanNodes.isEmpty {
                        HStack {
                            Image(systemName: "wifi.slash")
                                .foregroundStyle(.tertiary)
                            Text("No Mac nodes found on local network")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 4)
                    } else {
                        ForEach(lanNodes) { node in
                            NodeCardView(node: node, appState: appState)
                        }
                    }
                }

                // WAN Nodes
                Section("Wide Area Network") {
                    let wanNodes = appState.discoveredNodes.filter { !$0.isLAN }
                    if wanNodes.isEmpty {
                        HStack {
                            Image(systemName: "globe")
                                .foregroundStyle(.tertiary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("No WAN nodes")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                Text("Configure a relay server in Settings")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .padding(.vertical, 4)
                    } else {
                        ForEach(wanNodes) { node in
                            NodeCardView(node: node, appState: appState)
                        }
                    }
                }

                // Connected Node Info
                if let connected = appState.connectedNode {
                    Section("Active Connection") {
                        LabeledContent("Node", value: connected.name)
                        LabeledContent("Host", value: connected.host)
                        LabeledContent("Port", value: "\(connected.port)")
                        if let chip = connected.chipName {
                            LabeledContent("Chip", value: chip)
                        }
                        if let ram = connected.totalRAMGB {
                            LabeledContent("RAM", value: "\(Int(ram)) GB")
                        }
                        if let model = connected.loadedModel {
                            LabeledContent("Model", value: model)
                        }

                        Button(role: .destructive) {
                            appState.disconnect()
                        } label: {
                            Label("Disconnect", systemImage: "xmark.circle")
                        }
                    }
                }
            }
            .navigationTitle("Network")
            .refreshable {
                await appState.refreshModels()
            }
        }
    }
}

// MARK: - Node Card

private struct NodeCardView: View {
    let node: DiscoveredNode
    var appState: CompanionAppState

    private var isConnectedToThis: Bool {
        appState.connectedNode?.id == node.id
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "desktopcomputer")
                    .font(.title3)
                    .foregroundStyle(.blue)

                VStack(alignment: .leading, spacing: 2) {
                    Text(node.name)
                        .font(.headline)

                    HStack(spacing: 8) {
                        if let chip = node.chipName {
                            Text(chip)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        if let ram = node.totalRAMGB {
                            Text("\(Int(ram)) GB")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Spacer()

                if isConnectedToThis {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else {
                    connectionQualityBadge
                }
            }

            if let model = node.loadedModel {
                HStack {
                    Image(systemName: "cpu")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(model)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if !isConnectedToThis {
                Button {
                    Task {
                        await appState.connect(to: node)
                    }
                } label: {
                    Text("Connect")
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        }
        .padding(.vertical, 4)
    }

    private var connectionQualityBadge: some View {
        Group {
            if let quality = node.connectionQuality {
                Text(quality.rawValue)
                    .font(.caption2)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(.blue.opacity(0.1))
                    .clipShape(Capsule())
            }
        }
    }
}
