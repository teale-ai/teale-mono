import Foundation

// MARK: - Chip Family

public enum ChipFamily: String, Codable, Sendable {
    case m1, m1Pro, m1Max, m1Ultra
    case m2, m2Pro, m2Max, m2Ultra
    case m3, m3Pro, m3Max, m3Ultra
    case m4, m4Pro, m4Max, m4Ultra
    case a14, a15, a16, a17Pro, a18, a18Pro, a19Pro
    case unknown

    public var isAppleSilicon: Bool { self != .unknown }

    public var generation: Int {
        switch self {
        case .m1, .m1Pro, .m1Max, .m1Ultra: return 1
        case .m2, .m2Pro, .m2Max, .m2Ultra: return 2
        case .m3, .m3Pro, .m3Max, .m3Ultra: return 3
        case .m4, .m4Pro, .m4Max, .m4Ultra: return 4
        case .a14: return 14
        case .a15: return 15
        case .a16: return 16
        case .a17Pro: return 17
        case .a18, .a18Pro: return 18
        case .a19Pro: return 19
        case .unknown: return 0
        }
    }
}

// MARK: - Device Tier

public enum DeviceTier: Int, Codable, Sendable, Comparable {
    case tier4 = 4  // iPhones, old devices — leaf node only
    case tier3 = 3  // iPads with M-series
    case tier2 = 2  // Mac laptops
    case tier1 = 1  // Mac desktops — backbone

    public static func < (lhs: DeviceTier, rhs: DeviceTier) -> Bool {
        lhs.rawValue > rhs.rawValue // tier1 is highest
    }
}

// MARK: - Thermal State

public enum ThermalLevel: String, Codable, Sendable, Comparable {
    case nominal
    case fair
    case serious
    case critical

    public static func < (lhs: ThermalLevel, rhs: ThermalLevel) -> Bool {
        let order: [ThermalLevel] = [.nominal, .fair, .serious, .critical]
        return order.firstIndex(of: lhs)! < order.firstIndex(of: rhs)!
    }
}

// MARK: - Power State

public struct PowerState: Codable, Sendable {
    public var isOnACPower: Bool
    public var batteryLevel: Double?  // 0.0-1.0, nil if no battery
    public var isLowPowerMode: Bool

    public init(isOnACPower: Bool, batteryLevel: Double? = nil, isLowPowerMode: Bool = false) {
        self.isOnACPower = isOnACPower
        self.batteryLevel = batteryLevel
        self.isLowPowerMode = isLowPowerMode
    }
}

// MARK: - Hardware Capability Profile

public struct HardwareCapability: Codable, Sendable {
    public var chipFamily: ChipFamily
    public var chipName: String          // e.g. "Apple M2 Pro"
    public var totalRAMGB: Double        // e.g. 32.0
    public var gpuCoreCount: Int
    public var memoryBandwidthGBs: Double  // estimated GB/s
    public var tier: DeviceTier

    public init(
        chipFamily: ChipFamily,
        chipName: String,
        totalRAMGB: Double,
        gpuCoreCount: Int,
        memoryBandwidthGBs: Double,
        tier: DeviceTier
    ) {
        self.chipFamily = chipFamily
        self.chipName = chipName
        self.totalRAMGB = totalRAMGB
        self.gpuCoreCount = gpuCoreCount
        self.memoryBandwidthGBs = memoryBandwidthGBs
        self.tier = tier
    }

    /// Estimated available RAM for model loading (total minus ~4GB for OS)
    public var availableRAMForModelsGB: Double {
        max(totalRAMGB - 4.0, 1.0)
    }
}
