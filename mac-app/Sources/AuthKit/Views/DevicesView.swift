import SwiftUI
import SharedTypes

// MARK: - Devices View

public struct DevicesView: View {
    var authManager: AuthManager
    @State private var showTransferSheet = false
    @State private var selectedDeviceForTransfer: DeviceRecord?
    @State private var showRemoveConfirmation = false
    @State private var selectedDeviceForRemoval: DeviceRecord?

    public init(authManager: AuthManager) {
        self.authManager = authManager
    }

    public var body: some View {
        #if os(iOS)
        NavigationStack {
            deviceList
                .navigationTitle("Devices")
                .refreshable {
                    await authManager.fetchDevices()
                }
        }
        #else
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("Devices")
                        .font(.headline)
                    Spacer()
                    Button {
                        Task { await authManager.fetchDevices() }
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                            .font(.subheadline)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }

                deviceContent
            }
            .padding()
        }
        #endif
    }

    // MARK: - List (iOS)

    private var deviceList: some View {
        List {
            deviceContent
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var deviceContent: some View {
        // This device
        if let current = authManager.devices.first(where: { $0.id == authManager.currentDeviceID }) {
            Section("This Device") {
                DeviceCardView(
                    device: current,
                    isCurrent: true,
                    onRemove: nil,
                    onTransfer: nil
                )
            }
        }

        // Other devices
        let otherDevices = authManager.devices.filter { $0.id != authManager.currentDeviceID }
        Section("Other Devices") {
            if otherDevices.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "laptopcomputer.and.iphone")
                        .font(.title2)
                        .foregroundStyle(.tertiary)
                    Text("No other devices")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text("Sign in on another device to see it here")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
            } else {
                ForEach(otherDevices) { device in
                    DeviceCardView(
                        device: device,
                        isCurrent: false,
                        onRemove: {
                            selectedDeviceForRemoval = device
                            showRemoveConfirmation = true
                        },
                        onTransfer: {
                            selectedDeviceForTransfer = device
                            showTransferSheet = true
                        }
                    )
                }
            }
        }

        // Account info
        if let user = authManager.currentUser {
            Section("Account") {
                if let phone = user.phone {
                    LabeledContent("Phone", value: phone)
                }
                if let email = user.email {
                    LabeledContent("Email", value: email)
                }
                LabeledContent("Devices", value: "\(authManager.devices.count)")
            }
        }
    }
}

// MARK: - Device Card

private struct DeviceCardView: View {
    let device: DeviceRecord
    let isCurrent: Bool
    let onRemove: (() -> Void)?
    let onTransfer: (() -> Void)?

    @State private var showRemoveConfirmation = false
    @State private var showTransferSheet = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: device.platform == .macos ? "desktopcomputer" : "iphone")
                    .font(.title3)
                    .foregroundStyle(.blue)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(device.deviceName)
                            .font(.headline)
                        if isCurrent {
                            Text("This device")
                                .font(.caption2)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(.blue.opacity(0.1))
                                .clipShape(Capsule())
                        }
                    }

                    HStack(spacing: 8) {
                        if let chip = device.chipName {
                            Text(chip)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        if let ram = device.ramGB {
                            Text("\(ram) GB")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Text(device.platform.rawValue.uppercased())
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                // Status indicator
                statusDot
            }

            // Last seen
            if !isCurrent {
                HStack {
                    Image(systemName: "clock")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("Last seen ")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    + Text(device.lastSeen, style: .relative)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    + Text(" ago")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            // Actions for non-current devices
            if !isCurrent {
                HStack(spacing: 8) {
                    Button {
                        onTransfer?()
                    } label: {
                        Label("Transfer", systemImage: "arrow.right.circle")
                            .font(.subheadline)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Button(role: .destructive) {
                        onRemove?()
                    } label: {
                        Label("Remove", systemImage: "xmark.circle")
                            .font(.subheadline)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
        }
        .padding(.vertical, 4)
        .confirmationDialog(
            "Remove \(device.deviceName)?",
            isPresented: $showRemoveConfirmation,
            titleVisibility: .visible
        ) {
            Button("Remove", role: .destructive) {
                onRemove?()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This device will be unlinked from your account. It can still be used anonymously.")
        }
    }

    private var statusDot: some View {
        let isRecent = Date().timeIntervalSince(device.lastSeen) < 600 // 10 minutes
        return Circle()
            .fill(isCurrent ? .green : (isRecent ? .green : .orange))
            .frame(width: 8, height: 8)
    }
}
