import SwiftUI
import AppCore
import ChatKit
import SharedTypes
import WANKit

struct ChatView: View {
    @Environment(AppState.self) private var appState
    @State private var selectedConversationID: UUID?

    var body: some View {
        HSplitView {
            ConversationListSidebar(
                chatService: appState.chatService,
                selectedID: $selectedConversationID
            )
            .frame(minWidth: 220, idealWidth: 260, maxWidth: 360)

            if let id = selectedConversationID,
               let conversation = appState.chatService.conversations.first(where: { $0.id == id }) {
                ConversationDetailView(conversation: conversation)
                    .id(conversation.id)
            } else {
                emptyState
            }
        }
        .navigationTitle(appState.loc("chat.title"))
        .task {
            // Select the first conversation on appear (AppState.initializeAsync
            // seeds one if none exist).
            if selectedConversationID == nil {
                selectedConversationID = appState.chatService.conversations.first?.id
            }
        }
        .onChange(of: appState.chatService.conversations.map(\.id)) { _, ids in
            if selectedConversationID == nil || !ids.contains(where: { $0 == selectedConversationID }) {
                selectedConversationID = ids.first
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 36))
                .foregroundStyle(.quaternary)
            Text(appState.loc("chat.startConversation"))
                .font(.title3)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Conversation List Sidebar

private struct ConversationListSidebar: View {
    @Environment(AppState.self) private var appState
    let chatService: ChatService
    @Binding var selectedID: UUID?
    @State private var showNewGroup = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(appState.loc("chat.title"))
                    .font(.headline)
                Spacer()
                Menu {
                    Button {
                        newDMChat()
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
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            List(selection: $selectedID) {
                ForEach(chatService.conversations) { conversation in
                    ConversationListRow(conversation: conversation)
                        .tag(conversation.id)
                        .contextMenu {
                            Button(role: .destructive) {
                                Task { await chatService.leaveConversation(conversation.id) }
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                }
            }
            .listStyle(.sidebar)
        }
        .sheet(isPresented: $showNewGroup) {
            NewGroupSheet(chatService: chatService) { newID in
                selectedID = newID
            }
        }
    }

    private func newDMChat() {
        Task {
            let created = await chatService.createDM(
                with: UUID(),
                title: "New Chat",
                agentConfig: AgentConfig(
                    autoRespond: true,
                    mentionOnly: false,
                    persona: "assistant"
                )
            )
            selectedID = created?.id
        }
    }
}

private struct ConversationListRow: View {
    let conversation: Conversation

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: conversation.type == .group ? "person.3.fill" : "bubble.left.fill")
                .font(.system(size: 14))
                .foregroundStyle(conversation.type == .group ? Color.orange : Color.blue)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text(conversation.displayTitle())
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                if let preview = conversation.lastMessagePreview, !preview.isEmpty {
                    Text(preview)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Conversation Detail View

private struct ConversationDetailView: View {
    @Environment(AppState.self) private var appState
    let conversation: Conversation
    @State private var messageText: String = ""
    @State private var selectedPeerModel: String?
    @State private var showAISettings = false
    @State private var showGroupWallet = false
    @State private var showMembers = false
    @State private var demoRunning = false
    @FocusState private var isInputFocused: Bool

    private var isDemoConversation: Bool {
        conversation.title == DemoReservationDriver.conversationTitle
    }

    private var chatService: ChatService { appState.chatService }
    private var aiParticipant: AIParticipant { appState.chatService.aiParticipant }

    private var loadedModel: ModelDescriptor? {
        appState.engineStatus.currentModel
    }

    private var hasInferenceTarget: Bool {
        appState.hasAvailableInferenceTarget
    }

    private var canSend: Bool {
        !messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            conversationHeader

            if !hasInferenceTarget {
                noModelBanner
            }

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        if chatService.activeMessages.isEmpty && !aiParticipant.isGenerating {
                            emptyChatHeader
                        }

                        ForEach(chatService.activeMessages) { message in
                            ChatBubbleView(
                                message: message,
                                isGroup: conversation.type == .group
                            )
                            .id(message.id)
                        }

                        if aiParticipant.isGenerating && !aiParticipant.streamingText.isEmpty {
                            AIStreamingBubble(text: aiParticipant.streamingText)
                                .id("streaming")
                        }

                        if aiParticipant.isGenerating && aiParticipant.streamingText.isEmpty {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.small)
                                Text(appState.loc("chat.thinking"))
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 12)
                            .id("loading")
                        }
                    }
                    .padding(.vertical, 8)
                }
                .onChange(of: aiParticipant.streamingText) {
                    withAnimation { proxy.scrollTo("streaming", anchor: .bottom) }
                }
                .onChange(of: chatService.activeMessages.count) {
                    if let last = chatService.activeMessages.last {
                        withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
            }

            Divider()
            inputBar
        }
        .task(id: conversation.id) {
            await chatService.openConversation(conversation)
            // Claim keyboard focus so typing works immediately after opening
            // or switching conversations.
            isInputFocused = true
        }
        .onDisappear {
            chatService.closeConversation()
        }
        .sheet(isPresented: $showAISettings) {
            AISettingsSheet(conversation: conversation, chatService: chatService)
        }
        .sheet(isPresented: $showGroupWallet) {
            GroupWalletSheet(
                conversation: conversation,
                chatService: chatService,
                currentUserID: appState.currentUserID
            )
        }
        .sheet(isPresented: $showMembers) {
            MembersSheet(
                conversation: conversation,
                chatService: chatService,
                currentUserID: appState.currentUserID
            )
        }
    }

    private var conversationHeader: some View {
        HStack(spacing: 8) {
            Image(systemName: conversation.type == .group ? "person.3.fill" : "bubble.left.fill")
                .foregroundStyle(conversation.type == .group ? .orange : .blue)
            Text(conversation.displayTitle())
                .font(.headline)
            Spacer()
            if isDemoConversation {
                Button {
                    playDemo()
                } label: {
                    if demoRunning {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Play demo", systemImage: "play.fill")
                            .labelStyle(.titleAndIcon)
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(Color(red: 0.0, green: 0.6, blue: 0.6))
                .controlSize(.small)
                .disabled(demoRunning)
            }
            HStack(spacing: 4) {
                Text("$\(String(format: "%.2f", chatService.walletStore.balance(for: conversation.id)))")
                    .font(.callout.monospacedDigit())
                Button {
                    showGroupWallet = true
                } label: {
                    Label("Wallet", systemImage: "creditcard")
                }
                .buttonStyle(.borderless)
                .labelStyle(.iconOnly)
                .help("Group wallet, contributions, and auto top-up")
            }
            if conversation.type == .group {
                Button {
                    showMembers = true
                } label: {
                    Label("Members", systemImage: "person.3")
                }
                .buttonStyle(.borderless)
                .labelStyle(.iconOnly)
                .help("View members and invite people")
            }
            Button {
                showAISettings = true
            } label: {
                Label("AI Settings", systemImage: "sparkles")
            }
            .buttonStyle(.borderless)
            .labelStyle(.iconOnly)
            .help("Edit AI behavior for this conversation")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.regularMaterial)
    }

    private var noModelBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(appState.loc("chat.noModelLoaded"))
                .font(.callout.weight(.medium))
            Text(appState.loc("chat.goToModels"))
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(10)
        .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 12)
        .padding(.top, 8)
    }

    private var emptyChatHeader: some View {
        VStack(spacing: 12) {
            Spacer(minLength: 80)
            Image(systemName: conversation.type == .group ? "person.3" : "brain.head.profile")
                .font(.system(size: 36))
                .foregroundStyle(.quaternary)
            Text(appState.loc("chat.startConversation"))
                .font(.title3)
                .foregroundStyle(.secondary)
            if conversation.type == .group {
                Text("Type @teale to ask the AI for help.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else if hasInferenceTarget {
                Text(appState.loc("chat.typeBelow"))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var inputBar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                ModelPickerButton(selectedPeerModel: $selectedPeerModel)
                Spacer()
                if case .loadingModel(let m) = appState.engineStatus {
                    HStack(spacing: 4) {
                        ProgressView().controlSize(.mini)
                        Text("Loading \(m.name)…")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 6)
            .padding(.bottom, 4)

            HStack(alignment: .bottom, spacing: 8) {
                TextField(appState.loc("chat.message"), text: $messageText, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...8)
                    .padding(8)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
                    .focused($isInputFocused)
                    .onSubmit { sendMessage() }

                Button(action: sendMessage) {
                    Image(systemName: aiParticipant.isGenerating ? "stop.circle.fill" : "arrow.up.circle.fill")
                        .font(.title2)
                        .foregroundStyle(canSend ? .blue : .secondary)
                }
                .buttonStyle(.plain)
                .disabled(!canSend && !aiParticipant.isGenerating)
                .keyboardShortcut(.return, modifiers: .command)
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 10)
        }
    }

    private func playDemo() {
        guard !demoRunning else { return }
        demoRunning = true
        let conv = conversation
        Task {
            let driver = DemoReservationDriver(chatService: chatService)
            await driver.run(conversationID: conv.id)
            demoRunning = false
        }
    }

    private func sendMessage() {
        let text = messageText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !aiParticipant.isGenerating else { return }
        messageText = ""

        let conv = conversation
        let agentConfig = conv.agentConfig
        let userID = appState.currentUserID

        Task {
            await chatService.sendMessage(text)

            guard let lastMessage = chatService.activeMessages.last,
                  aiParticipant.shouldRespond(to: lastMessage, config: agentConfig, currentUserID: userID) else {
                return
            }

            await aiParticipant.runTurn(
                conversation: conv,
                chatService: chatService,
                participants: chatService.activeParticipants
            )
        }
    }
}

// MARK: - Chat Bubble

private struct ChatBubbleView: View {
    let message: DecryptedMessage
    let isGroup: Bool

    var body: some View {
        switch message.messageType {
        case .toolCall:
            ToolCallBubble(content: message.content)
        case .toolResult:
            ToolResultBubble(content: message.content)
        case .agentRequest:
            MacAgentExchangeChip(content: message.content, incoming: false)
        case .agentResponse:
            MacAgentExchangeChip(content: message.content, incoming: true)
        case .disclosureConsent:
            MacDisclosureConsentChip(content: message.content)
        case .system:
            HStack {
                Spacer()
                Text(message.content)
                    .font(.caption2.italic())
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.vertical, 8)
        default:
            TextBubble(message: message)
        }
    }
}

// MARK: - Mac agent-to-agent chip

private struct MacAgentExchangeChip: View {
    let content: String
    let incoming: Bool

    private var exchange: AgentExchange? {
        guard let data = content.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(AgentExchange.self, from: data)
    }

    var body: some View {
        if let exchange {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    Image(systemName: "antenna.radiowaves.left.and.right")
                        .foregroundStyle(.white)
                        .frame(width: 32, height: 32)
                        .background(Color(red: 0.0, green: 0.6, blue: 0.6), in: Circle())
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 4) {
                            if incoming {
                                Text(exchange.counterpartyName)
                                Image(systemName: "arrow.right").font(.caption2)
                                Text("Teale")
                            } else {
                                Text("Teale")
                                Image(systemName: "arrow.right").font(.caption2)
                                Text(exchange.counterpartyName)
                            }
                        }
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        Text(exchange.headline)
                            .font(.callout.weight(.medium))
                    }
                    Spacer()
                }
                if !exchange.payload.isEmpty {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(exchange.payload.sorted(by: { $0.key < $1.key }), id: \.key) { kv in
                            HStack(alignment: .top, spacing: 8) {
                                Text(kv.key.replacingOccurrences(of: "_", with: " "))
                                    .font(.caption.monospaced().weight(.semibold))
                                    .foregroundStyle(.tertiary)
                                    .frame(width: 160, alignment: .leading)
                                Text(kv.value)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Spacer(minLength: 0)
                            }
                        }
                    }
                    .padding(.leading, 6)
                }
            }
            .padding(14)
            .background(
                LinearGradient(
                    colors: [
                        Color(red: 0.0, green: 0.6, blue: 0.6).opacity(0.12),
                        Color(red: 0.0, green: 0.6, blue: 0.6).opacity(0.04)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                in: RoundedRectangle(cornerRadius: 14)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(Color(red: 0.0, green: 0.6, blue: 0.6).opacity(0.3), lineWidth: 0.8)
            )
            .padding(.horizontal, 16)
            .padding(.vertical, 4)
        }
    }
}

private struct MacDisclosureConsentChip: View {
    let content: String

