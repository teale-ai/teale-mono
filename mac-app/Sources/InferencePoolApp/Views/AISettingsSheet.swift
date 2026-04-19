import SwiftUI
import ChatKit

struct AISettingsSheet: View {
    let conversation: Conversation
    let chatService: ChatService

    @Environment(\.dismiss) private var dismiss
    @State private var autoRespond: Bool
    @State private var mentionOnly: Bool
    @State private var systemPrompt: String
    @State private var title: String
    @State private var heartbeatsEnabled: Bool
    @State private var memoryEntries: [MemoryEntry] = []

    init(conversation: Conversation, chatService: ChatService) {
        self.conversation = conversation
        self.chatService = chatService
        _autoRespond = State(initialValue: conversation.agentConfig.autoRespond)
        _mentionOnly = State(initialValue: conversation.agentConfig.mentionOnly)
        _systemPrompt = State(initialValue: conversation.agentConfig.systemPrompt ?? "")
        _title = State(initialValue: conversation.title ?? "")
        _heartbeatsEnabled = State(initialValue: conversation.heartbeatsEnabled)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("AI Settings")
                .font(.title2.weight(.semibold))

            Form {
                Section("Conversation") {
                    TextField("Title", text: $title)
                }

                Section("AI Behavior") {
                    Toggle("Auto-respond to every message", isOn: $autoRespond)
                        .onChange(of: autoRespond) { _, newValue in
                            if newValue { mentionOnly = false }
                        }
                    Toggle("Only respond when @mentioned", isOn: $mentionOnly)
                        .onChange(of: mentionOnly) { _, newValue in
                            if newValue { autoRespond = false }
                        }
                        .help("@teale or @agent triggers a response.")
                    Toggle("Proactive check-ins", isOn: $heartbeatsEnabled)
                        .help("Teale can post unprompted nudges about upcoming dates, stale plans, and unanswered questions.")
                }

                Section("Custom System Prompt (optional)") {
                    TextEditor(text: $systemPrompt)
                        .frame(minHeight: 80)
                        .font(.callout)
                }

                Section("Group Memory (\(memoryEntries.count))") {
                    if memoryEntries.isEmpty {
                        Text("Teale will write facts about this group here as you chat — preferences, dates, running plans.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(memoryEntries) { entry in
                            HStack(alignment: .top) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(entry.text)
                                        .font(.callout)
                                    if let category = entry.category {
                                        Text(category)
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                Button {
                                    chatService.memoryStore.remove(id: entry.id, from: conversation.id)
                                    refreshMemory()
                                } label: {
                                    Image(systemName: "trash")
                                }
                                .buttonStyle(.borderless)
                            }
                        }
                        Button("Clear all memory", role: .destructive) {
                            chatService.memoryStore.clear(conversationID: conversation.id)
                            refreshMemory()
                        }
                    }
                }
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 520, height: 640)
        .onAppear { refreshMemory() }
    }

    private func refreshMemory() {
        memoryEntries = chatService.memoryStore.entries(for: conversation.id).reversed()
    }

    private func save() {
        let newConfig = AgentConfig(
            model: conversation.agentConfig.model,
            systemPrompt: systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : systemPrompt,
            autoRespond: autoRespond,
            mentionOnly: mentionOnly,
            persona: conversation.agentConfig.persona
        )
        let newTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let capturedHeartbeats = heartbeatsEnabled

        Task {
            await chatService.updateConversation(
                id: conversation.id,
                title: newTitle.isEmpty ? nil : newTitle,
                agentConfig: newConfig,
                heartbeatsEnabled: capturedHeartbeats
            )
            dismiss()
        }
    }
}
