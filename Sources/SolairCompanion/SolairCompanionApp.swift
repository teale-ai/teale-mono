import SwiftUI
import SharedTypes

@main
struct SolairCompanionApp: App {
    @State private var appState = CompanionAppState()

    var body: some Scene {
        WindowGroup {
            TabView {
                CompanionChatView(appState: appState)
                    .tabItem {
                        Label("Chat", systemImage: "bubble.left.and.bubble.right")
                    }

                NetworkView(appState: appState)
                    .tabItem {
                        Label("Network", systemImage: "network")
                    }

                CompanionWalletView(appState: appState)
                    .tabItem {
                        Label("Wallet", systemImage: "creditcard")
                    }

                CompanionSettingsView(appState: appState)
                    .tabItem {
                        Label("Settings", systemImage: "gear")
                    }
            }
            .task {
                await appState.startDiscovery()
            }
        }
    }
}
