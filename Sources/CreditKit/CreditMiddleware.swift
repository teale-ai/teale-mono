import Foundation
import SharedTypes

// MARK: - Errors

/// Error thrown when the user does not have enough credits for a remote request.
public struct InsufficientCreditsError: Error, CustomStringConvertible {
    public let required: CreditAmount
    public let available: CreditAmount

    public init(required: CreditAmount, available: CreditAmount) {
        self.required = required
        self.available = available
    }

    public var description: String {
        "Insufficient credits: need \(required), have \(available)"
    }
}

// MARK: - CreditTracker

/// Helper that counts tokens flowing through an AsyncThrowingStream without consuming it (tee pattern).
public struct CreditTracker: Sendable {

    /// Wraps a stream to count the tokens passing through it, returning a new stream and a token count accessor.
    /// The token count is accumulated in a Sendable actor.
    public static func tracking(
        stream: AsyncThrowingStream<ChatCompletionChunk, Error>
    ) -> (stream: AsyncThrowingStream<ChatCompletionChunk, Error>, counter: TokenCounter) {
        let counter = TokenCounter()

        let trackedStream = AsyncThrowingStream<ChatCompletionChunk, Error> { continuation in
            let task = Task {
                do {
                    for try await chunk in stream {
                        // Count tokens in this chunk (each non-nil content delta is roughly 1 token)
                        for choice in chunk.choices {
                            if choice.delta.content != nil {
                                await counter.increment()
                            }
                        }
                        continuation.yield(chunk)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }

        return (trackedStream, counter)
    }
}

/// Thread-safe token counter.
public actor TokenCounter {
    public private(set) var count: Int = 0

    public init() {}

    public func increment() {
        count += 1
    }

    public func getCount() -> Int {
        count
    }
}

// MARK: - CreditAwareProvider

/// An InferenceProvider wrapper that automatically tracks credits for remote inference.
public actor CreditAwareProvider: InferenceProvider {
    private let wrapped: any InferenceProvider
    private let wallet: CreditWallet
    private let isRemote: Bool
    private let peerID: String?

    /// - Parameters:
    ///   - provider: The underlying inference provider to wrap.
    ///   - wallet: The credit wallet to record transactions against.
    ///   - isRemote: Whether this provider represents a remote peer (costs credits) vs local (free).
    ///   - peerID: Optional peer node ID for transaction records.
    public init(
        provider: any InferenceProvider,
        wallet: CreditWallet,
        isRemote: Bool = false,
        peerID: String? = nil
    ) {
        self.wrapped = provider
        self.wallet = wallet
        self.isRemote = isRemote
        self.peerID = peerID
    }

    public var status: EngineStatus {
        get async { await wrapped.status }
    }

    public var loadedModel: ModelDescriptor? {
        get async { await wrapped.loadedModel }
    }

    public func loadModel(_ descriptor: ModelDescriptor) async throws {
        try await wrapped.loadModel(descriptor)
    }

    public func unloadModel() async {
        await wrapped.unloadModel()
    }

    public nonisolated func generate(request: ChatCompletionRequest) -> AsyncThrowingStream<ChatCompletionChunk, Error> {
        // We need to capture self properties before creating the stream
        let wrapped = self.wrapped
        let wallet = self.wallet
        let isRemote = self.isRemote
        let peerID = self.peerID

        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    // Check balance before remote requests
                    if isRemote {
                        let balance = await wallet.currentBalance()
                        if balance < CreditPricing.minimumBalanceForRemote {
                            throw InsufficientCreditsError(
                                required: CreditPricing.minimumBalanceForRemote,
                                available: balance
                            )
                        }
                    }

                    let innerStream = wrapped.generate(request: request)
                    let (tracked, counter) = CreditTracker.tracking(stream: innerStream)

                    // Get the model for pricing
                    let model = await wrapped.loadedModel

                    for try await chunk in tracked {
                        continuation.yield(chunk)
                    }

                    // After stream completes, record credits
                    if let model = model {
                        let tokenCount = await counter.getCount()
                        if tokenCount > 0 {
                            if isRemote {
                                // We consumed remote inference — record spending
                                await wallet.recordSpending(tokens: tokenCount, model: model, peer: peerID)
                            }
                            // Note: Earning is recorded on the serving side, not here
                        }
                    }

                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    /// Record earning when we serve a request for a peer.
    public func recordServing(tokens: Int, model: ModelDescriptor, peer: String?) async {
        await wallet.recordEarning(tokens: tokens, model: model, peer: peer)
    }
}
