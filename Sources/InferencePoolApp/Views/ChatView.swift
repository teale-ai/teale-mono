import SwiftUI
import AppCore
import SharedTypes

struct ChatView: View {
    @Environment(AppState.self) private var appState
    @State private var conversation: Conversation?
    @State private var messageText: String = ""
    @State private var streamingText: String = ""
    @State private var isGenerating: Bool = false
    @State private var showModelPicker: Bool = false

    /// Models that are downloaded and ready to load
    private var availableModels: [ModelDescriptor] {
        appState.modelManager.compatibleModels.filter {
            appState.downloadedModelIDs.contains($0.id)
        }
    }

    private var loadedModel: ModelDescriptor? {
        appState.engineStatus.currentModel
    }

    var body: some View {
        VStack(spacing: 0) {
            // No model banner
            if !hasInferenceTarget {
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
                    } else {
                        VStack(spacing: 12) {
                            Spacer(minLength: 80)
                            Image(systemName: "brain.head.profile")
                                .font(.system(size: 36))
                                .foregroundStyle(.quaternary)
                            Text(appState.loc("chat.startConversation"))
                                .font(.title3)
                                .foregroundStyle(.secondary)
                            if hasInferenceTarget {
                                Text(appState.loc("chat.typeBelow"))
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

            // Input area with model picker
            VStack(spacing: 0) {
                // Model picker row
                HStack(spacing: 6) {
                    modelPickerButton
                    Spacer()
                    if case .loadingModel(let m) = appState.engineStatus {
                        HStack(spacing: 4) {
                            ProgressView()
                                .controlSize(.mini)
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
                .padding(.bottom, 10)
            }
        }
        .navigationTitle(appState.loc("chat.title"))
        .onAppear {
            // Use the first conversation or create one — single continuous chat
            if let first = appState.conversationStore.conversations.first {
                conversation = first
            } else {
                conversation = appState.conversationStore.createConversation()
            }
        }
    }

    private var hasInferenceTarget: Bool {
        appState.hasAvailableInferenceTarget
    }

    private var canSend: Bool {
        !messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - Model Picker

    @ViewBuilder
    private var modelPickerButton: some View {
        Menu {
            if availableModels.isEmpty {
                Text("No models downloaded")
            } else {
                ForEach(availableModels) { model in
                    Button {
                        Task { await switchModel(model) }
                    } label: {
                        HStack {
                            Text(model.name)
                            Text(model.parameterCount)
                                .foregroundStyle(.secondary)
                            if loadedModel?.id == model.id {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                    .disabled(loadedModel?.id == model.id)
                }
            }

            Divider()

            Button {
                appState.currentView = .models
            } label: {
                Label("Browse Models…", systemImage: "square.grid.2x2")
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "cpu")
                    .font(.caption2)
                if let model = loadedModel {
                    Text(model.name)
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
    }

    private func switchModel(_ model: ModelDescriptor) async {
        guard loadedModel?.id != model.id else { return }
        await appState.loadModel(model)
    }

    // MARK: - Actions

    private func sendMessage() {
        guard canSend, !isGenerating else { return }
        guard let conversation else { return }

        let userText = messageText
        messageText = ""

        let _ = appState.conversationStore.addMessage(to: conversation, role: "user", content: userText)

        Task {
            await generateResponse(for: conversation)
        }
    }

    private func generateResponse(for conversation: Conversation) async {
        guard hasInferenceTarget else {
            let _ = appState.conversationStore.addMessage(to: conversation, role: "assistant", content: appState.loc("chat.noModelResponse"))
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
            let _ = appState.conversationStore.addMessage(to: conversation, role: "assistant", content: streamingText)
        } catch {
            let _ = appState.conversationStore.addMessage(to: conversation, role: "assistant", content: "Error: \(error.localizedDescription)")
        }

        streamingText = ""
        isGenerating = false
    }
}

// MARK: - Chat Bubble

private struct ChatBubbleView: View {
    @Environment(AppState.self) private var appState
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
                Text(isUser ? appState.loc("chat.you") : appState.loc("chat.assistant"))
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
