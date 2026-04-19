import Foundation

// MARK: - Auto Top-Up Scheduler

/// Periodically checks each group wallet the local user has auto-top-up rules for.
/// When a group's balance dips below the configured threshold, pushes a
/// contribution from the user's personal wallet (up to the daily cap).
@MainActor
public final class AutoTopUpScheduler {
    private weak var chatService: ChatService?
    private var task: Task<Void, Never>?
    /// Check cadence. 5 minutes is frequent enough for a "group is running out
    /// of credits" experience and cheap to run.
    public var interval: TimeInterval = 5 * 60

    public init(chatService: ChatService) {
        self.chatService = chatService
    }

    public func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(self?.interval ?? 300))
                await self?.runPass()
            }
        }
    }

    public func stop() {
        task?.cancel()
        task = nil
    }

    private func runPass() async {
        guard let chatService else { return }
        let walletStore = chatService.walletStore

        for conversation in chatService.conversations {
            guard let rule = walletStore.autoTopUpRule(for: conversation.id), rule.enabled else { continue }

            let balance = walletStore.balance(for: conversation.id)
            guard balance < rule.thresholdAmount else { continue }

            let alreadyToday = walletStore.autoContributedToday(for: conversation.id)
            let remaining = max(0, rule.dailyCap - alreadyToday)
            let desired = rule.topUpAmount
            let amount = min(desired, remaining)
            guard amount > 0.009 else { continue }

            let memo = "Auto top-up (balance was \(String(format: "%.2f", balance)))"
            let success = await chatService.contributeToGroupWallet(
                amount: amount,
                conversationID: conversation.id,
                memo: memo
            )
            if success {
                _ = walletStore.recordAutoContribution(amount: amount, conversationID: conversation.id)
            }
        }
    }
}
