import SwiftUI
import AppCore
import SharedTypes
import ChatKit
import ModelManager

struct CompanionHomeChatSection: View {
    @Environment(AppState.self) private var appState

    @State private var inputText = ""
    @State private var isSending = false
    @State private var activeSendThreadID: UUID?
    @State private var statusMessage = ""
    @State private var statusIsError = false
    @State private var streamingText = ""
    @State private var interruptedDrafts: [UUID: String] = [:]

    private var chatService: ChatService { appState.chatService }

    private var threads: [Conversation] {
        chatService.conversations
            .filter { $0.type == .dm && !$0.isArchived }
            .sorted { left, right in
                if left.updatedAt != right.updatedAt {
                    return left.updatedAt > right.updatedAt
                }
                return left.createdAt > right.createdAt
            }
    }

    private var activeThread: Conversation? {
        if let active = chatService.activeConversation,
           active.type == .dm,
           !active.isArchived {
            return active
        }
        return threads.first
    }

    private var visibleMessages: [DecryptedMessage] {
        chatService.activeMessages.filter { message in
            message.messageType == .text || message.messageType == .aiResponse
        }
    }

    private var modelOptions: [CompanionHomeModelOption] {
        var options: [CompanionHomeModelOption] = []
        var seen = Set<String>()

        if let local = appState.engineStatus.currentModel {
            let identifier = local.openrouterId ?? local.huggingFaceRepo
            if seen.insert(identifier).inserted {
                options.append(
                    CompanionHomeModelOption(
                        id: identifier,
                        label: "FREE - \(local.name)",
                        note: "Local is free on this Mac."
                    )
                )
            }
        }

        for model in ModelCatalog.allModels.sorted(by: { lhs, rhs in
            if lhs.popularityRank != rhs.popularityRank {
                return lhs.popularityRank < rhs.popularityRank
            }
            return lhs.requiredRAMGB < rhs.requiredRAMGB
        }) {
            let identifier = model.openrouterId ?? model.huggingFaceRepo
            guard seen.insert(identifier).inserted else { continue }
            options.append(
                CompanionHomeModelOption(
                    id: identifier,
                    label: model.name,
                    note: appState.gatewayAPIKey.isEmpty
                        ? "Connected peers can serve this now. Add a gateway bearer for wider network fallback."
                        : "Network models spend Teale credits when local supply cannot serve them."
                )
            )
        }

        return options
    }

    var body: some View {
        TealeSection(prompt: "thread") {
            VStack(alignment: .leading, spacing: 12) {
                threadStrip
                modelPicker
                statusLine
                transcript
                composer
            }
        }
        .task {
            await ensureThreadReady()
        }
        .onChange(of: threads.map(\.id)) { _, _ in
            Task {
                await ensureThreadReady()
            }
        }
    }

    private var threadStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(threads) { thread in
                    CompanionHomeThreadChip(
                        title: thread.displayTitle(),
                        active: thread.id == activeThread?.id,
                        disabled: isSending,
                        onSelect: {
                            Task {
                                await openThread(thread)
                            }
                        },
                        onClose: {
                            Task {
                                await closeThread(thread)
                            }
                        }
                    )
                }

