import Foundation

// MARK: - Device Class

/// Groups the 21+ chip families into 5 practical device classes for profile matching.
/// This avoids the combinatorial explosion of per-chip-per-model profiles.
public enum DeviceClass: String, Codable, Sendable, CaseIterable {
    case ultraDesktop  // M*Ultra — 64-192 GB, can run anything
    case maxDesktop    // M*Max — 32-128 GB, high-end
    case proLaptop     // M*Pro — 16-48 GB, mainstream power user
    case baseMac       // M1/M2/M3/M4 base — 8-24 GB, memory-constrained
    case mobile        // A-series — 4-16 GB, very constrained
    case other         // Non-Apple (NVIDIA, AMD, Intel, ARM)
}

extension ChipFamily {
    public var deviceClass: DeviceClass {
        switch self {
        case .m1Ultra, .m2Ultra, .m3Ultra, .m4Ultra:
            return .ultraDesktop
        case .m1Max, .m2Max, .m3Max, .m4Max:
            return .maxDesktop
        case .m1Pro, .m2Pro, .m3Pro, .m4Pro:
            return .proLaptop
        case .m1, .m2, .m3, .m4:
            return .baseMac
        case .a14, .a15, .a16, .a17Pro, .a18, .a18Pro, .a19Pro:
            return .mobile
        case .tensorG4:
            return .mobile
        case .nvidiaGPU, .amdGPU, .intelCPU, .amdCPU, .armGeneric, .unknown:
            return .other
        }
    }
}

// MARK: - Inference Profile

/// Tunable parameters for llama.cpp inference. All optional — nil means "use default".
/// When resolving profiles, non-nil values from higher-priority profiles override lower ones.
public struct InferenceProfile: Sendable, Codable, Equatable {
    public var contextSize: Int?
    public var kvCacheType: String?       // "q4_0", "q8_0", "f16"
    public var batchSize: Int?
    public var flashAttn: Bool?
    public var mmap: Bool?
    public var parallelSlots: Int?
    public var gpuLayers: Int?
    public var threads: Int?
    public var reasoningOff: Bool?

    public init(
        contextSize: Int? = nil,
        kvCacheType: String? = nil,
        batchSize: Int? = nil,
        flashAttn: Bool? = nil,
        mmap: Bool? = nil,
        parallelSlots: Int? = nil,
        gpuLayers: Int? = nil,
        threads: Int? = nil,
        reasoningOff: Bool? = nil
    ) {
        self.contextSize = contextSize
        self.kvCacheType = kvCacheType
        self.batchSize = batchSize
        self.flashAttn = flashAttn
        self.mmap = mmap
        self.parallelSlots = parallelSlots
        self.gpuLayers = gpuLayers
        self.threads = threads
        self.reasoningOff = reasoningOff
    }

    /// Merge two profiles: overlay's non-nil values override base.
    public func merging(with overlay: InferenceProfile) -> InferenceProfile {
        InferenceProfile(
            contextSize: overlay.contextSize ?? self.contextSize,
            kvCacheType: overlay.kvCacheType ?? self.kvCacheType,
            batchSize: overlay.batchSize ?? self.batchSize,
            flashAttn: overlay.flashAttn ?? self.flashAttn,
            mmap: overlay.mmap ?? self.mmap,
            parallelSlots: overlay.parallelSlots ?? self.parallelSlots,
            gpuLayers: overlay.gpuLayers ?? self.gpuLayers,
            threads: overlay.threads ?? self.threads,
            reasoningOff: overlay.reasoningOff ?? self.reasoningOff
        )
    }
}

// MARK: - Device Model Profile

/// A profile entry mapping a (device class, model) combination to optimal inference parameters.
/// When `modelID` and `modelFamily` are both nil, this is a device-class default.
public struct DeviceModelProfile: Sendable, Codable {
    public var deviceClass: DeviceClass
    public var modelID: String?           // nil = applies to all models
    public var modelFamily: String?       // nil = applies to all families
    public var minRAMGB: Double?          // RAM floor for this profile to activate
    public var maxRAMGB: Double?          // RAM ceiling for this profile
    public var params: InferenceProfile
    public var notes: String?

    public init(
        deviceClass: DeviceClass,
        modelID: String? = nil,
        modelFamily: String? = nil,
        minRAMGB: Double? = nil,
        maxRAMGB: Double? = nil,
        params: InferenceProfile,
        notes: String? = nil
    ) {
        self.deviceClass = deviceClass
        self.modelID = modelID
        self.modelFamily = modelFamily
        self.minRAMGB = minRAMGB
        self.maxRAMGB = maxRAMGB
        self.params = params
        self.notes = notes
    }

    /// Whether this profile's RAM requirements match the given hardware.
    public func matchesRAM(_ totalRAMGB: Double) -> Bool {
        if let min = minRAMGB, totalRAMGB < min { return false }
        if let max = maxRAMGB, totalRAMGB < max { return true }
        return maxRAMGB == nil
    }
}
