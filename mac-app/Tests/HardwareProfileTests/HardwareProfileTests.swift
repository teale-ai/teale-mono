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
        XCTAssertEqual(ChipFamily.m4Ultra.generation, 4)
        XCTAssertEqual(ChipFamily.unknown.generation, 0)
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
