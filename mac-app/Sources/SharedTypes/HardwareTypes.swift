import Foundation

// MARK: - Chip Family

public enum ChipFamily: String, Codable, Sendable {
    // Apple Silicon — Mac
    case m1, m1Pro, m1Max, m1Ultra
    case m2, m2Pro, m2Max, m2Ultra
    case m3, m3Pro, m3Max, m3Ultra
    // There is no M4 Ultra: Apple skipped it (the 2025 Mac Studio ships the
    // M3 Ultra), so the enum does not model one.
    case m4, m4Pro, m4Max
    case m5, m5Pro, m5Max
    // Apple Silicon Mac whose generation this build does not know yet
    // (e.g. "Apple M6 Pro", or an M5 Ultra once it ships). Classified by
    // the Pro/Max/Ultra suffix so a new Mac is never treated as non-Apple.
    case appleSilicon, appleSiliconPro, appleSiliconMax, appleSiliconUltra
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
        case .m4, .m4Pro, .m4Max: return 4
        case .m5, .m5Pro, .m5Max: return 5
        // Newer than every generation this build knows.
        case .appleSilicon, .appleSiliconPro, .appleSiliconMax, .appleSiliconUltra:
            return Self.unknownAppleGeneration
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

    /// `generation` reported for an Apple Silicon Mac newer than the
    /// families this build knows.
    public static let unknownAppleGeneration = 99

    /// Parse a `machdep.cpu.brand_string` such as "Apple M5 Pro".
    /// Known generations map to their exact family. Any other brand string
    /// that starts with "Apple M<digits>" maps to the generation-agnostic
    /// Apple Silicon family picked by its Pro/Max/Ultra suffix. Everything
    /// else is `.unknown`.
    public static func parse(brandString: String) -> ChipFamily {
        let lower = brandString.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard lower.hasPrefix("apple m") else { return .unknown }
        let afterM = lower.dropFirst("apple m".count)
        let digits = afterM.prefix { $0.isASCII && $0.isNumber }
        guard let generation = Int(digits) else { return .unknown }
        let rest = afterM.dropFirst(digits.count)
            .split(whereSeparator: { $0 == " " || $0 == "(" || $0 == ")" || $0 == "-" })
            .map(String.init)
        enum Variant { case base, pro, max, ultra }
        let variant: Variant
        if rest.contains("ultra") {
            variant = .ultra
        } else if rest.contains("max") {
            variant = .max
        } else if rest.contains("pro") {
            variant = .pro
        } else {
            variant = .base
        }

        switch (generation, variant) {
        case (1, .base): return .m1
        case (1, .pro): return .m1Pro
        case (1, .max): return .m1Max
        case (1, .ultra): return .m1Ultra
        case (2, .base): return .m2
        case (2, .pro): return .m2Pro
        case (2, .max): return .m2Max
        case (2, .ultra): return .m2Ultra
        case (3, .base): return .m3
        case (3, .pro): return .m3Pro
        case (3, .max): return .m3Max
        case (3, .ultra): return .m3Ultra
        case (4, .base): return .m4
        case (4, .pro): return .m4Pro
        case (4, .max): return .m4Max
        case (5, .base): return .m5
        case (5, .pro): return .m5Pro
        case (5, .max): return .m5Max
        case (_, .base): return .appleSilicon
        case (_, .pro): return .appleSiliconPro
        case (_, .max): return .appleSiliconMax
        case (_, .ultra): return .appleSiliconUltra
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

    /// RAM budget for a model's full footprint (weights + KV + runtime).
    /// Delegates to `ModelFit`, the single fit rule shared by the catalog
    /// filter, the MLX free-memory guard and the docs.
    public var availableRAMForModelsGB: Double {
        ModelFit.budgetGB(totalRAMGB: totalRAMGB)
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
        case .m5:                   return 22
        case .m5Pro:                return 40
        case .m5Max:                return 55
        case .appleSilicon:         return 22
        case .appleSiliconPro:      return 40
        case .appleSiliconMax:      return 55
        case .appleSiliconUltra:    return 75
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
