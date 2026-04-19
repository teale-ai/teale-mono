import SwiftUI
import SharedTypes
import ChatKit

// MARK: - Companion 1:1 Chat (with Teale AI)

struct CompanionChatView: View {
    var appState: CompanionAppState
    @State private var inputText = ""
    @State private var isSending = false

    private var chatService: ChatService { appState.chatService }

    var body: some View {
        VStack(spacing: 0) {
            statusBanner
            messagesScroll
            Divider()
            composer
        }
        .navigationTitle("Teale AI")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            #if os(iOS)
            ToolbarItem(placement: .topBarLeading) {
                modePicker
            }
            #else
            ToolbarItem(placement: .automatic) {
                modePicker
            }
            #endif
            ToolbarItem(placement: .automatic) {
                Button {
                    Task { await newChat() }
                } label: {
                    Image(systemName: "square.and.pencil")
                }
            }
        }
        .task {
            if chatService.activeConversation == nil,
               let first = chatService.conversations.first {
                await chatService.openConversation(first)
            }
        }
    }

    // MARK: - Status banner

    private var statusBanner: some View {
        Group {
            switch appState.inferenceMode {
            case .local:
                if let model = appState.localModel {
                    banner(icon: "cpu", tint: .green, text: "On-device: \(model.name)")
                } else if appState.isLoadingModel {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.mini)
                        Text(appState.loadingPhase.isEmpty ? "Loading model…" : appState.loadingPhase)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .background(Color.teale.opacity(0.08))
                } else {
                    banner(icon: "cpu", tint: .orange, text: "No model loaded — go to Models tab")
                }
            case .remote:
                remoteBanner
            }
        }
    }

    private func banner(icon: String, tint: Color, text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon).foregroundStyle(tint).font(.caption2)
            Text(text).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
        .background(tint.opacity(0.08))
    }

    @ViewBuilder private var remoteBanner: some View {
        switch appState.connectionStatus {
        case .connected(let name):
            banner(icon: "circle.fill", tint: .green, text: "Connected to \(name)")
        case .disconnected:
            banner(icon: "circle.fill", tint: .red, text: "Not connected — go to Network tab")
        case .connecting:
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text("Connecting…").font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .background(Color.yellow.opacity(0.1))
        case .error(let msg):
            banner(icon: "exclamationmark.triangle.fill", tint: .orange, text: msg)
        }
    }

    // MARK: - Mode picker

    private var modePicker: some View {
        Menu {
            Section("Inference Mode") {
                ForEach(InferenceMode.allCases, id: \.self) { mode in
                    Button {
                        appState.inferenceMode = mode
                    } label: {
                        HStack {
                            Label(mode.rawValue, systemImage: mode == .local ? "cpu" : "network")
                            if mode == appState.inferenceMode {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            }
            if appState.inferenceMode == .remote {
                Section("Remote Models") {
                    ForEach(appState.availableModels, id: \.self) { model in
                        Button {
                            appState.selectedModel = model
                        } label: {
                            HStack {
                                Text(model)
                                if model == appState.selectedModel {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: appState.inferenceMode == .local ? "cpu" : "network")
                Text(appState.selectedModel ?? "Pick model")
                    .font(.caption)
                    .lineLimit(1)
            }
        }
    }

    // MARK: - Messages

    private var messagesScroll: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    if chatService.activeMessages.isEmpty {
                        emptyState
                    } else {
                        ForEach(Array(chatService.activeMessages.enumerated()), id: \.element.id) { idx, message in
                            renderMessage(message, previous: idx > 0 ? chatService.activeMessages[idx - 1] : nil)
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

    @ViewBuilder
    private func renderMessage(_ message: DecryptedMessage, previous: DecryptedMessage?) -> some View {
        switch message.messageType {
        case .text, .aiResponse:
            let role: BubbleRole = message.isFromAgent ? .ai : .me
            let isFirstInRun = previous?.isFromAgent != message.isFromAgent
            ChatBubble(
                content: message.content,
                role: role,
                senderLabel: isFirstInRun && role == .ai ? "Teale" : nil,
                timestamp: message.createdAt,
                isFirstInRun: isFirstInRun,
                isLastInRun: true
            )
            .id(message.id)
        case .toolCall:
            ToolCallInlineRow(content: message.content).id(message.id)
        case .toolResult:
            ToolResultInlineRow(content: message.content).id(message.id)
        case .walletEntry:
            WalletEntryChip(content: message.content, currentUserID: appState.currentUserID)
                .id(message.id)
        case .agentRequest:
            AgentExchangeChip(content: message.content, incoming: false).id(message.id)
        case .agentResponse:
            AgentExchangeChip(content: message.content, incoming: true).id(message.id)
        case .disclosureConsent:
            DisclosureConsentChip(content: message.content).id(message.id)
        case .system:
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

    private var emptyState: some View {
        VStack(spacing: 16) {
            Spacer().frame(height: 60)
            Image(systemName: "sparkles")
                .font(.system(size: 44))
                .foregroundStyle(Color.teale)
            Text("Chat with Teale")
                .font(.title3.weight(.semibold))
            if !appState.canInfer {
                Text(appState.inferenceMode == .local
                     ? "Download a model in Models, or connect to a Mac running Teale."
                     : "Connect to a Mac node in the Network tab.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            } else {
                Text("Ask anything. In a group chat, @teale to bring the AI in.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }
        }
    }

    private var typingIndicator: some View {
        HStack(spacing: 6) {
            HStack(spacing: 3) {
                ForEach(0..<3) { _ in
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

            Button {
                send()
            } label: {
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
        !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        && appState.canInfer
        && !isSending
    }

    private func send() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        inputText = ""
        isSending = true
        Task {
            await appState.sendMessage(text)
            isSending = false
        }
    }

    private func newChat() async {
        let created = await chatService.createDM(
            with: UUID(),
            title: "New Chat",
            agentConfig: AgentConfig(
                autoRespond: true,
                mentionOnly: false,
                persona: "assistant"
            )
        )
        if let created {
            await chatService.openConversation(created)
        }
    }
}
