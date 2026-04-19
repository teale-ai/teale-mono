import Foundation
import SharedTypes

// MARK: - Device Model Profile Resolver

/// Resolves the best inference profile for a given (hardware, model) combination.
///
/// Resolution order (highest priority first):
/// 1. User overrides (from ~/.teale/profiles.json) — exact model match
/// 2. User overrides — family match
/// 3. User overrides — device-class default
/// 4. Built-in registry — exact model match
/// 5. Built-in registry — family match
/// 6. Built-in registry — device-class default
/// 7. Global hardcoded defaults
public struct DeviceModelProfileResolver: Sendable {

    /// Resolve the best InferenceProfile for the given hardware and optional model.
    public static func resolve(
        hardware: HardwareCapability,
        model: ModelDescriptor? = nil,
        userOverrides: [DeviceModelProfile]? = nil
    ) -> InferenceProfile {
        let deviceClass = hardware.chipFamily.deviceClass
        let ram = hardware.totalRAMGB

        // Start with global defaults
        var result = globalDefaults

        // Layer 1: Built-in device-class defaults
        let builtIn = DeviceModelProfileRegistry.profiles
        if let deviceDefault = bestMatch(
            in: builtIn, deviceClass: deviceClass, ram: ram,
            modelID: nil, modelFamily: nil
        ) {
            result = result.merging(with: deviceDefault.params)
        }

        // Layer 2: Built-in family match
        if let family = model?.family {
            if let familyMatch = bestMatch(
                in: builtIn, deviceClass: deviceClass, ram: ram,
                modelID: nil, modelFamily: family
            ) {
                result = result.merging(with: familyMatch.params)
            }
        }

        // Layer 3: Built-in exact model match
        if let modelID = model?.id {
            if let modelMatch = bestMatch(
                in: builtIn, deviceClass: deviceClass, ram: ram,
                modelID: modelID, modelFamily: nil
            ) {
                result = result.merging(with: modelMatch.params)
            }
        }

        // Layer 4-6: User overrides (same cascade, higher priority)
        if let overrides = userOverrides, !overrides.isEmpty {
            if let deviceDefault = bestMatch(
                in: overrides, deviceClass: deviceClass, ram: ram,
                modelID: nil, modelFamily: nil
            ) {
                result = result.merging(with: deviceDefault.params)
            }

            if let family = model?.family {
                if let familyMatch = bestMatch(
                    in: overrides, deviceClass: deviceClass, ram: ram,
                    modelID: nil, modelFamily: family
                ) {
                    result = result.merging(with: familyMatch.params)
                }
            }

            if let modelID = model?.id {
                if let modelMatch = bestMatch(
                    in: overrides, deviceClass: deviceClass, ram: ram,
                    modelID: modelID, modelFamily: nil
                ) {
                    result = result.merging(with: modelMatch.params)
                }
            }
        }

        // Post-processing: flash attention requires M3+ (generation >= 3)
        if hardware.chipFamily.isAppleSilicon && hardware.chipFamily.generation < 3 {
            result.flashAttn = false
        }

        return result
    }

    // MARK: - Private

    /// Global fallback defaults when no profile matches at all.
    private static let globalDefaults = InferenceProfile(
        contextSize: 8192,
        kvCacheType: "q8_0",
        batchSize: 1024,
        flashAttn: false,
        mmap: false,
        parallelSlots: 1,
        gpuLayers: 999,
        reasoningOff: true
    )

    /// Find the best matching profile in a list for the given criteria.
    /// Matches on deviceClass + RAM range, then filters by modelID/modelFamily.
    private static func bestMatch(
        in profiles: [DeviceModelProfile],
        deviceClass: DeviceClass,
        ram: Double,
        modelID: String?,
        modelFamily: String?
    ) -> DeviceModelProfile? {
        profiles.first { profile in
            guard profile.deviceClass == deviceClass else { return false }
            guard profile.matchesRAM(ram) else { return false }

            // Match specificity level
            if let modelID = modelID {
                return profile.modelID == modelID
            } else if let modelFamily = modelFamily {
                return profile.modelID == nil && profile.modelFamily == modelFamily
            } else {
                return profile.modelID == nil && profile.modelFamily == nil
            }
        }
    }
}
