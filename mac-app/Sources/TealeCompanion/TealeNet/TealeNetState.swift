#if os(iOS)
import Foundation
import Observation
#if os(iOS)
import UIKit
#endif

/// Observable glue between the iOS UI and the gateway clients. All mutation
/// happens on the main actor; work is dispatched to background through the
/// underlying clients.
@MainActor
@Observable
final class TealeNetState {

    // MARK: - Public observable state

    let deviceID: String = GatewayIdentity.shared.deviceID
    var groups: [GwGroupSummary] = []
    var activeGroupID: String?
    var messages: [GwGroupMessage] = []
    var groupLatestMessage: [String: GwGroupMessage] = [:]
    var unreadGroupIDs: Set<String> = []
    var isSending: Bool = false
    var isAITyping: Bool = false
    var isLoadingGroups: Bool = false
    var lastError: String?
    var preferredModel: String = "meta-llama/llama-3.1-8b-instruct"
    var username: String = ""

    // Wallet
    var balance: GwBalance?
    var transactions: [GwLedgerEntry] = []

    // MARK: - Clients

    let auth: GatewayAuthClient
    let groupsClient: GatewayGroupsClient
    let chatClient: GatewayChatClient
    let walletClient: GatewayWalletClient

    private var pollTask: Task<Void, Never>?
    private var listRefreshTask: Task<Void, Never>?
    private var greetedGroupIDs: Set<String> = []

    init() {
        let auth = GatewayAuthClient()
        self.auth = auth
        self.groupsClient = GatewayGroupsClient(auth: auth)
        self.chatClient = GatewayChatClient(auth: auth)
        self.walletClient = GatewayWalletClient(auth: auth)
    }

    // MARK: - Lifecycle

