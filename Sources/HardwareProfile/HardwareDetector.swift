import Foundation
import SharedTypes
#if canImport(IOKit)
import IOKit
#endif

// MARK: - Hardware Detector

public struct HardwareDetector: Sendable {
    public init() {}

    /// Detect the current device's hardware capabilities
    public func detect() -> HardwareCapability {
        let chipName = detectChipName()
        let chipFamily = parseChipFamily(from: chipName)
        let totalRAM = detectTotalRAM()
        let gpuCores = detectGPUCoreCount()
        let bandwidth = estimateMemoryBandwidth(chip: chipFamily, ram: totalRAM)
        let tier = determineTier(chipFamily: chipFamily)

        return HardwareCapability(
            chipFamily: chipFamily,
            chipName: chipName,
            totalRAMGB: totalRAM,
            gpuCoreCount: gpuCores,
            memoryBandwidthGBs: bandwidth,
            tier: tier
        )
    }

    // MARK: - Chip Detection

    private func detectChipName() -> String {
        sysctlString("machdep.cpu.brand_string") ?? "Unknown"
    }

    private func parseChipFamily(from name: String) -> ChipFamily {
        let lower = name.lowercased()
        if lower.contains("m4 ultra") { return .m4Ultra }
        if lower.contains("m4 max") { return .m4Max }
        if lower.contains("m4 pro") { return .m4Pro }
        if lower.contains("m4") { return .m4 }
        if lower.contains("m3 ultra") { return .m3Ultra }
        if lower.contains("m3 max") { return .m3Max }
        if lower.contains("m3 pro") { return .m3Pro }
        if lower.contains("m3") { return .m3 }
        if lower.contains("m2 ultra") { return .m2Ultra }
        if lower.contains("m2 max") { return .m2Max }
        if lower.contains("m2 pro") { return .m2Pro }
        if lower.contains("m2") { return .m2 }
        if lower.contains("m1 ultra") { return .m1Ultra }
        if lower.contains("m1 max") { return .m1Max }
        if lower.contains("m1 pro") { return .m1Pro }
        if lower.contains("m1") { return .m1 }
        return .unknown
    }

    // MARK: - RAM Detection

    private func detectTotalRAM() -> Double {
        Double(ProcessInfo.processInfo.physicalMemory) / (1024 * 1024 * 1024)
    }

    // MARK: - GPU Core Count

    private func detectGPUCoreCount() -> Int {
        #if canImport(Metal)
        // Attempt Metal-based detection
        if let count = metalGPUCoreCount() { return count }
        #endif
        // Fallback: estimate from chip family
        return estimateGPUCores()
    }

    #if canImport(Metal)
    private func metalGPUCoreCount() -> Int? {
        // Metal doesn't directly expose core count, but we can use IOKit
        return ioKitGPUCoreCount()
    }
    #endif

    private func ioKitGPUCoreCount() -> Int? {
        #if os(macOS)
        let matching = IOServiceMatching("AGXAccelerator")
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else {
            return nil
        }
        defer { IOObjectRelease(iterator) }

        var service = IOIteratorNext(iterator)
        while service != 0 {
            if let props = getIOProperties(service) {
                if let gpuCores = props["gpu-core-count"] as? Int {
                    IOObjectRelease(service)
                    return gpuCores
                }
            }
            IOObjectRelease(service)
            service = IOIteratorNext(iterator)
        }
        return nil
        #else
        return nil
        #endif
    }

    #if os(macOS)
    private func getIOProperties(_ service: io_object_t) -> [String: Any]? {
        var properties: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS else {
            return nil
        }
        return properties?.takeRetainedValue() as? [String: Any]
    }
    #endif

    private func estimateGPUCores() -> Int {
        // Reasonable estimates based on chip family
        let chipName = detectChipName()
        let family = parseChipFamily(from: chipName)
        switch family {
        case .m1: return 8
        case .m1Pro: return 16
        case .m1Max: return 32
        case .m1Ultra: return 64
        case .m2: return 10
        case .m2Pro: return 19
        case .m2Max: return 38
        case .m2Ultra: return 76
        case .m3: return 10
        case .m3Pro: return 18
        case .m3Max: return 40
        case .m3Ultra: return 80
        case .m4: return 10
        case .m4Pro: return 20
        case .m4Max: return 40
        case .m4Ultra: return 80
        default: return 8
        }
    }

    // MARK: - Memory Bandwidth

    private func estimateMemoryBandwidth(chip: ChipFamily, ram: Double) -> Double {
        switch chip {
        case .m1: return 68.25
        case .m1Pro: return 200.0
        case .m1Max: return 400.0
        case .m1Ultra: return 800.0
        case .m2: return 100.0
        case .m2Pro: return 200.0
        case .m2Max: return 400.0
        case .m2Ultra: return 800.0
        case .m3: return 100.0
        case .m3Pro: return 150.0
        case .m3Max: return 400.0
        case .m3Ultra: return 800.0
        case .m4: return 120.0
        case .m4Pro: return 273.0
        case .m4Max: return 546.0
        case .m4Ultra: return 819.2
        default: return 50.0
        }
    }

    // MARK: - Device Tier

    private func determineTier(chipFamily: ChipFamily) -> DeviceTier {
        #if os(macOS)
        // Check if desktop vs laptop
        let model = sysctlString("hw.model") ?? ""
        if model.contains("MacPro") || model.contains("MacStudio") || model.contains("Macmini") || model.contains("Mac1") {
            return .tier1
        }
        return .tier2
        #elseif os(iOS)
        return .tier4
        #else
        return .tier2
        #endif
    }

    // MARK: - sysctl Helper

    private func sysctlString(_ name: String) -> String? {
        var size = 0
        sysctlbyname(name, nil, &size, nil, 0)
        guard size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        sysctlbyname(name, &buffer, &size, nil, 0)
        return String(cString: buffer)
    }
}
