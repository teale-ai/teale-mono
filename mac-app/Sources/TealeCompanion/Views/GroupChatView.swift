import SwiftUI
import ChatKit
import SharedTypes

// MARK: - Group Chat View (iMessage/Signal-style, Teal-branded)

struct GroupChatView: View {
    var appState: CompanionAppState
    let conversation: Conversation
    @State private var inputText = ""
    @State private var isSending = false
    @State private var showWallet = false
    @State private var showMembers = false
    @State private var demoRunning = false

    private var chatService: ChatService { appState.chatService }
    private var isDemoConversation: Bool {
        conversation.title == DemoReservationDriver.conversationTitle
    }

    var body: some View {
        VStack(spacing: 0) {
            fundingHeader
            messagesScroll
            Divider()
            composer
        }
        .navigationTitle(conversation.title ?? "Chat")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            if isDemoConversation {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        playDemo()
                    } label: {
                        if demoRunning {
                            ProgressView().controlSize(.small)
                        } else {
                            Label("Play demo", systemImage: "play.fill")
                        }
                    }
                    .disabled(demoRunning)
                }
            } else {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button { showMembers = true } label: {
                            Label("Members & Invite", systemImage: "person.3")
                        }
                        Button { showWallet = true } label: {
                            Label("Group Wallet", systemImage: "creditcard")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
        }
        .task {
            await chatService.openConversation(conversation)
        }
        .onDisappear {
            Task { await chatService.closeConversation() }
        }
        .sheet(isPresented: $showWallet) {
            GroupWalletSheetiOS(
                conversation: conversation,
                chatService: chatService,
                currentUserID: appState.currentUserID
            )
        }
        .sheet(isPresented: $showMembers) {
            MembersSheetiOS(
                conversation: conversation,
                chatService: chatService,
                currentUserID: appState.currentUserID
            )
        }
    }

    // MARK: - Funding header

    private var fundingHeader: some View {
        let balance = chatService.walletStore.balance(for: conversation.id)
        let hasLocalSupply = appState.localModel != nil
        return HStack(spacing: 8) {
            Image(systemName: hasLocalSupply ? "bolt.horizontal.circle.fill" : (balance > 0 ? "creditcard.circle.fill" : "creditcard"))
                .foregroundStyle(hasLocalSupply ? .green : (balance > 0 ? Color.teale : .secondary))
            if hasLocalSupply {
                Text("Free — your device is supplying inference")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if balance > 0 {
                Text("Funded — group wallet: $\(String(format: "%.2f", balance))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("Add credits or join someone running Teale to chat with AI")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                showWallet = true
            } label: {
                Text("Wallet").font(.caption.weight(.medium))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(.regularMaterial)
    }

    // MARK: - Messages scroll

    private var messagesScroll: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    if chatService.activeMessages.isEmpty {
                        emptyState
                    } else {
                        ForEach(Array(runs.enumerated()), id: \.offset) { _, group in
                            ForEach(Array(group.bubbles.enumerated()), id: \.offset) { idx, bubble in
                                switch bubble.kind {
                                case .dateSeparator(let date):
                                    DateSeparator(date: date)
                                case .text(let message, let role):
                                    ChatBubble(
                                        content: message.content,
                                        role: role,
                                        senderLabel: idx == 0 ? bubble.senderLabel : nil,
                                        timestamp: idx == group.bubbles.count - 1 ? message.createdAt : nil,
                                        isFirstInRun: idx == 0,
                                        isLastInRun: idx == group.bubbles.count - 1
                                    )
                                    .id(message.id)
                                case .toolCall(let message):
                                    ToolCallInlineRow(content: message.content)
                                        .id(message.id)
                                case .toolResult(let message):
                                    ToolResultInlineRow(content: message.content)
                                        .id(message.id)
                                case .walletEntry(let message):
                                    WalletEntryChip(content: message.content, currentUserID: appState.currentUserID)
                                        .id(message.id)
                                case .agentRequest(let message):
                                    AgentExchangeChip(content: message.content, incoming: false)
                                        .id(message.id)
                                case .agentResponse(let message):
                                    AgentExchangeChip(content: message.content, incoming: true)
                                        .id(message.id)
                                case .disclosureConsent(let message):
                                    DisclosureConsentChip(content: message.content)
                                        .id(message.id)
                                case .system(let message):
                                    HStack {
                                        Spacer()
                                        Text(message.content)
                                            .font(.caption2.italic())
                                            .foregroundStyle(.secondary)
                                        Spacer()
                                    }
                                    .padding(.vertical, 8)
                                    .id(message.id)
                                }
                            }
                        }
                    }

                    if chatService.aiParticipant.isGenerating {
                        typingIndicator
                            .id("typing")
                    }
                }
                .padding(.vertical, 6)
            }
            .onChange(of: chatService.activeMessages.count) {
                if let last = chatService.activeMessages.last {
                    withAnimation(.easeOut(duration: 0.15)) {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
            .onChange(of: chatService.aiParticipant.streamingText) {
                withAnimation(.easeOut(duration: 0.15)) {
                    proxy.scrollTo("typing", anchor: .bottom)
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer().frame(height: 80)
            Image(systemName: conversation.type == .group ? "person.3" : "bubble.left.and.bubble.right")
                .font(.system(size: 40))
                .foregroundStyle(Color.teale.opacity(0.5))
            Text(conversation.type == .group ? "Start chatting with your group" : "Start chatting")
                .font(.headline)
                .foregroundStyle(.secondary)
            Text("Type @teale to ask the AI for help planning, scheduling, or anything else.")
                .font(.subheadline)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
    }

    private var typingIndicator: some View {
        HStack(spacing: 6) {
            HStack(spacing: 3) {
                ForEach(0..<3) { i in
                    Circle()
                        .fill(Color.teale)
                        .frame(width: 6, height: 6)
                        .opacity(0.6)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(Color.tealeLight, in: Capsule())
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 2)
    }

    // MARK: - Composer

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Message", text: $inputText, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...6)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Color.gray.opacity(0.12), in: Capsule())
                .disabled(isSending)

            Button(action: send) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 34)
                    .background(canSend ? Color.teale : Color.gray.opacity(0.35), in: Circle())
            }
            .disabled(!canSend)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    private var canSend: Bool {
        !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isSending
    }

    private func playDemo() {
        guard !demoRunning else { return }
        demoRunning = true
        Task {
            let driver = DemoReservationDriver(chatService: chatService)
            await driver.run(conversationID: conversation.id)
            demoRunning = false
        }
    }

    private func send() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        inputText = ""
        isSending = true

        Task {
            await chatService.sendMessage(text)

            if let lastMessage = chatService.activeMessages.last,
               chatService.aiParticipant.shouldRespond(
                   to: lastMessage,
                   config: conversation.agentConfig,
                   currentUserID: appState.currentUserID
               ) {
                await chatService.aiParticipant.runTurn(
                    conversation: conversation,
                    chatService: chatService,
                    participants: chatService.activeParticipants
                )
            }

            isSending = false
        }
    }

    // MARK: - Runs / date separators

    private enum BubbleKind {
        case dateSeparator(Date)
        case text(DecryptedMessage, BubbleRole)
        case toolCall(DecryptedMessage)
        case toolResult(DecryptedMessage)
        case walletEntry(DecryptedMessage)
        case agentRequest(DecryptedMessage)
        case agentResponse(DecryptedMessage)
        case disclosureConsent(DecryptedMessage)
        case system(DecryptedMessage)
    }

    private struct BubbleItem {
        let kind: BubbleKind
        let senderLabel: String?
    }

    private struct RunGroup {
        let bubbles: [BubbleItem]
    }

    /// Turn the flat message list into groups of consecutive bubbles from the same sender,
    /// with date separators inserted at day boundaries.
    private var runs: [RunGroup] {
        var result: [RunGroup] = []
        var current: [BubbleItem] = []
        var currentSender: UUID?? = .none
        var lastDate: Date?
        let cal = Calendar.current

        func flush() {
            if !current.isEmpty {
                result.append(RunGroup(bubbles: current))
                current = []
            }
        }

        for message in chatService.activeMessages {
            // Day break → date separator
            if let lastDate, !cal.isDate(lastDate, inSameDayAs: message.createdAt) {
                flush()
                result.append(RunGroup(bubbles: [BubbleItem(kind: .dateSeparator(message.createdAt), senderLabel: nil)]))
                currentSender = .none
            } else if lastDate == nil {
                result.append(RunGroup(bubbles: [BubbleItem(kind: .dateSeparator(message.createdAt), senderLabel: nil)]))
            }
            lastDate = message.createdAt

            switch message.messageType {
            case .text, .aiResponse:
                let role: BubbleRole = {
                    if message.isFromAgent { return .ai }
                    if message.senderID == appState.currentUserID { return .me }
                    return .them
                }()
                let senderLabel: String? = {
                    if role == .me { return nil }
                    if role == .ai { return "Teale" }
                    if let senderID = message.senderID {
                        return chatService.activeParticipants
                            .first { $0.participant.userID == senderID }?.displayName
                            ?? "User"
                    }
                    return "User"
                }()
                let sameSender: Bool = {
                    guard case .some(let prev) = currentSender else { return false }
                    return prev == message.senderID
                }()
                if !sameSender {
                    flush()
                    currentSender = .some(message.senderID)
                }
                current.append(BubbleItem(kind: .text(message, role), senderLabel: senderLabel))

            case .toolCall:
                flush()
                currentSender = .none
                result.append(RunGroup(bubbles: [BubbleItem(kind: .toolCall(message), senderLabel: nil)]))

            case .toolResult:
                flush()
                currentSender = .none
                result.append(RunGroup(bubbles: [BubbleItem(kind: .toolResult(message), senderLabel: nil)]))

            case .walletEntry:
                flush()
                currentSender = .none
                result.append(RunGroup(bubbles: [BubbleItem(kind: .walletEntry(message), senderLabel: nil)]))

            case .agentRequest:
                flush()
                currentSender = .none
                result.append(RunGroup(bubbles: [BubbleItem(kind: .agentRequest(message), senderLabel: nil)]))

            case .agentResponse:
                flush()
                currentSender = .none
                result.append(RunGroup(bubbles: [BubbleItem(kind: .agentResponse(message), senderLabel: nil)]))

            case .disclosureConsent:
                flush()
                currentSender = .none
                result.append(RunGroup(bubbles: [BubbleItem(kind: .disclosureConsent(message), senderLabel: nil)]))

            case .system:
                flush()
                currentSender = .none
                result.append(RunGroup(bubbles: [BubbleItem(kind: .system(message), senderLabel: nil)]))
            }
        }
        flush()
        return result
    }
}