    private var consent: DisclosureConsent? {
        guard let data = content.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(DisclosureConsent.self, from: data)
    }

    var body: some View {
        if let consent {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Image(systemName: "lock.shield.fill")
                        .foregroundStyle(.white)
                        .frame(width: 32, height: 32)
                        .background(Color.orange, in: Circle())
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Share with \(consent.counterpartyName)?")
                            .font(.callout.weight(.semibold))
                        Text("Your agent will share only these items — nothing more.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(consent.disclosures, id: \.self) { item in
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: "checkmark").foregroundStyle(.green).font(.caption2)
                            Text(item).font(.caption)
                        }
                    }
                }
                .padding(.leading, 6)
            }
            .padding(14)
            .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(Color.orange.opacity(0.3), lineWidth: 0.8)
            )
            .padding(.horizontal, 16)
            .padding(.vertical, 4)
        }
    }
}

private struct TextBubble: View {
    let message: DecryptedMessage

    private var isAI: Bool { message.isFromAgent }
    /// In a DM the human's messages have no explicit senderID; in the demo
    /// conversation, "other humans" (Alex/Jamie/Sam) are inserted with real
    /// sender UUIDs. That's the rule we use to distinguish right-side ("you")
    /// from left-side ("other humans").
    private var isYou: Bool { !isAI && message.senderID == nil }

