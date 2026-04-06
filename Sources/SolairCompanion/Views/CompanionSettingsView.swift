import SwiftUI
import AuthKit

struct CompanionSettingsView: View {
    var appState: CompanionAppState
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

                    HStack {
                        Text("WAN Relay Server")
                        Spacer()
                        TextField("https://relay.teale.network", text: Binding(
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
                    LabeledContent("Conversations", value: "\(appState.conversationStore.conversations.count)")
                }

                // About
                Section("About") {
                    LabeledContent("App", value: "Teale Companion")
                    LabeledContent("Version", value: "1.0.0")
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
                    appState.conversationStore.clearAll()
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
    }
}