                TealeActionButton(title: "new thread", primary: false, disabled: isSending) {
                    Task {
                        await createThread()
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var modelPicker: some View {
        if let activeThread {
            VStack(alignment: .leading, spacing: 6) {
                Text("MODEL")
                    .font(TealeDesign.monoSmall)
                    .tracking(0.9)
                    .foregroundStyle(TealeDesign.muted)

                Picker(
                    "Model",
                    selection: Binding(
                        get: { selectedModelID(for: activeThread) },
                        set: { next in
                            Task {
                                await updateSelectedModel(next, for: activeThread)
                            }
                        }
                    )
                ) {
                    ForEach(modelOptions) { option in
                        Text(option.label).tag(option.id)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .disabled(isSending || modelOptions.isEmpty)

                Text(modelNote(for: activeThread))
                    .font(TealeDesign.monoSmall)
                    .foregroundStyle(TealeDesign.muted)
            }
        } else {
            Text("Creating your first thread...")
                .font(TealeDesign.monoSmall)
                .foregroundStyle(TealeDesign.muted)
        }
    }

    @ViewBuilder
    private var statusLine: some View {
        if !statusMessage.isEmpty {
            Text(statusMessage)
                .font(TealeDesign.monoSmall)
                .foregroundStyle(statusIsError ? TealeDesign.fail : TealeDesign.muted)
                .padding(.vertical, 2)
        }
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if visibleMessages.isEmpty,
                       streamingText.isEmpty,
                       interruptedDrafts[activeThread?.id ?? UUID()] == nil {
                        Text("Open a thread and ask Teale anything.")
                            .font(TealeDesign.monoSmall)
                            .foregroundStyle(TealeDesign.muted)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        ForEach(visibleMessages) { message in
                            CompanionHomeChatBubble(
                                fromUser: message.messageType == .text,
                                content: message.content
                            )
                            .id(message.id)
                        }

                        if let activeThread,
                           activeSendThreadID == activeThread.id,
                           (!streamingText.isEmpty || isSending) {
                            CompanionHomeChatBubble(
                                fromUser: false,
                                content: streamingText.isEmpty ? "Thinking..." : streamingText,
                                note: streamingText.isEmpty ? nil : "streaming"
                            )
                            .id("streaming")
                        }

                        if let activeThread,
                           let interrupted = interruptedDrafts[activeThread.id],
                           !interrupted.isEmpty,
                           activeSendThreadID != activeThread.id {
                            CompanionHomeChatBubble(
                                fromUser: false,
                                content: interrupted,
                                note: "interrupted"
                            )
                            .id("interrupted-\(activeThread.id.uuidString)")
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 260, maxHeight: 360)
            .padding(14)
            .background(Color(red: 0x02/255, green: 0x08/255, blue: 0x09/255))
            .overlay(Rectangle().stroke(TealeDesign.border, lineWidth: 1))
            .onChange(of: visibleMessages.count) { _, _ in
                scrollTranscript(proxy: proxy)
            }
            .onChange(of: streamingText) { _, _ in
                scrollTranscript(proxy: proxy)
            }
        }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("MESSAGE")
                .font(TealeDesign.monoSmall)
                .tracking(0.9)
                .foregroundStyle(TealeDesign.muted)

            TextEditor(text: $inputText)
                .font(TealeDesign.mono)
                .foregroundStyle(TealeDesign.text)
                .scrollContentBackground(.hidden)
                .frame(minHeight: 84, maxHeight: 120)
                .padding(10)
                .background(Color(red: 0x02/255, green: 0x08/255, blue: 0x09/255))
                .overlay(Rectangle().stroke(TealeDesign.border, lineWidth: 1))
                .disabled(isSending)

            HStack(spacing: 10) {
                Text("Threaded chat is local-first. Pick a model above to steer the route.")
                    .font(TealeDesign.monoSmall)
                    .foregroundStyle(TealeDesign.muted)
                Spacer(minLength: 8)
                TealeActionButton(title: "send", primary: true, disabled: sendDisabled) {
                    sendCurrentMessage()
                }
            }
        }
    }

    private var sendDisabled: Bool {
        inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || isSending
            || activeThread == nil
            || modelOptions.isEmpty
    }

    @MainActor
    private func ensureThreadReady() async {
        if threads.isEmpty {
            await createThread()
            return
        }

        if let active = chatService.activeConversation,
           active.type == .dm,
           !active.isArchived {
            if active.agentConfig.model == nil, let fallback = modelOptions.first?.id {
                await updateSelectedModel(fallback, for: active)
            }
            return
        }

        if let first = threads.first {
            await chatService.openConversation(first)
            if first.agentConfig.model == nil, let fallback = modelOptions.first?.id {
                await updateSelectedModel(fallback, for: first)
            }
        }
    }

    @MainActor
    private func createThread() async {
        let created = await chatService.createDM(
            with: UUID(),
            title: "New Thread",
            agentConfig: AgentConfig(
                model: modelOptions.first?.id,
                autoRespond: false,
                mentionOnly: false,
                persona: "assistant"
            )
        )
        if let created {
            await chatService.openConversation(created)
            statusMessage = ""
            statusIsError = false
        }
    }

    @MainActor
    private func closeThread(_ thread: Conversation) async {
        guard !isSending else { return }
        let fallback = threads.first(where: { $0.id != thread.id })
        interruptedDrafts.removeValue(forKey: thread.id)
        await chatService.leaveConversation(thread.id)
        if let fallback {
            await chatService.openConversation(fallback)
        } else {
            await createThread()
        }
        statusMessage = ""
        statusIsError = false
    }

    @MainActor
    private func openThread(_ thread: Conversation) async {
        guard !isSending else { return }
        await chatService.openConversation(thread)
        statusMessage = ""
        statusIsError = false
    }

    @MainActor
    private func updateSelectedModel(_ identifier: String, for thread: Conversation) async {
        guard !identifier.isEmpty else { return }
        var config = currentThread(thread.id)?.agentConfig ?? thread.agentConfig
        guard config.model != identifier else { return }
        config.model = identifier
        await chatService.updateConversation(
            id: thread.id,
            title: currentThread(thread.id)?.title ?? thread.title,
            agentConfig: config
        )
        statusMessage = ""
        statusIsError = false
    }

    private func selectedModelID(for thread: Conversation) -> String {
        if let chosen = currentThread(thread.id)?.agentConfig.model,
           modelOptions.contains(where: { $0.id == chosen }) {
            return chosen
        }
        return modelOptions.first?.id ?? ""
    }

    private func modelNote(for thread: Conversation) -> String {
        let chosen = selectedModelID(for: thread)
        return modelOptions.first(where: { $0.id == chosen })?.note
            ?? "Local is free on this Mac. Network models spend Teale credits."
    }

    private func currentThread(_ id: UUID) -> Conversation? {
        chatService.conversations.first(where: { $0.id == id })
    }

    private func sendCurrentMessage() {
        guard let thread = activeThread else { return }
        let content = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else { return }

        inputText = ""
        statusMessage = ""
        statusIsError = false
        interruptedDrafts[thread.id] = nil
        isSending = true
        activeSendThreadID = thread.id
        streamingText = ""

        Task {
            await sendMessage(content, in: thread)
        }
    }

    @MainActor
    private func sendMessage(_ content: String, in thread: Conversation) async {
        await chatService.openConversation(thread)

        let latestThread = currentThread(thread.id) ?? thread
        if latestThread.title == nil || latestThread.title == "New Thread" || latestThread.title == "New Conversation" {
            await chatService.updateConversation(
                id: latestThread.id,
                title: normalizedThreadTitle(content),
                agentConfig: latestThread.agentConfig
            )
        }

        await chatService.sendMessage(content)

        let requestMessages = chatService.activeMessages.compactMap(apiMessage)
        let modelID = selectedModelID(for: currentThread(thread.id) ?? thread)

        do {
            let reply = try await streamReply(messages: requestMessages, modelID: modelID)
            if !reply.isEmpty {
                await chatService.insertAIMessage(reply, conversationID: thread.id)
            }
            statusMessage = "Responded via \(shortModelLabel(modelID))."
            statusIsError = false
        } catch {
            if !streamingText.isEmpty {
                interruptedDrafts[thread.id] = streamingText
            }
            statusMessage = error.localizedDescription
            statusIsError = true
        }

        streamingText = ""
        activeSendThreadID = nil
        isSending = false
    }

    private func apiMessage(from message: DecryptedMessage) -> APIMessage? {
        switch message.messageType {
        case .text:
            return APIMessage(role: "user", content: message.content)
        case .aiResponse:
            return APIMessage(role: "assistant", content: message.content)
        default:
            return nil
        }
    }

    private func normalizedThreadTitle(_ text: String) -> String {
        let compact = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: " ")
        guard !compact.isEmpty else { return "New Thread" }
        if compact.count <= 32 { return compact }
        return String(compact.prefix(32)).trimmingCharacters(in: .whitespacesAndNewlines) + "..."
    }

    private func shortModelLabel(_ identifier: String) -> String {
        let last = identifier.split(separator: "/").last.map(String.init) ?? identifier
        return last.replacingOccurrences(of: "-", with: " ")
    }

    private func scrollTranscript(proxy: ScrollViewProxy) {
        withAnimation(.easeOut(duration: 0.15)) {
            if activeSendThreadID != nil {
                proxy.scrollTo("streaming", anchor: .bottom)
            } else if let last = visibleMessages.last {
                proxy.scrollTo(last.id, anchor: .bottom)
            }
        }
    }

    private func streamReply(messages: [APIMessage], modelID: String) async throws -> String {
        guard let url = URL(string: "http://127.0.0.1:\(appState.serverPort)/v1/chat/completions") else {
            throw CompanionHomeChatError.invalidResponse
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONEncoder().encode(
            ChatCompletionRequest(
                model: modelID,
                messages: messages,
                temperature: 0.7,
                maxTokens: 1024,
                stream: true
            )
        )

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw CompanionHomeChatError.invalidResponse
        }

        if http.statusCode != 200 {
            var errorBody = Data()
            for try await byte in bytes {
                errorBody.append(byte)
                if errorBody.count >= 4096 {
                    break
                }
            }
            if let apiError = try? JSONDecoder().decode(APIErrorResponse.self, from: errorBody) {
                throw CompanionHomeChatError.server(apiError.error.message)
            }
            let text = String(data: errorBody, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            throw CompanionHomeChatError.server(text?.isEmpty == false ? text! : "Chat request failed with HTTP \(http.statusCode).")
        }

        var assistantReply = ""
        for try await line in bytes.lines {
            guard line.hasPrefix("data: ") else { continue }
            let payload = String(line.dropFirst(6))
            if payload == "[DONE]" {
                break
            }
            guard let data = payload.data(using: .utf8) else { continue }
            if let apiError = try? JSONDecoder().decode(APIErrorResponse.self, from: data) {
                throw CompanionHomeChatError.server(apiError.error.message)
            }
            let chunk = try JSONDecoder().decode(ChatCompletionChunk.self, from: data)
            if let delta = chunk.choices.first?.delta.content, !delta.isEmpty {
                assistantReply.append(delta)
                await MainActor.run {
                    streamingText = assistantReply
                }
            }
        }

        return assistantReply.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private struct CompanionHomeModelOption: Identifiable, Equatable {
    let id: String
    let label: String
    let note: String
}

private struct CompanionHomeThreadChip: View {
    let title: String
    let active: Bool
    let disabled: Bool
    let onSelect: () -> Void
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onSelect) {
                Text(title)
                    .font(TealeDesign.monoSmall)
                    .foregroundStyle(active ? TealeDesign.text : TealeDesign.muted)
                    .lineLimit(1)
            }
            .buttonStyle(.plain)
            .disabled(disabled)

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(disabled ? TealeDesign.muted : TealeDesign.teale)
            }
            .buttonStyle(.plain)
            .disabled(disabled)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(active ? TealeDesign.cardStrong : TealeDesign.card)
        .overlay(
            Rectangle()
                .stroke(active ? TealeDesign.teale : TealeDesign.border, lineWidth: 1)
        )
    }
}

private struct CompanionHomeChatBubble: View {
    let fromUser: Bool
    let content: String
    var note: String? = nil

    var body: some View {
        HStack {
            if fromUser { Spacer(minLength: 40) }
            VStack(alignment: .leading, spacing: 6) {
                Text(content)
                    .font(TealeDesign.mono)
                    .foregroundStyle(TealeDesign.text)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let note, !note.isEmpty {
                    Text(note)
                        .font(TealeDesign.monoTiny)
                        .foregroundStyle(TealeDesign.muted)
                }
            }
            .padding(12)
            .background(fromUser ? TealeDesign.tealeDim.opacity(0.28) : TealeDesign.cardStrong)
            .overlay(
                Rectangle()
                    .stroke(fromUser ? TealeDesign.teale : TealeDesign.border, lineWidth: 1)
            )
            .frame(maxWidth: 560, alignment: .leading)
            if !fromUser { Spacer(minLength: 40) }
        }
    }
}

private enum CompanionHomeChatError: LocalizedError {
    case invalidResponse
    case server(String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "The local chat stream returned an invalid response."
        case .server(let message):
            return message
        }
    }
}
