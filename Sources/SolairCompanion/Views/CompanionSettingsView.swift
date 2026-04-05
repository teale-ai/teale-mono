import SwiftUI

struct CompanionSettingsView: View {
    var appState: CompanionAppState
    @State private var showResetConfirmation = false

    var body: some View {
        NavigationStack {
            Form {
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
                        TextField("https://relay.solair.network", text: Binding(
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
                    LabeledContent("App", value: "Solair Companion")
                    LabeledContent("Version", value: "1.0.0")
                    LabeledContent("Platform", value: "iOS")
                    HStack {
                        Text("Project")
                        Spacer()
                        Link("github.com/solair", destination: URL(string: "https://github.com/solair")!)
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
