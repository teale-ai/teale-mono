import SwiftUI
import SharedTypes
import HardwareProfile
import InferenceEngine
import ModelManager
import LocalAPI
import ClusterKit
import WANKit
import CreditKit
import AgentKit

// MARK: - Main App Entry

@main
struct InferencePoolApp: App {
    @State private var appState = AppState()

    var body: some Scene {
        MenuBarExtra {
            ContentView()
                .environment(appState)
                .frame(width: 480, height: 600)
        } label: {
            Label("Inference Pool", systemImage: "brain.head.profile")
        }
        .menuBarExtraStyle(.window)
    }
}

// MARK: - Content View (root navigation)

struct ContentView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        NavigationSplitView {
            SidebarView()
        } detail: {
            switch appState.currentView {
            case .dashboard:
                DashboardView()
            case .chat:
                ChatView()
            case .models:
                ModelBrowserView()
            case .cluster:
                ClusterView()
            case .wan:
                WANView()
            case .wallet:
                WalletView()
            case .agents:
                AgentView()
            case .settings:
                SettingsView()
            }
        }
        .task {
            await appState.initializeAsync()
            await appState.startServer()
        }
    }
}

// MARK: - Sidebar

struct SidebarView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var state = appState

        List(selection: Binding(get: { appState.currentView }, set: { appState.currentView = $0 })) {
            Label("Dashboard", systemImage: "gauge")
                .tag(AppView.dashboard)
            Label("Chat", systemImage: "bubble.left.and.bubble.right")
                .tag(AppView.chat)
            Label("Models", systemImage: "square.stack.3d.up")
                .tag(AppView.models)
            Label("Cluster", systemImage: "desktopcomputer.and.arrow.down")
                .tag(AppView.cluster)
            Label("WAN", systemImage: "globe")
                .tag(AppView.wan)
            Label("Wallet", systemImage: "creditcard")
                .tag(AppView.wallet)
            Label("Agents", systemImage: "person.2.wave.2")
                .tag(AppView.agents)
            Label("Settings", systemImage: "gear")
                .tag(AppView.settings)
        }
        .listStyle(.sidebar)
        .frame(minWidth: 140)
    }
}
