import Foundation

// MARK: - Chip Family

public enum ChipFamily: String, Codable, Sendable {
    // Apple Silicon — Mac
    case m1, m1Pro, m1Max, m1Ultra
    case m2, m2Pro, m2Max, m2Ultra
    case m3, m3Pro, m3Max, m3Ultra
    case m4, m4Pro, m4Max, m4Ultra
    // Apple Silicon — iPhone/iPad
    case a14, a15, a16, a17Pro, a18, a18Pro, a19Pro
    // Google Tensor
    case tensorG4      // Google Tensor G4 (Pixel 9)
    // Non-Apple (cross-platform teale-node)
    case nvidiaGPU     // NVIDIA GPU (CUDA)
    case amdGPU        // AMD GPU (ROCm)
    case intelCPU      // x86_64 Intel CPU
    case amdCPU        // x86_64 AMD CPU
    case armGeneric    // ARM64 (non-Apple, e.g. Snapdragon, Raspberry Pi)
    case unknown

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        self = ChipFamily(rawValue: rawValue) ?? .unknown
    }

    public var isAppleSilicon: Bool {
        switch self {
        case .nvidiaGPU, .amdGPU, .intelCPU, .amdCPU, .armGeneric, .tensorG4, .unknown:
            return false
        default:
            return true
        }
    }

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
        case .tensorG4: return 4
        case .nvidiaGPU, .amdGPU, .intelCPU, .amdCPU, .armGeneric, .unknown: return 0
        }
    }
}

// MARK: - Device Tier

// MARK: - GPU Backend

public enum GPUBackend: String, Codable, Sendable {
    case metal      // Apple Metal (macOS/iOS)
    case cuda       // NVIDIA CUDA
    case rocm       // AMD ROCm
    case vulkan     // Vulkan (cross-platform)
    case sycl       // Intel SYCL
    case cpu        // CPU-only fallback
}

// MARK: - Platform

public enum Platform: String, Codable, Sendable {
    case macOS
    case iOS
    case linux
    case windows
    case android
    case freebsd
}

// MARK: - Device Tier

public enum DeviceTier: Int, Codable, Sendable, Comparable {
    case tier4 = 4  // iPhones, Android phones, SBCs — leaf node only
    case tier3 = 3  // iPads with M-series, high-end Android tablets
    case tier2 = 2  // Mac laptops, Linux/Windows desktops with GPU
    case tier1 = 1  // Mac desktops, Linux/Windows servers — backbone

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
    public var chipName: String          // e.g. "Apple M2 Pro", "NVIDIA RTX 4090"
    public var totalRAMGB: Double        // e.g. 32.0
    public var gpuCoreCount: Int
    public var memoryBandwidthGBs: Double  // estimated GB/s
    public var tier: DeviceTier
    // Cross-platform fields (optional for backward compatibility with existing Apple nodes)
    public var gpuBackend: GPUBackend?   // nil = inferred from chipFamily (Metal for Apple)
    public var platform: Platform?       // nil = inferred from compile target
    public var gpuVRAMGB: Double?        // discrete GPU VRAM (nil for unified memory)

    public init(
        chipFamily: ChipFamily,
        chipName: String,
        totalRAMGB: Double,
        gpuCoreCount: Int,
        memoryBandwidthGBs: Double,
        tier: DeviceTier,
        gpuBackend: GPUBackend? = nil,
        platform: Platform? = nil,
        gpuVRAMGB: Double? = nil
    ) {
        self.chipFamily = chipFamily
        self.chipName = chipName
        self.totalRAMGB = totalRAMGB
        self.gpuCoreCount = gpuCoreCount
        self.memoryBandwidthGBs = memoryBandwidthGBs
        self.tier = tier
        self.gpuBackend = gpuBackend
        self.platform = platform
        self.gpuVRAMGB = gpuVRAMGB
    }

    private enum CodingKeys: String, CodingKey {
        case chipFamily
        case chipName
        case totalRAMGB
        case gpuCoreCount
        case memoryBandwidthGBs
        case tier
        case gpuBackend
        case platform
        case gpuVRAMGB
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        chipFamily = try container.decode(ChipFamily.self, forKey: .chipFamily)
        chipName = try container.decode(String.self, forKey: .chipName)
        totalRAMGB = try container.decode(Double.self, forKey: .totalRAMGB)
        gpuCoreCount = try container.decode(Int.self, forKey: .gpuCoreCount)
        memoryBandwidthGBs = try container.decode(Double.self, forKey: .memoryBandwidthGBs)

        let rawTier = try container.decodeIfPresent(Int.self, forKey: .tier)
        tier = rawTier.flatMap(DeviceTier.init(rawValue:)) ?? .tier4

        if let rawBackend = try container.decodeIfPresent(String.self, forKey: .gpuBackend) {
            gpuBackend = GPUBackend(rawValue: rawBackend)
        } else {
            gpuBackend = nil
        }

        if let rawPlatform = try container.decodeIfPresent(String.self, forKey: .platform) {
            platform = Platform(rawValue: rawPlatform)
        } else {
            platform = nil
        }

        gpuVRAMGB = try container.decodeIfPresent(Double.self, forKey: .gpuVRAMGB)
    }

    /// Estimated available RAM for model loading (total minus ~4GB for OS)
    public var availableRAMForModelsGB: Double {
        max(totalRAMGB - 4.0, 1.0)
    }

    /// Estimated system power draw in watts during inference.
    /// Based on Apple-published TDP and typical inference workload.
    public var estimatedInferenceWatts: Double {
        switch chipFamily {
        case .m1:                   return 20
        case .m1Pro:                return 30
        case .m1Max:                return 40
        case .m1Ultra:              return 60
        case .m2:                   return 22
        case .m2Pro:                return 35
        case .m2Max:                return 45
        case .m2Ultra:              return 65
        case .m3:                   return 22
        case .m3Pro:                return 36
        case .m3Max:                return 48
        case .m3Ultra:              return 70
        case .m4:                   return 22
        case .m4Pro:                return 38
        case .m4Max:                return 50
        case .m4Ultra:              return 75
        case .a14, .a15:            return 5
        case .a16, .a17Pro:         return 6
        case .a18, .a18Pro:         return 7
        case .a19Pro:               return 8
        case .nvidiaGPU:            return 300 // Typical GPU TDP (RTX 3090/4090 range)
        case .amdGPU:               return 250 // Typical AMD GPU TDP
        case .intelCPU:             return 65  // Typical desktop CPU
        case .amdCPU:               return 65  // Typical desktop CPU
        case .tensorG4:             return 8   // Google Tensor G4 (Pixel 9)
        case .armGeneric:           return 10  // Low-power ARM (Snapdragon, RPi)
        case .unknown:              return 30  // Conservative estimate
        }
    }
}
