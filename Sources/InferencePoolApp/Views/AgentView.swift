import SwiftUI
import AppCore
import AgentKit

struct AgentView: View {
    @Environment(AppState.self) private var appState
    @State private var agentState: AgentManagerState?
    @State private var selectedConversation: AgentConversation?
    @State private var newIntentText: String = ""
    @State private var newChatText: String = ""
    @State private var showProfileEditor: Bool = false

    var body: some View {
        HSplitView {
            // Left: conversation list + profile
            VStack(spacing: 0) {
                // Profile card
                AgentProfileCard(profile: appState.agentProfile)
                    .padding(8)

                Divider()

                // Conversations
                if let state = agentState {
                    if state.activeConversations.isEmpty {
                        VStack(spacing: 8) {
                            Image(systemName: "bubble.left.and.text.bubble.right")
                                .font(.title2)
                                .foregroundStyle(.secondary)
                            Text("No conversations")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        List(state.activeConversations, selection: $selectedConversation) { convo in
                            AgentConversationRow(conversation: convo, myNodeID: appState.agentProfile?.nodeID ?? "")
                                .tag(convo)
                        }
                        .listStyle(.sidebar)
                    }
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }

                Divider()

                // Directory count
                if let state = agentState {
                    HStack {
                        Image(systemName: "person.2")
                            .foregroundStyle(.secondary)
                        Text("\(state.directoryEntries.count) known agents")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    .padding(8)
                }
            }
            .frame(minWidth: 180, maxWidth: 220)

            // Right: conversation detail or directory
            VStack(spacing: 0) {
                if let convo = selectedConversation {
                    AgentConversationDetail(conversation: convo, myNodeID: appState.agentProfile?.nodeID ?? "")

                    Divider()

                    // Chat input
                    HStack(spacing: 8) {
                        TextField("Message...", text: $newChatText, axis: .vertical)
                            .textFieldStyle(.plain)
                            .lineLimit(1...3)
                            .onSubmit { sendChat() }

                        Button(action: sendChat) {
                            Image(systemName: "arrow.up.circle.fill")
                                .font(.title2)
                        }
                        .buttonStyle(.plain)
                        .disabled(newChatText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    .padding(12)
                } else {
                    // Directory view
                    AgentDirectoryView()
                }
            }
        }
        .navigationTitle("Agents")
        .task {
            await refreshState()
        }
    }

    private func refreshState() async {
        agentState = await appState.agentManager.getState()
    }

    private func sendChat() {
        guard !newChatText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        guard let convo = selectedConversation else { return }
        let text = newChatText
        newChatText = ""

        let peerID = convo.participants.first { $0 != appState.agentProfile?.nodeID } ?? ""

        Task {
            _ = try? await appState.agentManager.sendChat(
                to: peerID,
                message: text,
                conversationID: convo.id
            )
            await refreshState()
        }
    }
}

// MARK: - Agent Profile Card

private struct AgentProfileCard: View {
    let profile: AgentProfile?

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: profileIcon)
                .font(.title2)
                .foregroundStyle(.purple)

            VStack(alignment: .leading, spacing: 2) {
                if let profile = profile {
                    Text(profile.displayName)
                        .font(.caption.bold())
                    Text(profile.agentType.rawValue.capitalized)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Setting up...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            Circle()
                .fill(profile != nil ? .green : .orange)
                .frame(width: 8, height: 8)
        }
    }

    private var profileIcon: String {
        guard let profile = profile else { return "person.circle" }
        switch profile.agentType {
        case .personal: return "person.circle.fill"
        case .business: return "building.2.crop.circle.fill"
        case .service: return "gearshape.circle.fill"
        }
    }
}

// MARK: - Conversation Row

private struct AgentConversationRow: View {
    let conversation: AgentConversation
    let myNodeID: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: stateIcon)
                    .foregroundStyle(stateColor)
                    .font(.caption)
                Text(peerName)
                    .font(.caption.bold())
                    .lineLimit(1)
            }

            if let intent = conversation.intent {
                Text(intent.description)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else if let lastMsg = conversation.messages.last {
                switch lastMsg.type {
                case .chat(let payload):
                    Text(payload.content)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                default:
                    Text(conversation.state.rawValue)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            Text(conversation.updatedAt, style: .relative)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
    }

    private var peerName: String {
        conversation.participants.first { $0 != myNodeID }?.prefix(12).description ?? "Unknown"
    }

    private var stateIcon: String {
        switch conversation.state {
        case .initiated: return "paperplane"
        case .negotiating: return "arrow.left.arrow.right"
        case .accepted: return "checkmark.circle"
        case .completed: return "checkmark.circle.fill"
        case .rejected: return "xmark.circle"
        case .expired: return "clock"
        case .chatting: return "bubble.left.and.bubble.right"
        }
    }

    private var stateColor: Color {
        switch conversation.state {
        case .initiated, .negotiating: return .orange
        case .accepted: return .blue
        case .completed: return .green
        case .rejected: return .red
        case .expired: return .gray
        case .chatting: return .purple
        }
    }
}

// MARK: - Conversation Detail

private struct AgentConversationDetail: View {
    let conversation: AgentConversation
    let myNodeID: String

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 8) {
                // State badge
                HStack {
                    Label(conversation.state.rawValue.capitalized, systemImage: "circle.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    if let intent = conversation.intent {
                        Text(intent.category)
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.purple.opacity(0.2))
                            .clipShape(Capsule())
                    }
                }

                Divider()

                // Messages
                ForEach(conversation.messages) { message in
                    AgentMessageBubble(message: message, isMe: message.fromAgentID == myNodeID)
                }
            }
            .padding()
        }
    }
}

