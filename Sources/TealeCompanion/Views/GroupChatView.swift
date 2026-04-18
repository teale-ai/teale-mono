import SwiftUI
import ChatKit
import SharedTypes

// MARK: - Group Chat View

struct GroupChatView: View {
    var appState: CompanionAppState
    let conversation: Conversation
    @State private var inputText = ""
    @State private var isSending = false

    private var chatService: ChatService? { appState.chatService }

    var body: some View {
        VStack(spacing: 0) {
            // Messages
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 2) {
                        if let messages = chatService?.activeMessages, !messages.isEmpty {
                            ForEach(messages) { message in
                                GroupMessageBubble(
                                    message: message,
                                    participants: chatService?.activeParticipants ?? [],
                                    isGroup: conversation.type == .group
                                )
                                .id(message.id)
                            }
                        } else {
                            groupEmptyState
                        }

                        // AI streaming indicator
                        if let ai = chatService?.aiParticipant, ai.isGenerating {
                            HStack(spacing: 8) {
                                ProgressView()
                                    .controlSize(.small)
                                Text("Teale is thinking...")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal)
                            .padding(.vertical, 8)
                            .id("ai-typing")
                        }
                    }
                    .padding(.vertical, 8)
                }
                .onChange(of: chatService?.activeMessages.count) {
                    if let last = chatService?.activeMessages.last {
                        withAnimation(.easeOut(duration: 0.15)) {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
            }

            Divider()

            // Input bar
            groupInputBar
        }
        .navigationTitle(conversation.title ?? "Chat")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button {
                        // TODO: invite flow
                    } label: {
                        Label("Invite People", systemImage: "person.badge.plus")
                    }
                    Button {
                        // TODO: agent settings
                    } label: {
                        Label("AI Settings", systemImage: "sparkles")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .task {
            await chatService?.openConversation(conversation)
        }
        .onDisappear {
            Task { await chatService?.closeConversation() }
        }
    }

    // MARK: - Empty State

    private var groupEmptyState: some View {
        VStack(spacing: 16) {
            Spacer().frame(height: 60)
            Image(systemName: conversation.type == .group ? "person.3" : "bubble.left.and.bubble.right")
                .font(.system(size: 40))
                .foregroundStyle(Color.teale.opacity(0.4))

            Text(conversation.type == .group ? "Start chatting with your group" : "Start chatting")
                .font(.headline)
                .foregroundStyle(.secondary)

            Text("Type @teale to ask the AI for help with planning, scheduling, or anything else.")
                .font(.subheadline)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
    }

    // MARK: - Input Bar

    private var groupInputBar: some View {
        HStack(spacing: 8) {
            TextField("Message...", text: $inputText, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...5)
                .padding(10)
                .background(Color.gray.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 20))
                .disabled(isSending)

            Button {
                sendGroupMessage()
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
        !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isSending
    }

    private func sendGroupMessage() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        inputText = ""
        isSending = true

        Task {
            await chatService?.sendMessage(text)

            // Check if AI should respond
            if let chatService,
               let lastMessage = chatService.activeMessages.last,
               chatService.aiParticipant.shouldRespond(
                   to: lastMessage,
                   config: conversation.agentConfig,
                   currentUserID: appState.currentUserID
               ) {
                let response = await chatService.aiParticipant.generateResponse(
                    conversation: conversation,
                    messages: chatService.activeMessages,
                    participants: chatService.activeParticipants,
                    tools: []
                )
                if let response {
                    await chatService.insertAIMessage(response, conversationID: conversation.id)
                }
            }

            isSending = false
        }
    }
}

// MARK: - Group Message Bubble

private struct GroupMessageBubble: View {
    let message: DecryptedMessage
    let participants: [ParticipantInfo]
    let isGroup: Bool

    private var senderName: String? {
        guard isGroup, let senderID = message.senderID else { return nil }
        return participants.first { $0.participant.userID == senderID }?.displayName
    }

    private var isOwnMessage: Bool {
        message.senderID != nil && !message.isFromAgent
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 6) {
            if isOwnMessage { Spacer(minLength: 48) }

            VStack(alignment: isOwnMessage ? .trailing : .leading, spacing: 2) {
                // Sender name in group chats
                if let name = senderName, !isOwnMessage {
                    Text(name)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Color.teale)
                        .padding(.leading, 4)
                }

                // AI label
                if message.isFromAgent {
                    HStack(spacing: 4) {
                        Image(systemName: "sparkles")
                            .font(.caption2)
                            .foregroundStyle(Color.teale)
                        Text("Teale")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(Color.teale)
                    }
                    .padding(.leading, 4)
                }

                Text(message.content)
                    .textSelection(.enabled)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(bubbleColor)
                    .clipShape(RoundedRectangle(cornerRadius: 18))
                    .foregroundStyle(isOwnMessage ? .white : .primary)

                Text(message.createdAt, style: .time)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 4)
            }

            if !isOwnMessage { Spacer(minLength: 48) }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 1)
    }

    private var bubbleColor: some ShapeStyle {
        if isOwnMessage {
            return AnyShapeStyle(Color.teale)
        } else if message.isFromAgent {
            return AnyShapeStyle(Color.tealeLight)
        } else {
            return AnyShapeStyle(Color.gray.opacity(0.15))
        }
    }
}