    var body: some View {
        if isAI {
            aiCenteredBubble
        } else if isYou {
            youBubble
        } else {
            otherBubble
        }
    }

    // Right-aligned Teal bubble for the local user.
    private var youBubble: some View {
        HStack(alignment: .bottom, spacing: 0) {
            Spacer(minLength: 120)
            VStack(alignment: .trailing, spacing: 6) {
                messageContent(alignment: .trailing)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                Color(red: 0.0, green: 0.6, blue: 0.6),
                in: UnevenRoundedRectangle(cornerRadii: RectangleCornerRadii(
                    topLeading: 18, bottomLeading: 18, bottomTrailing: 4, topTrailing: 18
                ))
            )
            .foregroundStyle(.white)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 3)
    }

    // Left-aligned gray bubble for other participants.
    private var otherBubble: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "person.circle.fill")
                .font(.system(size: 20))
                .foregroundStyle(.blue)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 6) {
                messageContent(alignment: .leading)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                Color.primary.opacity(0.07),
                in: UnevenRoundedRectangle(cornerRadii: RectangleCornerRadii(
                    topLeading: 18, bottomLeading: 4, bottomTrailing: 18, topTrailing: 18
                ))
            )
            Spacer(minLength: 120)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 3)
    }

    // Centered boxed card for AI — distinct from both sides of the chat.
    private var aiCenteredBubble: some View {
        HStack {
            Spacer(minLength: 0)
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "sparkles")
                        .font(.caption)
                        .foregroundStyle(Color(red: 0.0, green: 0.6, blue: 0.6))
                    Text("Teale")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color(red: 0.0, green: 0.6, blue: 0.6))
                    Spacer(minLength: 0)
                }
                messageContent(alignment: .leading)
            }
            .padding(14)
            .frame(maxWidth: 640, alignment: .leading)
            .background(
                LinearGradient(
                    colors: [
                        Color(red: 0.0, green: 0.6, blue: 0.6).opacity(0.10),
                        Color(red: 0.0, green: 0.6, blue: 0.6).opacity(0.03)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                in: RoundedRectangle(cornerRadius: 14)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(Color(red: 0.0, green: 0.6, blue: 0.6).opacity(0.25), lineWidth: 0.8)
            )
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private func messageContent(alignment: HorizontalAlignment) -> some View {
        ForEach(Array(MessageContentSegmenter.segments(message.content).enumerated()), id: \.offset) { _, segment in
            switch segment {
            case .text(let t):
                Text(LocalizedStringKey(t))
                    .textSelection(.enabled)
                    .font(.body)
                    .lineSpacing(3)
                    .multilineTextAlignment(alignment == .trailing ? .trailing : .leading)
                    .frame(maxWidth: .infinity, alignment: alignment == .trailing ? .trailing : .leading)
            case .code(let language, let code):
                CodeBlockView(language: language, code: code)
            }
        }
    }
}

private struct CodeBlockView: View {
    let language: String?
    let code: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let language, !language.isEmpty {
                HStack {
                    Text(language)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        copyToClipboard(code)
                    } label: {
                        Image(systemName: "doc.on.doc")
                            .font(.caption2)
                    }
                    .buttonStyle(.borderless)
                    .help("Copy code")
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Color.secondary.opacity(0.1))
            }
            Text(code)
                .font(.callout.monospaced())
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
        }
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(Color.secondary.opacity(0.2), lineWidth: 0.5)
        )
    }

    private func copyToClipboard(_ text: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #endif
    }
}