// MARK: - Message Bubble

private struct AgentMessageBubble: View {
    let message: AgentMessage
    let isMe: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            if isMe { Spacer(minLength: 40) }

            VStack(alignment: isMe ? .trailing : .leading, spacing: 4) {
                Text(isMe ? "You" : String(message.fromAgentID.prefix(8)))
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                Text(messageContent)
                    .font(.caption)
                    .padding(8)
                    .background(isMe ? Color.blue.opacity(0.15) : Color.gray.opacity(0.15))
                    .clipShape(RoundedRectangle(cornerRadius: 8))

                Text(message.timestamp, style: .time)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            if !isMe { Spacer(minLength: 40) }
        }
    }

    private var messageContent: String {
        switch message.type {
        case .intent(let payload):
            return "Intent: \(payload.description)"
        case .offer(let payload):
            return "Offer: \(payload.description) (\(String(format: "%.1f", payload.creditCost)) credits)"
        case .counterOffer(let payload):
            return "Counter: \(payload.description) (\(String(format: "%.1f", payload.creditCost)) credits)"
        case .accept(let payload):
            return "Accepted for \(String(format: "%.1f", payload.agreedCost)) credits"
        case .reject(let payload):
            return "Rejected: \(payload.reason)"
        case .complete(let payload):
            return "Completed: \(payload.outcome)"
        case .review(let payload):
            return "Review: \(String(repeating: "★", count: payload.rating))\(String(repeating: "☆", count: 5 - payload.rating))"
        case .chat(let payload):
            return payload.content
        case .capability(let payload):
            return "Capabilities: \(payload.capabilities.map(\.name).joined(separator: ", "))"
        case .status(let payload):
            return "Status: \(payload.status.rawValue) — \(payload.message ?? "")"
        }
    }
}

// MARK: - Agent Directory View

private struct AgentDirectoryView: View {
    @Environment(AppState.self) private var appState
    @State private var entries: [AgentDirectoryEntry] = []

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Agent Directory")
                    .font(.headline)
                Spacer()
                Button {
                    Task { await refresh() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .padding()

            Divider()

            if entries.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "person.2.wave.2")
                        .font(.system(size: 40))
                        .foregroundStyle(.secondary)
                    Text("No agents discovered yet")
                        .foregroundStyle(.secondary)
                    Text("Agents on your LAN and WAN network will appear here as they come online")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 1) {
                        ForEach(entries, id: \.profile.nodeID) { entry in
                            AgentDirectoryRow(entry: entry)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                        }
                    }
                }
            }
        }
        .task { await refresh() }
    }

    private func refresh() async {
        entries = await appState.agentManager.directory.allEntries()
    }
}

// MARK: - Directory Row

private struct AgentDirectoryRow: View {
    let entry: AgentDirectoryEntry

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: typeIcon)
                .font(.title2)
                .foregroundStyle(entry.isOnline ? .green : .gray)

            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(entry.profile.displayName)
                        .font(.body.bold())
                    Text(entry.profile.agentType.rawValue)
                        .font(.caption2)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(.quaternary)
                        .clipShape(Capsule())
                }

                if !entry.profile.bio.isEmpty {
                    Text(entry.profile.bio)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                HStack(spacing: 6) {
                    ForEach(entry.profile.capabilities.prefix(3)) { cap in
                        Text(cap.name)
                            .font(.caption2)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(.blue.opacity(0.1))
                            .clipShape(Capsule())
                    }
                }
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 4) {
                Circle()
                    .fill(entry.isOnline ? .green : .gray)
                    .frame(width: 8, height: 8)
                if let rating = entry.rating {
                    HStack(spacing: 2) {
                        Image(systemName: "star.fill")
                            .foregroundStyle(.yellow)
                        Text(String(format: "%.1f", rating))
                    }
                    .font(.caption2)
                }
            }
        }
    }

    private var typeIcon: String {
        switch entry.profile.agentType {
        case .personal: return "person.circle.fill"
        case .business: return "building.2.crop.circle.fill"
        case .service: return "gearshape.circle.fill"
        }
    }
}
