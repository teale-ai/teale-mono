import SwiftUI
import ChatKit
import SharedTypes

// MARK: - Brand Color

extension Color {
    /// Teale brand color — not blue (iOS), not green (Android)
    static let teale = Color(red: 0.0, green: 0.6, blue: 0.6)
    static let tealeDark = Color(red: 0.0, green: 0.45, blue: 0.45)
    static let tealeLight = Color(red: 0.0, green: 0.6, blue: 0.6).opacity(0.15)
}

// MARK: - Conversation List View (WhatsApp-style)

struct ConversationListView: View {
    var appState: CompanionAppState
    @State private var showNewChat = false
    @State private var showNewGroup = false
    @State private var searchText = ""

    private var filteredConversations: [Conversation] {
        guard let chatService = appState.chatService else { return [] }
        let convos = chatService.conversations
        if searchText.isEmpty { return convos }
        return convos.filter {
            ($0.title ?? "").localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        NavigationStack {
            List {
                // Solo AI chat — always at top
                NavigationLink {
                    CompanionChatView(appState: appState)
                } label: {
                    soloAIChatRow
                }

                // Group chats / DMs
                if let chatService = appState.chatService {
                    if filteredConversations.isEmpty && !searchText.isEmpty {
                        Text("No conversations found")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .listRowSeparator(.hidden)
                    } else {
                        ForEach(filteredConversations) { conversation in
                            NavigationLink {
                                GroupChatView(appState: appState, conversation: conversation)
                            } label: {
                                ConversationRow(conversation: conversation)
                            }
                        }
                    }
                }
            }
            .listStyle(.plain)
            .searchable(text: $searchText, prompt: "Search")
            .navigationTitle("Teale")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.large)
            #endif
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button {
                            showNewChat = true
                        } label: {
                            Label("New Chat", systemImage: "bubble.left")
                        }
                        Button {
                            showNewGroup = true
                        } label: {
                            Label("New Group", systemImage: "person.3")
                        }
                    } label: {
                        Image(systemName: "square.and.pencil")
                    }
                }
            }
            .sheet(isPresented: $showNewGroup) {
                NewGroupSheet(appState: appState)
            }
            .task {
                await appState.chatService?.loadConversations()
            }
        }
    }

    // MARK: - Solo AI Chat Row

    private var soloAIChatRow: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(Color.teale)
                    .frame(width: 50, height: 50)
                Image(systemName: "sparkles")
                    .font(.title3)
                    .foregroundStyle(.white)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text("Teale AI")
                    .font(.body.weight(.semibold))
                Text("Your personal AI assistant")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Conversation Row

private struct ConversationRow: View {
    let conversation: Conversation

    var body: some View {
        HStack(spacing: 12) {
            // Avatar
            ZStack {
                Circle()
                    .fill(conversation.type == .group ? Color.teale.opacity(0.2) : Color.gray.opacity(0.15))
                    .frame(width: 50, height: 50)
                Image(systemName: conversation.type == .group ? "person.3.fill" : "person.fill")
                    .font(.body)
                    .foregroundStyle(conversation.type == .group ? Color.teale : .secondary)
            }

            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(conversation.title ?? "Chat")
                        .font(.body.weight(.semibold))
                        .lineLimit(1)
                    Spacer()
                    if let lastMessage = conversation.lastMessageAt {
                        Text(lastMessage, style: .relative)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if let preview = conversation.lastMessagePreview {
                    Text(preview)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - New Group Sheet

private struct NewGroupSheet: View {
    var appState: CompanionAppState
    @Environment(\.dismiss) private var dismiss
    @State private var groupName = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Group Name") {
                    TextField("e.g. Trip to Tokyo, Family Dinner", text: $groupName)
                }

                Section {
                    Text("Invite friends after creating the group. Teale AI will be available in the chat — just @teale to ask it anything.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("New Group")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        Task {
                            _ = await appState.chatService?.createGroup(
                                title: groupName,
                                memberIDs: []
                            )
                            await appState.chatService?.loadConversations()
                            dismiss()
                        }
                    }
                    .disabled(groupName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}