private struct ToolCallBubble: View {
    let content: String
    @State private var expanded = false

    private var call: ToolCall? {
        guard let data = content.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(ToolCall.self, from: data)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "wrench.and.screwdriver.fill")
                .font(.system(size: 16))
                .foregroundStyle(.orange)
                .frame(width: 24)

            DisclosureGroup(isExpanded: $expanded) {
                if let call, !call.params.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(call.params.sorted(by: { $0.key < $1.key }), id: \.key) { kv in
                            Text("\(kv.key): \(kv.value)")
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.top, 4)
                } else {
                    Text("(no parameters)")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            } label: {
                Text("Calling tool: \(call?.tool ?? "?")")
                    .font(.callout.weight(.medium))
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.05))
    }
}

private struct ToolResultBubble: View {
    let content: String
    @State private var expanded = true

    private var outcome: ToolOutcome? {
        guard let data = content.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(ToolOutcome.self, from: data)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: outcome?.success == false ? "exclamationmark.triangle.fill" : "checkmark.seal.fill")
                .font(.system(size: 16))
                .foregroundStyle(outcome?.success == false ? .red : .green)
                .frame(width: 24)

            DisclosureGroup(isExpanded: $expanded) {
                Text(outcome?.content ?? content)
                    .font(.callout.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 4)
            } label: {
                Text("Result from \(outcome?.tool ?? "tool")")
                    .font(.callout.weight(.medium))
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color.green.opacity(0.04))
    }
}

