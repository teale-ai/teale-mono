import Foundation
import SharedTypes
import CoreGraphics

// MARK: - User Activity Monitor

@Observable
public final class UserActivityMonitor: @unchecked Sendable {
    public private(set) var secondsSinceLastInput: TimeInterval = 0
    public private(set) var isUserActive: Bool = true
    private var timer: Timer?

    /// Threshold in seconds before considering user idle
    public var idleThreshold: TimeInterval = 120  // 2 minutes

    public init() {
        startMonitoring()
    }

    deinit {
        timer?.invalidate()
    }

    private func startMonitoring() {
        timer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            self?.checkActivity()
        }
    }

    private func checkActivity() {
        #if os(macOS)
        let interval = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .mouseMoved)
        let keyInterval = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .keyDown)
        secondsSinceLastInput = min(interval, keyInterval)
        isUserActive = secondsSinceLastInput < idleThreshold
        #else
        isUserActive = true
        #endif
    }
}
