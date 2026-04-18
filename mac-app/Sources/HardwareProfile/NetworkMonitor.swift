import Foundation
import Network
import SharedTypes

// MARK: - Network Monitor

@Observable
public final class NetworkMonitor: @unchecked Sendable {
    public private(set) var isConnected: Bool = true
    public private(set) var isExpensive: Bool = false  // cellular/hotspot
    public private(set) var isConstrained: Bool = false  // low data mode

    /// True when connected via Wi-Fi (not cellular/hotspot)
    public var isOnWiFi: Bool { isConnected && !isExpensive }
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.teale.network-monitor")

    public init() {
        startMonitoring()
    }

    deinit {
        monitor.cancel()
    }

    private func startMonitoring() {
        monitor.pathUpdateHandler = { [weak self] path in
            DispatchQueue.main.async {
                self?.isConnected = path.status == .satisfied
                self?.isExpensive = path.isExpensive
                self?.isConstrained = path.isConstrained
            }
        }
        monitor.start(queue: queue)
    }
}
