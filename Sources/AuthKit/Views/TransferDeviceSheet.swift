import SwiftUI
import SharedTypes

// MARK: - Transfer Device Sheet

public struct TransferDeviceSheet: View {
    var authManager: AuthManager
    let device: DeviceRecord
    let onDismiss: () -> Void

    @State private var recipientPhone = ""
    @State private var lookupResult: UserProfile?
    @State private var isLookingUp = false
    @State private var isTransferring = false
    @State private var errorMessage: String?
    @State private var showConfirmation = false

    public init(authManager: AuthManager, device: DeviceRecord, onDismiss: @escaping () -> Void) {
        self.authManager = authManager
        self.device = device
        self.onDismiss = onDismiss
    }

    public var body: some View {
        NavigationStack {
            Form {
                // Device being transferred
                Section("Device") {
                    HStack {
                        Image(systemName: device.platform == .macos ? "desktopcomputer" : "iphone")
                            .foregroundStyle(.blue)
                        VStack(alignment: .leading) {
                            Text(device.deviceName)
                                .font(.headline)
                            if let chip = device.chipName {
                                Text(chip)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                // Recipient
                Section("Transfer To") {
                    TextField("Recipient phone number (+1...)", text: $recipientPhone)
                        #if os(iOS)
                        .keyboardType(.phonePad)
                        .textContentType(.telephoneNumber)
                        #endif

                    Button {
                        Task { await handleLookup() }
                    } label: {
                        HStack {
                            Text("Look Up")
                            if isLookingUp {
                                Spacer()
                                ProgressView()
                                    .controlSize(.small)
                            }
                        }
                    }
                    .disabled(recipientPhone.isEmpty || isLookingUp)

                    if let recipient = lookupResult {
                        HStack {
                            Image(systemName: "person.circle.fill")
                                .foregroundStyle(.green)
                            VStack(alignment: .leading) {
                                Text(recipient.displayName ?? "Teale User")
                                    .font(.subheadline)
                                    .fontWeight(.medium)
                                if let phone = recipient.phone {
                                    Text(phone)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }

                // Warning
                Section {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .font(.title3)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("What happens on transfer")
                                .font(.subheadline)
                                .fontWeight(.medium)
                            Text("Future credits earned on this device will go to the new owner. Your past credits stay with you. This action cannot be undone.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                }

                // Error
                if let error = errorMessage {
                    Section {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }

                // Transfer button
                Section {
                    Button(role: .destructive) {
                        showConfirmation = true
                    } label: {
                        HStack {
                            Spacer()
                            if isTransferring {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Label("Transfer Device", systemImage: "arrow.right.circle")
                            }
                            Spacer()
                        }
                    }
                    .disabled(lookupResult == nil || isTransferring)
                }
            }
            .navigationTitle("Transfer Device")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { onDismiss() }
                }
            }
            .confirmationDialog(
                "Transfer \(device.deviceName)?",
                isPresented: $showConfirmation,
                titleVisibility: .visible
            ) {
                Button("Transfer", role: .destructive) {
                    Task { await handleTransfer() }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                if let recipient = lookupResult {
                    Text("Transfer to \(recipient.displayName ?? "this user")? Future credit earnings on this device will go to them.")
                }
            }
        }
    }

    // MARK: - Actions

    @MainActor
    private func handleLookup() async {
        isLookingUp = true
        errorMessage = nil
        lookupResult = nil

        lookupResult = await authManager.lookupUser(phone: recipientPhone)
        if lookupResult == nil {
            errorMessage = "No user found with that phone number"
        }
        isLookingUp = false
    }

    @MainActor
    private func handleTransfer() async {
        isTransferring = true
        errorMessage = nil

        do {
            try await authManager.transferDevice(deviceID: device.id, toRecipientPhone: recipientPhone)
            onDismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
        isTransferring = false
    }
}
