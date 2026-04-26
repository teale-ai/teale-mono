import SwiftUI
import SharedTypes
import AuthKit
import ChatKit

enum CompanionTab: Hashable {
    case teale
    case chats
    case wallet
    case me
    case signIn
}

@main
struct TealeCompanionApp: App {
    @State private var appState = CompanionAppState()
    @State private var selectedTab: CompanionTab = .teale

    var body: some Scene {
        WindowGroup {
            rootTabs
                .task { await appState.initialize() }
                .onOpenURL { url in handleIncomingURL(url) }
        }
    }

    // Always present the Teale Network tab so the gateway-backed group chat
    // works out of the box with nothing beyond the ed25519 device identity.
    // The legacy Supabase-gated ChatKit tabs only show once the user has
    // signed in (or chosen anonymous mode), matching the prior behavior.
    @ViewBuilder
    private var rootTabs: some View {
        TabView(selection: $selectedTab) {
            #if os(iOS)
            TealeNetworkTabView()
                .tabItem {
                    Label("Teale", systemImage: "brain.head.profile")
                }
                .tag(CompanionTab.teale)
            #endif

            if let authManager = appState.authManager, authManager.authState.canUseApp {
                ConversationListView(appState: appState)
                    .tabItem {
                        Label("Chats", systemImage: "bubble.left.and.bubble.right.fill")
                    }
                    .tag(CompanionTab.chats)

                CompanionWalletView(appState: appState)
                    .tabItem {
                        Label("Wallet", systemImage: "creditcard.fill")
                    }
                    .tag(CompanionTab.wallet)

                MeTab(appState: appState, selectedTab: $selectedTab)
                    .tabItem {
                        Label("Me", systemImage: "person.crop.circle.fill")
                    }
                    .tag(CompanionTab.me)
            } else if let authManager = appState.authManager {
                // Existing Supabase login still available as a tab rather
                // than a gate, so the main Teale features are always usable.
                LoginView(authManager: authManager)
                    .tabItem {
                        Label("Sign in", systemImage: "person.crop.circle")
                    }
                    .tag(CompanionTab.signIn)
            }
        }
        .tint(Color.teale)
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
    @Binding var selectedTab: CompanionTab

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
                        CompanionSettingsView(appState: appState, selectedTab: $selectedTab)
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
