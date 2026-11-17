import XCTest
import Foundation
@testable import HardwareProfile
@testable import SharedTypes

final class HardwareProfileTests: XCTestCase {

    func testHardwareDetection() {
        let detector = HardwareDetector()
        let hardware = detector.detect()

        XCTAssertGreaterThan(hardware.totalRAMGB, 0)
        XCTAssertGreaterThan(hardware.gpuCoreCount, 0)
        XCTAssertGreaterThan(hardware.memoryBandwidthGBs, 0)
        XCTAssertFalse(hardware.chipName.isEmpty)
    }

    func testChipFamilyGeneration() {
        XCTAssertEqual(ChipFamily.m1.generation, 1)
        XCTAssertEqual(ChipFamily.m2Pro.generation, 2)
        XCTAssertEqual(ChipFamily.m3Max.generation, 3)
        XCTAssertEqual(ChipFamily.m4Max.generation, 4)
        XCTAssertEqual(ChipFamily.m5Pro.generation, 5)
        XCTAssertEqual(ChipFamily.appleSiliconPro.generation, ChipFamily.unknownAppleGeneration)
        XCTAssertEqual(ChipFamily.unknown.generation, 0)
    }

    func testParseKnownChipFamilies() {
        XCTAssertEqual(HardwareDetector.parseChipFamily(from: "Apple M1"), .m1)
        XCTAssertEqual(HardwareDetector.parseChipFamily(from: "Apple M1 Ultra"), .m1Ultra)
        XCTAssertEqual(HardwareDetector.parseChipFamily(from: "Apple M2 Pro"), .m2Pro)
        XCTAssertEqual(HardwareDetector.parseChipFamily(from: "Apple M3 Max"), .m3Max)
        XCTAssertEqual(HardwareDetector.parseChipFamily(from: "Apple M3 Ultra"), .m3Ultra)
        XCTAssertEqual(HardwareDetector.parseChipFamily(from: "Apple M4"), .m4)
        XCTAssertEqual(HardwareDetector.parseChipFamily(from: "Apple M4 Pro"), .m4Pro)
        XCTAssertEqual(HardwareDetector.parseChipFamily(from: "Apple M4 Max"), .m4Max)
    }

    func testParseM5Family() {
        XCTAssertEqual(HardwareDetector.parseChipFamily(from: "Apple M5"), .m5)
        XCTAssertEqual(HardwareDetector.parseChipFamily(from: "Apple M5 Pro"), .m5Pro)
        XCTAssertEqual(HardwareDetector.parseChipFamily(from: "Apple M5 Max"), .m5Max)

        let m5Pro = ChipFamily.m5Pro
        XCTAssertTrue(m5Pro.isAppleSilicon)
        XCTAssertEqual(m5Pro.deviceClass, .proLaptop)
        XCTAssertEqual(ChipFamily.m5.deviceClass, .baseMac)
        XCTAssertEqual(ChipFamily.m5Max.deviceClass, .maxDesktop)
    }

    func testParseUnknownAppleGenerationFallsBackBySuffix() {
        XCTAssertEqual(HardwareDetector.parseChipFamily(from: "Apple M6"), .appleSilicon)
        XCTAssertEqual(HardwareDetector.parseChipFamily(from: "Apple M6 Pro"), .appleSiliconPro)
        XCTAssertEqual(HardwareDetector.parseChipFamily(from: "Apple M7 Max"), .appleSiliconMax)
        // No M4 Ultra exists; an unreleased Ultra still lands in the Ultra class.
        XCTAssertEqual(HardwareDetector.parseChipFamily(from: "Apple M4 Ultra"), .appleSiliconUltra)
        XCTAssertEqual(HardwareDetector.parseChipFamily(from: "Apple M5 Ultra"), .appleSiliconUltra)

        for family in [ChipFamily.appleSilicon, .appleSiliconPro, .appleSiliconMax, .appleSiliconUltra] {
            XCTAssertTrue(family.isAppleSilicon, "\(family)")
            XCTAssertNotEqual(family.deviceClass, .other, "\(family)")
        }
        XCTAssertEqual(ChipFamily.appleSiliconUltra.deviceClass, .ultraDesktop)
    }

    func testParseNonAppleBrandStrings() {
        XCTAssertEqual(HardwareDetector.parseChipFamily(from: "Intel(R) Core(TM) i9-9980HK CPU @ 2.40GHz"), .unknown)
        XCTAssertEqual(HardwareDetector.parseChipFamily(from: "Unknown"), .unknown)
        XCTAssertEqual(HardwareDetector.parseChipFamily(from: ""), .unknown)
        XCTAssertEqual(HardwareDetector.parseChipFamily(from: "Apple Mxyz"), .unknown)
    }

    func testBandwidthForNewChips() {
        XCTAssertEqual(HardwareDetector.estimateMemoryBandwidth(chip: .m5, gpuCores: 10), 153.0)
        XCTAssertEqual(HardwareDetector.estimateMemoryBandwidth(chip: .m5Pro, gpuCores: 20), 307.0)
        XCTAssertEqual(HardwareDetector.estimateMemoryBandwidth(chip: .m5Max, gpuCores: 32), 460.0)
        XCTAssertEqual(HardwareDetector.estimateMemoryBandwidth(chip: .m5Max, gpuCores: 40), 614.0)
        XCTAssertGreaterThan(HardwareDetector.estimateMemoryBandwidth(chip: .appleSiliconPro, gpuCores: 20), 50.0)
    }

    func testNewAppleChipGetsAppleLlamaProfile() {
        let hardware = HardwareCapability(
            chipFamily: HardwareDetector.parseChipFamily(from: "Apple M5 Pro"),
            chipName: "Apple M5 Pro",
            totalRAMGB: 48,
            gpuCoreCount: 20,
            memoryBandwidthGBs: 307,
            tier: .tier2
        )
        let other = HardwareCapability(
            chipFamily: .nvidiaGPU,
            chipName: "NVIDIA",
            totalRAMGB: 48,
            gpuCoreCount: 0,
            memoryBandwidthGBs: 900,
            tier: .tier1
        )
        let appleProfile = DeviceModelProfileResolver.resolve(hardware: hardware)
        let otherProfile = DeviceModelProfileResolver.resolve(hardware: other)
        XCTAssertNotEqual(appleProfile, otherProfile)
    }

    func testTierFollowsInternalBattery() {
        XCTAssertEqual(HardwareDetector.tier(hasInternalBattery: true), .tier2)
        XCTAssertEqual(HardwareDetector.tier(hasInternalBattery: false), .tier1)
    }

    func testThermalLevelOrdering() {
        XCTAssertTrue(ThermalLevel.nominal < ThermalLevel.fair)
        XCTAssertTrue(ThermalLevel.fair < ThermalLevel.serious)
        XCTAssertTrue(ThermalLevel.serious < ThermalLevel.critical)
    }

    func testDeviceTierOrdering() {
        XCTAssertTrue(DeviceTier.tier1 > DeviceTier.tier2)
        XCTAssertTrue(DeviceTier.tier2 > DeviceTier.tier3)
        XCTAssertTrue(DeviceTier.tier3 > DeviceTier.tier4)
    }
}
