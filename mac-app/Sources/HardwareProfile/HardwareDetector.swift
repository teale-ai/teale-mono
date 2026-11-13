import Foundation
import SharedTypes
#if canImport(IOKit)
import IOKit
#endif
#if os(macOS)
import IOKit.ps
#endif

// MARK: - Hardware Detector

public struct HardwareDetector: Sendable {
    public init() {}

    /// Detect the current device's hardware capabilities
    public func detect() -> HardwareCapability {
        let chipName = detectChipName()
        let chipFamily = Self.parseChipFamily(from: chipName)
        let totalRAM = detectTotalRAM()
        let gpuCores = detectGPUCoreCount(family: chipFamily)
        let bandwidth = Self.estimateMemoryBandwidth(chip: chipFamily, gpuCores: gpuCores)
        let tier = determineTier()

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

    /// Brand string → chip family. Any "Apple M<n> …" string is Apple
    /// Silicon, even for generations this build does not know.
    static func parseChipFamily(from name: String) -> ChipFamily {
        ChipFamily.parse(brandString: name)
    }

    // MARK: - RAM Detection

    private func detectTotalRAM() -> Double {
        Double(ProcessInfo.processInfo.physicalMemory) / (1024 * 1024 * 1024)
    }

    // MARK: - GPU Core Count

    private func detectGPUCoreCount(family: ChipFamily) -> Int {
        #if canImport(Metal)
        // Attempt Metal-based detection
        if let count = metalGPUCoreCount() { return count }
        #endif
        // Fallback: estimate from chip family
        return Self.estimateGPUCores(family: family)
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

    /// Top-bin GPU core count per family, used only when IOKit does not
    /// report one.
    static func estimateGPUCores(family: ChipFamily) -> Int {
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
        case .m5: return 10
        case .m5Pro: return 20
        case .m5Max: return 40
        case .appleSilicon: return 10
        case .appleSiliconPro: return 20
        case .appleSiliconMax: return 40
        case .appleSiliconUltra: return 80
        default: return 8
        }
    }

    // MARK: - Memory Bandwidth

    /// Peak unified-memory bandwidth (GB/s) per docs/mac-fleet-configurations.md.
    /// Max chips ship in two memory configurations told apart by GPU core
    /// count (e.g. M5 Max 32-core 460 GB/s vs 40-core 614 GB/s).
    static func estimateMemoryBandwidth(chip: ChipFamily, gpuCores: Int) -> Double {
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
        case .m3Max: return gpuCores > 0 && gpuCores <= 30 ? 300.0 : 400.0
        case .m3Ultra: return 800.0
        case .m4: return 120.0
        case .m4Pro: return 273.0
        case .m4Max: return gpuCores > 0 && gpuCores <= 32 ? 410.0 : 546.0
        case .m5: return 153.0
        case .m5Pro: return 307.0
        case .m5Max: return gpuCores > 0 && gpuCores <= 32 ? 460.0 : 614.0
        // Unknown (newer) generation: assume at least the newest known
        // generation's figures for the same variant.
        case .appleSilicon: return 153.0
        case .appleSiliconPro: return 307.0
        case .appleSiliconMax: return 614.0
        case .appleSiliconUltra: return 819.0
        default: return 50.0
        }
    }

    // MARK: - Device Tier

    /// Desktops (no internal battery) are tier 1 backbone nodes; anything
    /// with an internal battery is a laptop and tier 2. Based on the IOKit
    /// power-source list rather than `hw.model`, whose "MacXX,Y" identifiers
    /// no longer distinguish laptops from desktops.
    private func determineTier() -> DeviceTier {
        #if os(macOS)
        return Self.tier(hasInternalBattery: Self.hasInternalBattery())
        #elseif os(iOS)
        return .tier4
        #else
        return .tier2
        #endif
    }

    static func tier(hasInternalBattery: Bool) -> DeviceTier {
        hasInternalBattery ? .tier2 : .tier1
    }

    #if os(macOS)
    /// True when IOKit lists an internal battery among the power sources.
    /// UPS units attached to a desktop report a different type and are
    /// ignored.
    static func hasInternalBattery() -> Bool {
        let snapshot = IOPSCopyPowerSourcesInfo().takeRetainedValue()
        let sources = IOPSCopyPowerSourcesList(snapshot).takeRetainedValue() as? [CFTypeRef] ?? []
        for source in sources {
            guard let info = IOPSGetPowerSourceDescription(snapshot, source)?.takeUnretainedValue() as? [String: Any] else {
                continue
            }
            if (info[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType {
                return true
            }
        }
        return false
    }
    #endif

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