private struct AIStreamingBubble: View {
    let text: String

    var body: some View {
        HStack {
            Spacer(minLength: 0)
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "sparkles")
                        .font(.caption)
                        .foregroundStyle(Color(red: 0.0, green: 0.6, blue: 0.6))
                    Text("Teale")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color(red: 0.0, green: 0.6, blue: 0.6))
                    Spacer(minLength: 0)
                }
                Text(LocalizedStringKey(text))
                    .textSelection(.enabled)
                    .font(.body)
                    .lineSpacing(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(14)
            .frame(maxWidth: 640, alignment: .leading)
            .background(
                LinearGradient(
                    colors: [
                        Color(red: 0.0, green: 0.6, blue: 0.6).opacity(0.10),
                        Color(red: 0.0, green: 0.6, blue: 0.6).opacity(0.03)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                in: RoundedRectangle(cornerRadius: 14)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(Color(red: 0.0, green: 0.6, blue: 0.6).opacity(0.25), lineWidth: 0.8)
            )
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 6)
    }
}

// MARK: - Model Picker (extracted — unified local/LAN/WAN)

private struct ModelPickerButton: View {
    @Environment(AppState.self) private var appState
    @Binding var selectedPeerModel: String?

    private enum ModelSource {
        case local(ModelDescriptor)
        case lan(modelID: String, deviceCount: Int)
        case wan(modelID: String, deviceCount: Int)
    }

    private struct AvailableModel: Identifiable {
        var id: String
        var displayName: String
        var source: ModelSource
        var isLoaded: Bool
    }

    private var loadedModel: ModelDescriptor? {
        appState.engineStatus.currentModel
    }

    private var hasInferenceTarget: Bool {
        appState.hasAvailableInferenceTarget
    }