    /// Kicks off the ed25519 bearer exchange + pulls initial groups & wallet.
    /// Safe to call repeatedly — duplicate work is deduped by the clients.
    func bootstrap() {
        Task {
            do { _ = try await auth.bearer() }
            catch { self.lastError = "auth: \(error)" }
            await refreshAll()
        }
        // Start a background refresh loop so the Teale tab stays fresh while
        // the user is idle on it.
        listRefreshTask?.cancel()
        listRefreshTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                if activeGroupID == nil { await refreshAll() }
            }
        }
    }

    func refreshAll() async {
        await refreshGroups()
        await refreshWallet()
    }

    // MARK: - Groups

    func refreshGroups() async {
        isLoadingGroups = true
        defer { isLoadingGroups = false }
        do {
            let fresh = try await groupsClient.listMine()
            groups = fresh
            // Fetch each group's last message so the list preview isn't blank.
            await withTaskGroup(of: (String, GwGroupMessage?).self) { tg in
                for g in fresh {
                    tg.addTask { [groupsClient] in
                        let last = try? await groupsClient.listMessages(
                            groupID: g.groupID, since: 0, limit: 1
                        ).last
                        return (g.groupID, last)
                    }
                }
                for await (gid, last) in tg {
                    if let last { groupLatestMessage[gid] = last }
                }
            }
        } catch { lastError = "groups: \(error)" }
    }

    func createGroup(title: String, then select: Bool = true) {
        Task {
            do {
                let g = try await groupsClient.create(title: title)
                groups.insert(g, at: 0)
                #if os(iOS)
                Haptics.success()
                #endif
                if select { openGroup(g.groupID) }
            } catch {
                lastError = "create: \(error)"
                #if os(iOS)
                Haptics.error()
                #endif
            }
        }
    }

    func addMember(groupID: String, deviceID: String, then onDone: @escaping () -> Void = {}) {
        Task {
            do {
                _ = try await groupsClient.addMember(groupID: groupID, deviceID: deviceID)
                #if os(iOS)
                Haptics.success()
                #endif
                await refreshGroups()
                onDone()
            } catch {
                lastError = "invite: \(error)"
                #if os(iOS)
                Haptics.error()
                #endif
            }
        }
    }

    // MARK: - Group chat

    func openGroup(_ groupID: String) {
        guard activeGroupID != groupID else { return }
        activeGroupID = groupID
        messages = []
        unreadGroupIDs.remove(groupID)
        pollTask?.cancel()
        pollTask = Task {
            var firstFetch = true
            while !Task.isCancelled && activeGroupID == groupID {
                do {
                    let since = messages.last?.timestamp ?? 0
                    let newer = try await groupsClient.listMessages(groupID: groupID, since: since)
                    if !newer.isEmpty {
                        let existing = Set(messages.map(\.id))
                        let adds = newer.filter { !existing.contains($0.id) }
                        if !adds.isEmpty {
                            messages = (messages + adds).sorted { $0.timestamp < $1.timestamp }
                            if let last = adds.last {
                                groupLatestMessage[groupID] = last
                            }
                        }
                    }
                    if firstFetch {
                        firstFetch = false
                        // Proactive greet: if the group has zero messages yet
                        // and we haven't greeted yet, have Teale introduce
                        // itself and offer help.
                        if messages.isEmpty && !greetedGroupIDs.contains(groupID) {
                            greetedGroupIDs.insert(groupID)
                            await sendGreeting(groupID: groupID)
                        }
                    }
                } catch {
                    // swallow; next tick will retry
                }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    func leaveGroup() {
        activeGroupID = nil
        pollTask?.cancel()
        pollTask = nil
        messages = []
    }

    /// Post a human message. Triggers an AI reply when the message looks
    /// like a question, a planning prompt, or mentions @teale.
    func send(groupID: String, text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isSending else { return }
        isSending = true
        #if os(iOS)
        Haptics.tap()
        #endif
        Task {
            defer { isSending = false }
            do {
                let posted = try await groupsClient.postMessage(groupID: groupID, content: trimmed)
                if !messages.contains(where: { $0.id == posted.id }) {
                    messages = (messages + [posted]).sorted { $0.timestamp < $1.timestamp }
                }
            } catch {
                lastError = "send: \(error)"
                #if os(iOS)
                Haptics.error()
                #endif
                return
            }

            if shouldAIReply(to: trimmed) {
                await replyFromAI(groupID: groupID, latest: trimmed)
            }
        }
    }

    /// Explicit "nudge Teale" button — user can call the AI in without
    /// posting a prose message first.
    func nudgeAI(groupID: String) {
        Task {
            await replyFromAI(groupID: groupID, latest: "Given the conversation so far, what do you think we should do next? One concrete suggestion, one sentence.")
        }
    }

    // MARK: - Wallet

    func refreshWallet() async {
        async let bal = (try? await walletClient.balance()) as GwBalance?
        async let tx = (try? await walletClient.transactions(limit: 50)) as [GwLedgerEntry]?
        self.balance = await bal
        if let t = await tx { self.transactions = t }
    }

    // MARK: - Clipboard / invite

    func copyDeviceIDToClipboard() {
        #if os(iOS)
        UIPasteboard.general.string = deviceID
        Haptics.click()
        #endif
    }

    // MARK: - AI triggers

    private func shouldAIReply(to text: String) -> Bool {
        if text.localizedCaseInsensitiveContains("@teale") { return true }
        if text.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("?") { return true }
        let lower = text.lowercased()
        let planningHints = [
            "let's ", "lets ", "should we", "what about", "any ideas",
            "recommend", "suggestion", "anyone know", "anybody know",
            "where should", "when should", "what should", "how should",
            "pick a", "plan ", "planning ",
        ]
        return planningHints.contains { lower.contains($0) }
    }

    private func replyFromAI(groupID: String, latest: String) async {
        isAITyping = true
        defer { isAITyping = false }
        let system = GwChatMessage(role: "system", content: Self.aiSystemPrompt)
        let history: [GwChatMessage] = messages.suffix(20).map { m in
            let role = (m.type == "ai") ? "assistant" : "user"
            return GwChatMessage(role: role, content: m.content)
        }
        var context = [system]
        context.append(contentsOf: history)
        context.append(GwChatMessage(role: "user", content: latest))
        await postAiReply(groupID: groupID, context: context)
    }

    private func sendGreeting(groupID: String) async {
        isAITyping = true
        defer { isAITyping = false }
        let title = groups.first { $0.groupID == groupID }?.title ?? "this group"
        let priming = [
            GwChatMessage(role: "system", content: Self.aiSystemPrompt),
            GwChatMessage(
                role: "user",
                content: "This group is called '\(title)'. Introduce yourself in one short sentence and suggest one concrete way you can help — don't list options, just pick one."
            ),
        ]
        await postAiReply(groupID: groupID, context: priming)
    }

    private func postAiReply(groupID: String, context: [GwChatMessage]) async {
        do {
            let reply = try await chatClient.completeOnce(model: preferredModel, messages: context)
            guard !reply.isEmpty else { return }
            let posted = try await groupsClient.postMessage(
                groupID: groupID, content: reply, type: "ai"
            )
            if !messages.contains(where: { $0.id == posted.id }) {
                messages = (messages + [posted]).sorted { $0.timestamp < $1.timestamp }
            }
        } catch {
            lastError = "teale: \(error)"
        }
    }

    static let aiSystemPrompt =
        "You are Teale, an AI participant in a group chat with human users. " +
        "Keep replies short (1–3 sentences) and helpful. Be proactive: when " +
        "someone asks a question or the group is planning something, offer a " +
        "concrete, opinionated suggestion rather than a list of options. " +
        "Don't greet every turn — only on your first message. Respond in the " +
        "same language as the user."
}
#endif
