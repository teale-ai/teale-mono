import SwiftUI
import SharedTypes

struct ChatView: View {
    @Environment(AppState.self) private var appState
    @State private var store = ConversationStore()
    @State private var conversation: Conversation?
    @State private var messageText: String = ""
    @State private var streamingText: String = ""
    @State private var isGenerating: Bool = false
    @State private var hasModelLoaded: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            // No model banner
            if !hasModelLoaded {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text("No model loaded.")
                        .font(.callout.weight(.medium))
                    Text("Go to **Models** to download and load one.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(10)
                .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                .padding(.horizontal, 12)
                .padding(.top, 8)
            }

            // Messages
            ScrollViewReader { proxy in
                ScrollView {
                    if let conversation, !conversation.messages.isEmpty || isGenerating {
                        LazyVStack(spacing: 0) {
                            ForEach(conversation.messages) { message in
                                ChatBubbleView(role: message.role, content: message.content)
                                    .id(message.id)
                            }

                            if isGenerating && !streamingText.isEmpty {
                                ChatBubbleView(role: "assistant", content: streamingText)
                                    .id("streaming")
                            }

                            if isGenerating && streamingText.isEmpty {
                                HStack(spacing: 6) {
                                    ProgressView()
                                        .controlSize(.small)
                                    Text("Thinking...")
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
                    } else {
                        VStack(spacing: 12) {
                            Spacer(minLength: 80)
                            Image(systemName: "brain.head.profile")
                                .font(.system(size: 36))
                                .foregroundStyle(.quaternary)
                            Text("Start a conversation")
                                .font(.title3)
                                .foregroundStyle(.secondary)
                            if hasModelLoaded {
                                Text("Type a message below to begin")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }
                            Spacer()
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
                .onChange(of: streamingText) {
                    withAnimation {
                        proxy.scrollTo("streaming", anchor: .bottom)
                    }
                }
                .onChange(of: conversation?.messages.count) {
                    if let last = conversation?.messages.last {
                        withAnimation {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
            }

            Divider()

            // Input area
            HStack(alignment: .bottom, spacing: 8) {
                TextField("Message...", text: $messageText, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...8)
                    .padding(8)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
                    .onSubmit { sendMessage() }

                Button(action: sendMessage) {
                    Image(systemName: isGenerating ? "stop.circle.fill" : "arrow.up.circle.fill")
                        .font(.title2)
                        .foregroundStyle(canSend ? .blue : .secondary)
                }
                .buttonStyle(.plain)
                .disabled(!canSend && !isGenerating)
                .keyboardShortcut(.return, modifiers: .command)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
        .navigationTitle("Chat")
        .onAppear {
            // Use the first conversation or create one — single continuous chat
            if let first = store.conversations.first {
                conversation = first
            } else {
                conversation = store.createConversation()
            }
        }
        .task {
            await checkModelLoaded()
        }
    }

    private var canSend: Bool {
        !messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func checkModelLoaded() async {
        let model = await appState.engine.loadedModel
        hasModelLoaded = model != nil
    }

    // MARK: - Actions

    private func sendMessage() {
        guard canSend, !isGenerating else { return }
        guard let conversation else { return }

        let userText = messageText
        messageText = ""

        let _ = store.addMessage(to: conversation, role: "user", content: userText)

        Task {
            await generateResponse(for: conversation)
        }
    }

    private func generateResponse(for conversation: Conversation) async {
        await checkModelLoaded()
        guard hasModelLoaded else {
            let _ = store.addMessage(to: conversation, role: "assistant", content: "No model loaded. Go to Models to download and load one.")
            return
        }

        isGenerating = true
        streamingText = ""

        let apiMessages = conversation.messages.map { msg in
            APIMessage(role: msg.role, content: msg.content)
        }

        let request = ChatCompletionRequest(messages: apiMessages, stream: true)
        let stream = appState.engine.generate(request: request)

        do {
            for try await chunk in stream {
                if let content = chunk.choices.first?.delta.content {
                    streamingText += content
                }
            }
            let _ = store.addMessage(to: conversation, role: "assistant", content: streamingText)
        } catch {
            let _ = store.addMessage(to: conversation, role: "assistant", content: "Error: \(error.localizedDescription)")
        }

        streamingText = ""
        isGenerating = false
    }
}

// MARK: - Chat Bubble

private struct ChatBubbleView: View {
    let role: String
    let content: String

    private var isUser: Bool { role == "user" }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: isUser ? "person.circle.fill" : "brain.head.profile")
                .font(.system(size: 20))
                .foregroundStyle(isUser ? .blue : .purple)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(isUser ? "You" : "Assistant")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                Text(LocalizedStringKey(content))
                    .textSelection(.enabled)
                    .font(.body)
                    .lineSpacing(3)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(isUser ? Color.clear : Color.primary.opacity(0.03))
    }
}
