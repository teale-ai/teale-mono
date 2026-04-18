import Foundation
import SharedTypes
import HardwareProfile
import InferenceEngine

#if canImport(Darwin)
import Darwin
#endif

// MARK: - Resource Governor

/// Enforces resource limits for SDK contribution.
/// Goes beyond AdaptiveThrottler by monitoring actual available memory
/// to protect the host app from resource starvation.
public actor ResourceGovernor {
    private let options: ContributionOptions
    private let hardware: HardwareCapability
    private let throttler: AdaptiveThrottler
    private var activeRequests: Int = 0

    /// Minimum memory (bytes) to keep free for the host app
    private let hostAppReserveBytes: UInt64 = 512 * 1024 * 1024  // 512 MB

    public init(options: ContributionOptions, hardware: HardwareCapability, throttler: AdaptiveThrottler) {
        self.options = options
        self.hardware = hardware
        self.throttler = throttler
    }

    /// Maximum RAM (GB) the SDK is allowed to use for models
    public var maxRAMGB: Double {
        let availableForModels = hardware.availableRAMForModelsGB
        switch options.maxRAMContribution {
        case .percent(let pct):
            return availableForModels * (Double(pct) / 100.0)
        case .absoluteGB(let gb):
            return min(gb, availableForModels)
        }
    }

    /// Whether the SDK should accept new inference work right now
    public func shouldAcceptWork() -> Bool {
        // Check throttler
        guard throttler.shouldAllowNetworkContribution else { return false }

        // Check concurrent request limit
        guard activeRequests < options.maxConcurrentRequests else { return false }

        // Check real-time memory pressure
        guard availableMemoryBytes() > hostAppReserveBytes else { return false }

        return true
    }

    /// Whether a model can be loaded within the SDK's RAM budget
    public func canLoadModel(_ descriptor: ModelDescriptor) -> Bool {
        descriptor.requiredRAMGB <= maxRAMGB
    }

    /// Track active request count
    public func requestStarted() {
        activeRequests += 1
    }

    public func requestCompleted() {
        activeRequests = max(0, activeRequests - 1)
    }

    // MARK: - Memory Monitoring

    private func availableMemoryBytes() -> UInt64 {
        #if os(iOS) || os(tvOS) || os(watchOS)
        return UInt64(os_proc_available_memory())
        #elseif os(macOS)
        // Use vm_statistics64 to estimate available memory on macOS
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else {
            return UInt64(hardware.totalRAMGB * 1_073_741_824)
        }
        let pageSize = UInt64(vm_kernel_page_size)
        return (UInt64(stats.free_count) + UInt64(stats.inactive_count) + UInt64(stats.purgeable_count)) * pageSize
        #else
        return UInt64(hardware.totalRAMGB * 1_073_741_824)
        #endif
    }
}