    private var allAvailableModels: [AvailableModel] {
        var models: [AvailableModel] = []
        var seenModelRepos: Set<String> = []

        let localModels = appState.modelManager.compatibleModels.filter {
            appState.downloadedModelIDs.contains($0.id)
        }
        for model in localModels {
            let isLoaded = loadedModel?.id == model.id && selectedPeerModel == nil
            models.append(AvailableModel(
                id: "local-\(model.id)",
                displayName: model.name,
                source: .local(model),
                isLoaded: isLoaded
            ))
            seenModelRepos.insert(model.huggingFaceRepo)
        }

        if appState.clusterEnabled {
            var lanModelCounts: [String: Int] = [:]
            for peer in appState.clusterManager.topology.connectedPeers {
                for model in peer.loadedModels {
                    lanModelCounts[model, default: 0] += 1
                }
            }
            for (modelID, count) in lanModelCounts.sorted(by: { $0.value > $1.value }) {
                guard !seenModelRepos.contains(modelID) else { continue }
                let shortName = cleanModelDisplayName(modelID)
                models.append(AvailableModel(
                    id: "lan-\(modelID)",
                    displayName: shortName,
                    source: .lan(modelID: modelID, deviceCount: count),
                    isLoaded: selectedPeerModel == modelID
                ))
                seenModelRepos.insert(modelID)
            }
        }

        if appState.wanEnabled {
            var wanModelCounts: [String: Int] = [:]
            for peer in appState.wanManager.state.connectedPeers {
                for model in peer.loadedModels {
                    wanModelCounts[model, default: 0] += 1
                }
            }
            for (modelID, count) in wanModelCounts.sorted(by: { $0.value > $1.value }) {
                guard !seenModelRepos.contains(modelID) else { continue }
                let shortName = cleanModelDisplayName(modelID)
                models.append(AvailableModel(
                    id: "wan-\(modelID)",
                    displayName: shortName,
                    source: .wan(modelID: modelID, deviceCount: count),
                    isLoaded: selectedPeerModel == modelID
                ))
            }
        }

        return models
    }

    private var selectedPeerModelIcon: String {
        guard let peerModel = selectedPeerModel else { return "memorychip" }
        let models = allAvailableModels
        if let entry = models.first(where: {
            switch $0.source {
            case .lan(let id, _), .wan(let id, _): return id == peerModel
            default: return false
            }
        }) {
            switch entry.source {
            case .lan: return "cable.connector"
            case .wan: return "globe"
            default: return "memorychip"
            }
        }
        return "globe"
    }

    var body: some View {
        let models = allAvailableModels
        let wanPeerCount = appState.wanManager.state.connectedPeers.count
        let wanModelCount = appState.wanManager.state.connectedPeers.flatMap(\.loadedModels).count

        Menu {
            if !models.isEmpty {
                ForEach(models) { entry in
                    Button {
                        switch entry.source {
                        case .local(let descriptor):
                            selectedPeerModel = nil
                            Task { await switchModel(descriptor) }
                        case .lan(let modelID, _), .wan(let modelID, _):
                            selectedPeerModel = modelID
                        }
                    } label: {
                        HStack {
                            switch entry.source {
                            case .local:
                                Label(entry.displayName, systemImage: "memorychip")
                                Text("Free").foregroundStyle(.secondary)
                            case .lan(_, let count):
                                Label(entry.displayName, systemImage: "cable.connector")
                                Text("Free").foregroundStyle(.secondary)
                                Text("\(count) device\(count == 1 ? "" : "s")")
                                    .foregroundStyle(.secondary)
                            case .wan(_, let count):
                                Label(entry.displayName, systemImage: "globe")
                                Text("$").foregroundStyle(.orange)
                                Text("\(count) device\(count == 1 ? "" : "s")")
                                    .foregroundStyle(.secondary)
                            }
                            if entry.isLoaded {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                    .disabled(entry.isLoaded)
                }
            } else {
                Text("No models available")
            }

            Divider()

            Button {
                appState.currentView = .models
            } label: {
                Label("Browse Models…", systemImage: "square.grid.2x2")
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: selectedPeerModelIcon)
                    .font(.caption2)
                if let peerModel = selectedPeerModel {
                    Text(cleanModelDisplayName(peerModel))
                        .font(.caption.weight(.medium))
                } else if let model = loadedModel {
                    Text(model.name)
                        .font(.caption.weight(.medium))
                } else if hasInferenceTarget {
                    Text("Peer model")
                        .font(.caption.weight(.medium))
                } else {
                    Text("No model")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                }
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(.quaternary.opacity(0.5), in: Capsule())
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .id("picker-\(models.count)-\(wanPeerCount)-\(wanModelCount)")
    }

    private func switchModel(_ model: ModelDescriptor) async {
        guard loadedModel?.id != model.id else { return }
        await appState.loadModel(model)
    }
}
