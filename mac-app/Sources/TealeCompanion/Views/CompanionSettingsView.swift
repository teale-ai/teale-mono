import SwiftUI
import SharedTypes
import AuthKit
#if os(iOS)
import UIKit
#else
import AppKit
#endif

struct CompanionSettingsView: View {
    var appState: CompanionAppState
    @Binding var selectedTab: CompanionTab
    @State private var showResetConfirmation = false

    var body: some View {
        NavigationStack {
            Form {
                // Account
                Section("Account") {
                    if let authManager = appState.authManager,
                       case .signedIn(let user) = authManager.authState {
                        if let phone = user.phone {
                            LabeledContent("Phone", value: phone)
                        }
                        if let email = user.email {
                            LabeledContent("Email", value: email)
                        }
                        Button("Sign Out") {
                            Task { await authManager.signOut() }
                        }
                    } else {
                        HStack {
                            Image(systemName: "person.crop.circle.badge.questionmark")
                                .foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Not signed in")
                                    .font(.subheadline)
                                Text("Sign in to sync across devices")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                Section("Account Devices") {
                    if let authManager = appState.authManager,
                       authManager.authState.isAuthenticated {
                        if appState.gatewayAccount.isLoading && appState.gatewayAccount.summary == nil {
                            HStack(spacing: 8) {
                                ProgressView()
                                    .controlSize(.small)
                                Text("Loading Teale device wallets...")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                        } else if let error = appState.gatewayAccount.errorMessage,
                                  appState.gatewayAccount.summary == nil {
                            Label(error, systemImage: "exclamationmark.triangle.fill")
                                .font(.caption)
                                .foregroundStyle(.red)
                        } else if let devices = appState.gatewayAccount.summary?.devices,
                                  !devices.isEmpty {
                            ForEach(devices) { device in
                                SettingsGatewayDeviceRow(
                                    device: device,
                                    localDeviceID: appState.gatewayAccount.localDeviceID,
                                    onUseInWallet: { deviceID in
                                        appState.gatewayAccount.stageWalletRecipient(deviceID)
                                        selectedTab = .wallet
                                    }
                                )
                            }
                        } else {
                            Text("No Teale device wallets linked to this account yet.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        Text("Sign in to load Teale device wallets for this account.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                // Connection preferences
                Section("Connection") {
                    HStack {
                        Text("Preferred Node")
                        Spacer()
                        Picker("", selection: Binding(
                            get: { appState.preferredNode ?? "__auto__" },
                            set: { appState.preferredNode = $0 == "__auto__" ? nil : $0 }
                        )) {
                            Text("Auto").tag("__auto__")
                            ForEach(appState.discoveredNodes) { node in
                                Text(node.name).tag(node.id)
                            }
                        }
                        .labelsHidden()
                    }
                }

                // WAN P2P
                Section("WAN Network") {
                    Toggle("Enable WAN", isOn: Binding(
                        get: { appState.wanEnabled },
                        set: { appState.wanEnabled = $0 }
                    ))

                    if appState.isWANBusy {
                        HStack {
                            ProgressView()
                                .controlSize(.small)
                            Text("Connecting...")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    if let error = appState.wanLastError {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }

                    HStack {
                        Text("Relay Server")
                        Spacer()
                        TextField("wss://relay.teale.com/ws", text: Binding(
                            get: { appState.wanRelayURL },
                            set: { appState.wanRelayURL = $0 }
                        ))
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 200)
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                        .autocorrectionDisabled()
                    }

                    if appState.wanEnabled {
                        let wanState = appState.wanManager.state
                        LabeledContent("Relay") {
                            Text(wanState.relayStatus == .connected ? "Connected" : wanState.relayStatus.rawValue)
                                .foregroundStyle(wanState.relayStatus == .connected ? .green : .orange)
                        }
                        LabeledContent("Peers", value: "\(wanState.connectedPeers.count) connected")
                    }
                }

                // Identity
                Section("Identity") {
                    HStack {
                        Text("Display Name")
                        Spacer()
                        TextField("My iPhone", text: Binding(
                            get: { appState.displayName },
                            set: { appState.displayName = $0 }
                        ))
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 200)
                        .multilineTextAlignment(.trailing)
                    }
                }

                // Status
                Section("Status") {
                    LabeledContent("Connection") {
                        Text(appState.connectionStatus.displayText)
                            .foregroundStyle(appState.connectionStatus.isConnected ? .green : .secondary)
                    }
                    LabeledContent("Available Models", value: "\(appState.availableModels.count)")
                    LabeledContent("Conversations", value: "\(appState.chatService.conversations.count)")
                }

                // About
                Section("About") {
                    LabeledContent("App", value: "Teale Companion")
                    LabeledContent("Version", value: BuildVersion.display)
                    LabeledContent("Platform", value: "iOS")
                    HStack {
                        Text("Project")
                        Spacer()
                        Link("github.com/taylorhou/teale", destination: URL(string: "https://github.com/taylorhou/teale")!)
                            .font(.subheadline)
                    }
                }

                // Danger zone
                Section {
                    Button(role: .destructive) {
                        showResetConfirmation = true
                    } label: {
                        Label("Reset All Data", systemImage: "trash")
                    }
                }
            }
            .navigationTitle("Settings")
            .confirmationDialog(
                "Reset all data?",
                isPresented: $showResetConfirmation,
                titleVisibility: .visible
            ) {
                Button("Reset", role: .destructive) {
                    Task {
                        for convo in appState.chatService.conversations {
                            await appState.chatService.leaveConversation(convo.id)
                        }
                    }
                    appState.disconnect()
                    appState.walletBalance = 0
                    appState.transactions = []
                    appState.displayName = "My iPhone"
                    appState.preferredNode = nil
                    appState.wanRelayURL = ""
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This will clear all conversations, wallet data, and settings. This cannot be undone.")
            }
        }
        .onAppear {
            Task {
                await appState.gatewayAccount.refreshIfNeeded(
                    authManager: appState.authManager,
                    deviceName: appState.displayName,
                    force: false
                )
            }
        }
    }
}

private struct SettingsGatewayDeviceRow: View {
    let device: CompanionGatewayAccountDevice
    let localDeviceID: String
    let onUseInWallet: (String) -> Void

    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(device.deviceName ?? shortDeviceID(device.deviceID))
                        .font(.subheadline.weight(.semibold))
                    Text(platformLine)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(formatCredits(device.walletBalanceCredits))
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Color.teale)
                    .monospacedDigit()
            }

            Button {
                copyText(device.deviceID)
                copied = true
                Task {
                    try? await Task.sleep(nanoseconds: 1_200_000_000)
                    copied = false
                }
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(shortDeviceID(device.deviceID))
                        .font(.system(.body, design: .monospaced).weight(.semibold))
                    Text(copied ? "Device ID copied." : "Tap to copy the full Teale device ID.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)

            Button("Send Credits") {
                onUseInWallet(device.deviceID)
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(.vertical, 4)
    }

    private var platformLine: String {
        let platform = device.platform ?? "device"
        if device.deviceID == localDeviceID {
            return "\(platform) · this device"
        }
        return platform
    }

    private func shortDeviceID(_ value: String) -> String {
        guard value.count > 16 else { return value }
        return "\(value.prefix(8))...\(value.suffix(8))"
    }

    private func formatCredits(_ credits: Int64) -> String {
        "\(credits.formatted()) credits"
    }

    private func copyText(_ value: String) {
        #if os(iOS)
        UIPasteboard.general.string = value
        #else
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
        #endif
    }
}
