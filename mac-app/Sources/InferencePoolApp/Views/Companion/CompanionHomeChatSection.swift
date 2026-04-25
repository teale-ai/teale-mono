import SwiftUI
import AppCore
import SharedTypes
import ChatKit
import ModelManager
import GatewayKit

struct CompanionHomeChatSection: View {
    @Environment(AppState.self) private var appState
    @Environment(CompanionGatewayState.self) private var gatewayState

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
            let quotedPricing = gatewayState.networkModels.first(where: { $0.id == identifier })
            if seen.insert(identifier).inserted {
                options.append(
                    CompanionHomeModelOption(
                        id: identifier,
                        label: "FREE - \(appState.companionShortModelLabel(identifier))",
                        note: appState.companionText("chat.localFree", fallback: "Local is free on this Mac."),
                        billedLocally: true,
                        promptUSDPerToken: quotedPricing?.promptUSDPerToken,
                        completionUSDPerToken: quotedPricing?.completionUSDPerToken
                    )
                )
            }
        }

        for model in gatewayState.networkModels {
            guard seen.insert(model.id).inserted else { continue }
            let pricingLabel = appState.companionDisplayPricePerMillionLabel(
                promptUSDPerToken: model.promptUSDPerToken,
                completionUSDPerToken: model.completionUSDPerToken
            )
            options.append(
                CompanionHomeModelOption(
                    id: model.id,
                    label: [pricingLabel, appState.companionShortModelLabel(model.id)]
                        .compactMap { $0 }
                        .joined(separator: " - "),
                    note: appState.companionText(
                        "chat.networkSpend",
                        fallback: "Network models spend {{unit}}. Device bearer is used automatically.",
                        replacements: ["unit": appState.companionDisplaySpendUnitLabel]
                    ),
                    billedLocally: false,
                    promptUSDPerToken: model.promptUSDPerToken,
                    completionUSDPerToken: model.completionUSDPerToken
                )
            )
        }

        return options
    }

    var body: some View {
        TealeSection(prompt: appState.companionText("home.thread", fallback: "thread")) {
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
        .onChange(of: modelOptions.map(\.id)) { _, _ in
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

                TealeActionButton(title: appState.companionText("chat.newThread", fallback: "new thread"), primary: false, disabled: isSending) {
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
                Text(appState.companionText("chat.model", fallback: "MODEL"))
                    .font(TealeDesign.monoSmall)
                    .tracking(0.9)
                    .foregroundStyle(TealeDesign.muted)

                Picker(
                    appState.companionText("chat.model", fallback: "MODEL"),
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
            Text(appState.companionText("chat.creatingThread", fallback: "Creating your first thread..."))
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
                        Text(appState.companionText("chat.empty", fallback: "Open a thread and ask Teale anything."))
                            .font(TealeDesign.monoSmall)
                            .foregroundStyle(TealeDesign.muted)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        ForEach(Array(visibleMessages.enumerated()), id: \.element.id) { index, message in
                            CompanionHomeChatBubble(
                                fromUser: message.messageType == .text,
                                content: message.content,
                                meta: bubbleMeta(for: message, at: index)
                            )
                            .id(message.id)
                        }

                        if let activeThread,
                           activeSendThreadID == activeThread.id,
                           (!streamingText.isEmpty || isSending) {
                            CompanionHomeChatBubble(
                                fromUser: false,
                                content: streamingText.isEmpty
                                    ? appState.companionText("chat.thinking", fallback: "Thinking...")
                                    : streamingText,
                                note: streamingText.isEmpty ? nil : appState.companionText("chat.streaming", fallback: "streaming")
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
                                note: appState.companionText("chat.interrupted", fallback: "interrupted")
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
            Text(appState.companionText("chat.message", fallback: "MESSAGE"))
                .font(TealeDesign.monoSmall)
                .tracking(0.9)
                .foregroundStyle(TealeDesign.muted)

            TextField(
                "",
                text: $inputText,
                prompt: Text(appState.companionText("chat.messagePlaceholder", fallback: "Type a message")),
                axis: .vertical
            )
                .textFieldStyle(.plain)
                .submitLabel(.send)
                .onSubmit {
                    sendCurrentMessage()
                }
                .font(TealeDesign.mono)
                .foregroundStyle(TealeDesign.text)
                .frame(minHeight: 84, maxHeight: 120)
                .padding(10)
                .background(Color(red: 0x02/255, green: 0x08/255, blue: 0x09/255))
                .overlay(Rectangle().stroke(TealeDesign.border, lineWidth: 1))
                .disabled(isSending)

            HStack(spacing: 10) {
                Text(appState.companionText("chat.hint", fallback: "Threaded chat is local-first. Pick a model above to steer the route."))
                    .font(TealeDesign.monoSmall)
                    .foregroundStyle(TealeDesign.muted)
                Spacer(minLength: 8)
                TealeActionButton(title: appState.companionText("chat.send", fallback: "send"), primary: true, disabled: sendDisabled) {
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
            title: appState.companionText("chat.newThreadTitle", fallback: "New Thread"),
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
            ?? appState.companionText("chat.localFree", fallback: "Local is free on this Mac.")
    }

    private func selectedModelOption(for thread: Conversation) -> CompanionHomeModelOption? {
        let chosen = selectedModelID(for: thread)
        return modelOptions.first(where: { $0.id == chosen }) ?? modelOptions.first
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

        let selectedOption = selectedModelOption(for: currentThread(thread.id) ?? thread)
        let modelID = selectedOption?.id ?? selectedModelID(for: currentThread(thread.id) ?? thread)
        let requestMessages = chatService.activeMessages.compactMap(apiMessage) + [APIMessage(role: "user", content: content)]

        await chatService.sendMessage(content)

        do {
            let result = try await streamReply(messages: requestMessages, modelID: modelID)
            if !result.text.isEmpty {
                await chatService.insertAIMessage(
                    result.text,
                    conversationID: thread.id,
                    metadata: aiResponseMetadata(for: result, option: selectedOption, modelID: modelID)
                )
            }
            statusMessage = appState.companionText(
                "chat.respondedVia",
                fallback: "Responded via {{model}}.",
                replacements: ["model": appState.companionShortModelLabel(modelID)]
            )
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
        guard !compact.isEmpty else { return appState.companionText("chat.newThreadTitle", fallback: "New Thread") }
        if compact.count <= 32 { return compact }
        return String(compact.prefix(32)).trimmingCharacters(in: .whitespacesAndNewlines) + "..."
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

    private func streamReply(messages: [APIMessage], modelID: String) async throws -> CompanionHomeStreamResult {
        guard let url = URL(string: "http://127.0.0.1:\(appState.serverPort)/v1/chat/completions") else {
            throw CompanionHomeChatError.invalidResponse
        }

        let localAPIKey = await localAPIKeyForChat()
        await ensureGatewayBearerForChat()

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(localAPIKey)", forHTTPHeaderField: "Authorization")
        var chatRequest = ChatCompletionRequest(
            model: modelID,
            messages: messages,
            temperature: 0.7,
            maxTokens: 1024,
            stream: true
        )
        chatRequest.streamOptions = ["include_usage": true]
        request.httpBody = try JSONEncoder().encode(chatRequest)

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
        var promptTokens = estimatedPromptTokens(for: messages)
        var promptTokensEstimated = true
        var completionTokens = 0
        var completionTokensEstimated = true
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
            if let usage = chunk.usage {
                if usage.promptTokens > 0 {
                    promptTokens = usage.promptTokens
                    promptTokensEstimated = false
                }
                if usage.completionTokens >= 0 {
                    completionTokens = usage.completionTokens
                    completionTokensEstimated = false
                }
            }
            if let delta = chunk.choices.first?.delta.content, !delta.isEmpty {
                assistantReply.append(delta)
                if completionTokensEstimated {
                    completionTokens = estimatedTokens(for: assistantReply)
                }
                await MainActor.run {
                    streamingText = assistantReply
                }
            }
        }

        let trimmed = assistantReply.trimmingCharacters(in: .whitespacesAndNewlines)
        if completionTokens == 0, !trimmed.isEmpty {
            completionTokens = estimatedTokens(for: trimmed)
            completionTokensEstimated = true
        }

        return CompanionHomeStreamResult(
            text: trimmed,
            promptTokens: promptTokens,
            promptTokensEstimated: promptTokensEstimated,
            completionTokens: completionTokens,
            completionTokensEstimated: completionTokensEstimated
        )
    }

    private func localAPIKeyForChat() async -> String {
        if let existing = await appState.apiKeyStore.allKeys().first(where: \.isActive)?.key {
            return existing
        }
        return await appState.apiKeyStore.generateKey(name: "Companion Home Chat").key
    }

    private func ensureGatewayBearerForChat() async {
        guard appState.gatewayAPIKey.isEmpty else { return }
        let auth = GatewayAuthClient(baseURL: companionGatewayRootURL(for: appState.gatewayFallbackURL))
        guard let bearer = try? await auth.bearer(), !bearer.isEmpty else { return }
        await MainActor.run {
            appState.gatewayAPIKey = bearer
        }
    }

    private func bubbleMeta(for message: DecryptedMessage, at index: Int) -> CompanionHomeBubbleMeta? {
        switch message.messageType {
        case .text:
            guard let meta = pairedAIResponseMetadata(after: index) else { return nil }
            return makeBubbleMeta(
                isInput: true,
                tokenCount: meta.tokensPrompt,
                tokenEstimated: meta.tokensPromptEstimated ?? false,
                quotedCostCredits: meta.quotedPromptCostCredits,
                billedCostCredits: meta.billedPromptCostCredits,
                costIsFree: meta.billedLocally ?? false
            )
        case .aiResponse:
            guard let meta = aiResponseMetadata(from: message) else { return nil }
            return makeBubbleMeta(
                isInput: false,
                tokenCount: meta.tokensCompletion,
                tokenEstimated: meta.tokensCompletionEstimated ?? false,
                quotedCostCredits: meta.quotedCompletionCostCredits,
                billedCostCredits: meta.billedCompletionCostCredits,
                costIsFree: meta.billedLocally ?? false
            )
        default:
            return nil
        }
    }

    private func pairedAIResponseMetadata(after index: Int) -> MessageMetadata.AIResponseMeta? {
        let start = visibleMessages.index(after: index)
        guard start < visibleMessages.endIndex else { return nil }
        for following in visibleMessages.suffix(from: start) {
            switch following.messageType {
            case .aiResponse:
                return aiResponseMetadata(from: following)
            case .text:
                return nil
            default:
                continue
            }
        }
        return nil
    }

    private func aiResponseMetadata(from message: DecryptedMessage) -> MessageMetadata.AIResponseMeta? {
        guard case .ai(let meta)? = message.metadata else { return nil }
        return meta
    }

    private func makeBubbleMeta(
        isInput: Bool,
        tokenCount: Int?,
        tokenEstimated: Bool,
        quotedCostCredits: Int64?,
        billedCostCredits: Int64?,
        costIsFree: Bool
    ) -> CompanionHomeBubbleMeta? {
        guard let tokenCount, tokenCount > 0 else { return nil }
        let tokenLabel = appState.companionText(
            isInput ? (tokenEstimated ? "chat.tokens.inputApprox" : "chat.tokens.input")
                    : (tokenEstimated ? "chat.tokens.outputApprox" : "chat.tokens.output"),
            fallback: isInput
                ? (tokenEstimated ? "~{{count}} input tokens" : "{{count}} input tokens")
                : (tokenEstimated ? "~{{count}} output tokens" : "{{count}} output tokens"),
            replacements: ["count": String(tokenCount)]
        )
        return CompanionHomeBubbleMeta(
            tokenText: tokenLabel,
            quotedCostText: quotedCostCredits.map { appState.companionDisplayAmountString(credits: $0, includeUnit: true) },
            billedCostText: costIsFree ? nil : billedCostCredits.map { appState.companionDisplayAmountString(credits: $0, includeUnit: true) },
            isFree: costIsFree
        )
    }

    private func aiResponseMetadata(
        for result: CompanionHomeStreamResult,
        option: CompanionHomeModelOption?,
        modelID: String
    ) -> MessageMetadata {
        let quotedPrompt = quotedCostCredits(tokens: result.promptTokens, usdPerToken: option?.promptUSDPerToken)
        let quotedCompletion = quotedCostCredits(tokens: result.completionTokens, usdPerToken: option?.completionUSDPerToken)
        let billedLocally = option?.billedLocally ?? false

        return .ai(
            .init(
                model: modelID,
                tokensPrompt: result.promptTokens,
                tokensCompletion: result.completionTokens,
                cost: nil,
                quotedPromptCostCredits: quotedPrompt,
                billedPromptCostCredits: billedLocally ? 0 : quotedPrompt,
                quotedCompletionCostCredits: quotedCompletion,
                billedCompletionCostCredits: billedLocally ? 0 : quotedCompletion,
                billedLocally: billedLocally,
                tokensPromptEstimated: result.promptTokensEstimated,
                tokensCompletionEstimated: result.completionTokensEstimated
            )
        )
    }

    private func quotedCostCredits(tokens: Int, usdPerToken: Double?) -> Int64? {
        guard tokens > 0, let usdPerToken else { return nil }
        let credits = Double(tokens) * usdPerToken * CompanionDisplayUnit.creditsPerUSD
        return Int64(credits.rounded())
    }

    private func estimatedPromptTokens(for messages: [APIMessage]) -> Int {
        let promptBytes = messages.reduce(into: 0) { partialResult, message in
            partialResult += message.content.lengthOfBytes(using: .utf8)
        }
        return max(1, Int(ceil(Double(promptBytes) / 4.0)) + 16)
    }

    private func estimatedTokens(for text: String) -> Int {
        let bytes = text.lengthOfBytes(using: .utf8)
        guard bytes > 0 else { return 0 }
        return max(1, Int(ceil(Double(bytes) / 4.0)))
    }
}

private struct CompanionHomeModelOption: Identifiable, Equatable {
    let id: String
    let label: String
    let note: String
    let billedLocally: Bool
    let promptUSDPerToken: Double?
    let completionUSDPerToken: Double?
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
    var meta: CompanionHomeBubbleMeta? = nil
    var note: String? = nil

    var body: some View {
        HStack {
            if fromUser { Spacer(minLength: 40) }
            VStack(alignment: .leading, spacing: 6) {
                Text(content)
                    .font(TealeDesign.mono)
                    .foregroundStyle(TealeDesign.text)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let meta {
                    CompanionHomeChatBubbleMetaView(meta: meta)
                }
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

private struct CompanionHomeBubbleMeta: Equatable {
    let tokenText: String
    let quotedCostText: String?
    let billedCostText: String?
    let isFree: Bool
}

private struct CompanionHomeStreamResult {
    let text: String
    let promptTokens: Int
    let promptTokensEstimated: Bool
    let completionTokens: Int
    let completionTokensEstimated: Bool
}

private struct CompanionHomeChatBubbleMetaView: View {
    let meta: CompanionHomeBubbleMeta

    var body: some View {
        HStack(spacing: 0) {
            Text(meta.tokenText)
            if meta.quotedCostText != nil || meta.billedCostText != nil || meta.isFree {
                Text(" · ")
                if meta.isFree {
                    if let quotedCostText = meta.quotedCostText, !quotedCostText.isEmpty {
                        Text(quotedCostText)
                            .strikethrough()
                            .foregroundStyle(TealeDesign.muted)
                        Text(" ")
                    }
                    Text("FREE")
                        .foregroundStyle(TealeDesign.teale)
                } else if let billedCostText = meta.billedCostText, !billedCostText.isEmpty {
                    Text(billedCostText)
                }
            }
        }
        .font(TealeDesign.monoTiny)
        .foregroundStyle(TealeDesign.muted)
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
