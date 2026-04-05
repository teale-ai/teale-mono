import SwiftUI
import SharedTypes

struct CompanionChatView: View {
    var appState: CompanionAppState
    @State private var inputText = ""
    @State private var isGenerating = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Connection indicator
                connectionBanner

                // Messages
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 12) {
                            if appState.conversationStore.activeMessages.isEmpty {
                                emptyStateView
                            } else {
                                ForEach(appState.conversationStore.activeMessages) { message in
                                    MessageBubbleView(message: message)
                                        .id(message.id)
                                }
                            }
                        }
                        .padding()
                    }
                    .onChange(of: appState.conversationStore.activeMessages.count) {
                        if let last = appState.conversationStore.activeMessages.last {
                            withAnimation {
                                proxy.scrollTo(last.id, anchor: .bottom)
                            }
                        }
                    }
                }

                Divider()

                // Input bar
                inputBar
            }
            .navigationTitle("Chat")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                #if os(iOS)
                ToolbarItem(placement: .topBarLeading) {
                    modelPicker
                }
                #else
                ToolbarItem(placement: .automatic) {
                    modelPicker
                }
                #endif
                ToolbarItem(placement: .automatic) {
                    Button {
                        _ = appState.conversationStore.createConversation(title: "New Chat")
                        appState.conversationStore.activeConversation = appState.conversationStore.conversations.first
                    } label: {
                        Image(systemName: "square.and.pencil")
                    }
                }
            }
        }
    }

    // MARK: - Subviews

    private var connectionBanner: some View {
        Group {
            switch appState.connectionStatus {
            case .connected(let name):
                HStack {
                    Image(systemName: "circle.fill")
                        .foregroundStyle(.green)
                        .font(.caption2)
                    Text("Connected to \(name)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
                .background(.green.opacity(0.1))

            case .disconnected:
                HStack {
                    Image(systemName: "circle.fill")
                        .foregroundStyle(.red)
                        .font(.caption2)
                    Text("Not connected -- go to Network tab")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
                .background(.red.opacity(0.1))

            case .connecting:
                HStack {
                    ProgressView()
                        .controlSize(.mini)
                    Text("Connecting...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
                .background(.yellow.opacity(0.1))

            case .error(let msg):
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.caption2)
                    Text(msg)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
                .background(.orange.opacity(0.1))
            }
        }
    }

    private var modelPicker: some View {
        Menu {
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
            if appState.availableModels.isEmpty {
                Text("No models available")
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "cpu")
                Text(appState.selectedModel ?? "No Model")
                    .font(.caption)
                    .lineLimit(1)
            }
        }
    }

    private var emptyStateView: some View {
        VStack(spacing: 16) {
            Spacer()
                .frame(height: 80)
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 48))
                .foregroundStyle(.tertiary)
            Text("Start a conversation")
                .font(.title3)
                .foregroundStyle(.secondary)
            if !appState.connectionStatus.isConnected {
                Text("Connect to a Mac node in the Network tab first")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var inputBar: some View {
        HStack(spacing: 8) {
            TextField("Message...", text: $inputText, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...5)
                .padding(10)
                .background(Color.gray.opacity(0.15))
                .clipShape(RoundedRectangle(cornerRadius: 20))
                .disabled(isGenerating)

            Button {
                sendMessage()
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.title2)
                    .foregroundStyle(canSend ? .blue : .gray)
            }
            .disabled(!canSend)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    private var canSend: Bool {
        !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        && appState.connectionStatus.isConnected
        && !isGenerating
    }

    private func sendMessage() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        inputText = ""
        isGenerating = true

        Task {
            await appState.sendMessage(text)
            isGenerating = false
        }
    }
}

// MARK: - Message Bubble

private struct MessageBubbleView: View {
    let message: CompanionMessage

    var body: some View {
        HStack {
            if message.role == .user { Spacer(minLength: 48) }

            VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 4) {
                Text(message.content)
                    .textSelection(.enabled)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(bubbleBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 18))
                    .foregroundStyle(message.role == .user ? .white : .primary)

                Text(message.timestamp, style: .time)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            if message.role == .assistant { Spacer(minLength: 48) }
        }
    }

    private var bubbleBackground: some ShapeStyle {
        if message.role == .user {
            return AnyShapeStyle(.blue)
        } else {
            return AnyShapeStyle(Color.gray.opacity(0.2))
        }
    }
}
