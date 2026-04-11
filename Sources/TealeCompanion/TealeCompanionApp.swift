import SwiftUI
import SharedTypes
import AuthKit
import ChatKit

@main
struct TealeCompanionApp: App {
    @State private var appState = CompanionAppState()

    var body: some Scene {
        WindowGroup {
            Group {
                if let authManager = appState.authManager, authManager.authState.canUseApp {
                    TabView {
                        ConversationListView(appState: appState)
                            .tabItem {
                                Label("Chats", systemImage: "bubble.left.and.bubble.right.fill")
                            }

                        NavigationStack {
                            LocalModelsView()
                        }
                        .environment(appState)
                        .tabItem {
                            Label("Models", systemImage: "cpu")
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
                } else if let authManager = appState.authManager {
                    LoginView(authManager: authManager)
                } else {
                    ProgressView("Loading...")
                }
            }
            .task {
                await appState.initialize()
            }
            .onOpenURL { url in
                // Handle invite deep links
                if url.scheme == "teale", url.host == "invite",
                   let code = url.pathComponents.last {
                    Task {
                        if let conversationID = try? await appState.chatService?.invitationService.redeemInvitation(code: code) {
                            await appState.chatService?.loadConversations()
                        }
                    }
                }

                // Handle OAuth callbacks
                if let authManager = appState.authManager {
                    Task { await authManager.handleOAuthCallback(url: url) }
                }
            }
        }
    }
}
