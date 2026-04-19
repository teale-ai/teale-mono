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

                        CompanionWalletView(appState: appState)
                            .tabItem {
                                Label("Wallet", systemImage: "creditcard.fill")
                            }

                        MeTab(appState: appState)
                            .tabItem {
                                Label("Me", systemImage: "person.crop.circle.fill")
                            }
                    }
                    .tint(Color.teale)
                } else if let authManager = appState.authManager {
                    LoginView(authManager: authManager)
                } else {
                    ProgressView("Loading…")
                }
            }
            .task {
                await appState.initialize()
            }
            .onOpenURL { url in
                handleIncomingURL(url)
            }
        }
    }

    // MARK: - Deep link handling

    private func handleIncomingURL(_ url: URL) {
        let invitationService = InvitationService(currentUserID: appState.currentUserID)
        if let token = invitationService.parseDeepLink(url), !token.isExpired {
            Task { @MainActor in
                if !appState.chatService.conversations.contains(where: { $0.id == token.groupID }) {
                    _ = await appState.chatService.createGroup(
                        title: token.groupTitle,
                        memberIDs: [],
                        agentConfig: AgentConfig(autoRespond: false, mentionOnly: true, persona: "assistant")
                    )
                    await appState.chatService.loadConversations()
                }
            }
            return
        }
        if let authManager = appState.authManager {
            Task { await authManager.handleOAuthCallback(url: url) }
        }
    }
}

// MARK: - Me tab (Models + Network + Settings consolidated)

private struct MeTab: View {
    var appState: CompanionAppState

    var body: some View {
        NavigationStack {
            List {
                Section("AI") {
                    NavigationLink {
                        LocalModelsView().environment(appState)
                    } label: {
                        Label("Models", systemImage: "cpu")
                    }
                    NavigationLink {
                        NetworkView(appState: appState)
                    } label: {
                        Label("Network", systemImage: "network")
                    }
                }
                Section("Settings") {
                    NavigationLink {
                        CompanionSettingsView(appState: appState)
                    } label: {
                        Label("Preferences", systemImage: "gear")
                    }
                }
            }
            .navigationTitle("Me")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.large)
            #endif
        }
    }
}
