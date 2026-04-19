import Foundation
import SharedTypes

// MARK: - Weighted Fair Queuing Request Scheduler

/// Schedules inference requests using Weighted Fair Queuing (WFQ).
/// PTN requests get priority weight over WWTN requests, but when
/// one queue is empty, the other gets 100% of capacity — zero idle RAM.
public actor RequestScheduler {

    /// A queued inference request with metadata for scheduling.
    public struct QueuedRequest: Sendable {
        public var request: ChatCompletionRequest
        public var source: RequestSource
        public var bidAmount: Double?  // WWTN bid in USDC (higher = higher priority within WWTN)
        public var enqueuedAt: Date
        public var continuation: CheckedContinuation<Void, Error>

        public init(
            request: ChatCompletionRequest,
            source: RequestSource,
            bidAmount: Double? = nil,
            continuation: CheckedContinuation<Void, Error>
        ) {
            self.request = request
            self.source = source
            self.bidAmount = bidAmount
            self.enqueuedAt = Date()
            self.continuation = continuation
        }
    }

    /// Where a request originated from.
    public enum RequestSource: Sendable {
        case local              // On-device, always immediate
        case lan                // LAN cluster peer
        case ptn(String)        // PTN member (ptnID)
        case wwtn               // Open WWTN marketplace
    }

    /// WFQ weights — configurable per PTN.
    private var ptnWeight: Double
    private var wwtnWeight: Double

    /// Virtual time trackers for WFQ.
    private var ptnVirtualTime: Double = 0
    private var wwtnVirtualTime: Double = 0

    /// Request queues.
    private var ptnQueue: [QueuedRequest] = []
    private var wwtnQueue: [QueuedRequest] = []

    /// Number of concurrent inference slots available.
    private let maxConcurrent: Int
    private var activeCount: Int = 0

    public init(ptnWeight: Double = 0.7, wwtnWeight: Double = 0.3, maxConcurrent: Int = 1) {
        self.ptnWeight = ptnWeight
        self.wwtnWeight = wwtnWeight
        self.maxConcurrent = maxConcurrent
    }

    /// Update WFQ weights (e.g., PTN admin configures 90/10 split).
    public func setWeights(ptn: Double, wwtn: Double) {
        self.ptnWeight = ptn
        self.wwtnWeight = wwtn
    }

    /// Enqueue a request. Suspends until the request is scheduled for execution.
    public func enqueue(
        request: ChatCompletionRequest,
        source: RequestSource,
        bidAmount: Double? = nil
    ) async throws {
        // Local and LAN requests bypass the queue entirely
        switch source {
        case .local, .lan:
            return
        default:
            break
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let queued = QueuedRequest(
                request: request,
                source: source,
                bidAmount: bidAmount,
                continuation: continuation
            )

            switch source {
            case .ptn:
                ptnQueue.append(queued)
            case .wwtn:
                // WWTN: sort by bid amount (highest first)
                wwtnQueue.append(queued)
                wwtnQueue.sort { ($0.bidAmount ?? 0) > ($1.bidAmount ?? 0) }
            case .local, .lan:
                break // Already handled above
            }

            scheduleNext()
        }
    }

    /// Signal that an inference request has completed, freeing a slot.
    public func complete() {
        activeCount = max(0, activeCount - 1)
        scheduleNext()
    }

    /// Current queue depths for monitoring.
    public var queueStatus: (ptn: Int, wwtn: Int, active: Int) {
        (ptnQueue.count, wwtnQueue.count, activeCount)
    }

    // MARK: - WFQ Scheduling

    private func scheduleNext() {
        while activeCount < maxConcurrent {
            guard let next = dequeueNext() else { return }
            activeCount += 1
            next.continuation.resume()
        }
    }

    /// WFQ dequeue: pick from the queue with the lower virtual time.
    /// When one queue is empty, the other gets all capacity.
    private func dequeueNext() -> QueuedRequest? {
        let hasPTN = !ptnQueue.isEmpty
        let hasWWTN = !wwtnQueue.isEmpty

        guard hasPTN || hasWWTN else { return nil }

        // If only one queue has requests, use it (zero idle capacity)
        if hasPTN && !hasWWTN {
            let req = ptnQueue.removeFirst()
            ptnVirtualTime += 1.0 / ptnWeight
            return req
        }
        if hasWWTN && !hasPTN {
            let req = wwtnQueue.removeFirst()
            wwtnVirtualTime += 1.0 / wwtnWeight
            return req
        }

        // Both queues have requests — pick the one with lower virtual time
        if ptnVirtualTime <= wwtnVirtualTime {
            let req = ptnQueue.removeFirst()
            ptnVirtualTime += 1.0 / ptnWeight
            return req
        } else {
            let req = wwtnQueue.removeFirst()
            wwtnVirtualTime += 1.0 / wwtnWeight
            return req
        }
    }
}
