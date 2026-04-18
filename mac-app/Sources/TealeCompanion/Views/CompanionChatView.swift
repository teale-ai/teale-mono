import SwiftUI
import SharedTypes
import ChatKit

struct CompanionChatView: View {
    var appState: CompanionAppState
    @State private var inputText = ""
    @State private var isGenerating = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Status indicator
                statusBanner

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
                    modePicker
                }
                #else
                ToolbarItem(placement: .automatic) {
                    modePicker
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

    // MARK: - Status Banner

    private var statusBanner: some View {
        Group {
            switch appState.inferenceMode {
            case .local:
                if let model = appState.localModel {
                    HStack {
                        Image(systemName: "cpu")
                            .foregroundStyle(.green)
                            .font(.caption2)
                        Text("On-device: \(model.name)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
                    .background(.green.opacity(0.1))
                } else if appState.isLoadingModel {
                    HStack {
                        ProgressView()
                            .controlSize(.mini)
                        Text(appState.loadingPhase.isEmpty ? "Loading model..." : appState.loadingPhase)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
                    .background(.blue.opacity(0.1))
                } else {
                    HStack {
                        Image(systemName: "cpu")
                            .foregroundStyle(.orange)
                            .font(.caption2)
                        Text("No model loaded — go to Models tab")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
                    .background(.orange.opacity(0.1))
                }

            case .remote:
                remoteStatusBanner
            }
        }
    }

    private var remoteStatusBanner: some View {
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
                    Text("Not connected — go to Network tab")
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

    // MARK: - Mode Picker

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
                Text(appState.selectedModel ?? "No Model")
                    .font(.caption)
                    .lineLimit(1)
            }
        }
    }

    // MARK: - Empty State

    private var emptyStateView: some View {
        VStack(spacing: 16) {
            Spacer()
                .frame(height: 60)
            Image(systemName: "sparkles")
                .font(.system(size: 44))
                .foregroundStyle(Color.teale)
            Text("Chat with Teale")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.primary)

            if !appState.canInfer {
                Text(appState.inferenceMode == .local
                     ? "Download and load a model in the Models tab"
                     : "Connect to a Mac node in the Network tab")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            } else {
                Text("Ask me anything — or better yet, start a group chat and I can help plan trips, meals, events, and more with your friends and family.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }

            // Group nudge
            groupNudgeBanner
        }
    }

    private var groupNudgeBanner: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "person.3.fill")
                    .foregroundStyle(Color.teale)
                Text("I'm even better with groups")
                    .font(.subheadline.weight(.medium))
            }
            Text("Plan trips, coordinate calendars, split tasks — @teale in any group chat.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
        .frame(maxWidth: .infinity)
        .background(Color.tealeLight, in: RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal, 24)
        .padding(.top, 8)
    }

    // MARK: - Input Bar

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
                    .foregroundStyle(canSend ? Color.teale : .gray)
            }
            .disabled(!canSend)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    private var canSend: Bool {
        !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        && appState.canInfer
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
            return AnyShapeStyle(Color.teale)
        } else {
            return AnyShapeStyle(Color.gray.opacity(0.15))
        }
    }
}
