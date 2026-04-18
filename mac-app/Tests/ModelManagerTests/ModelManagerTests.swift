import XCTest
import Foundation
@testable import ModelManager
@testable import SharedTypes

final class ModelManagerTests: XCTestCase {

    func testCatalogHasModels() {
        XCTAssertFalse(ModelCatalog.allModels.isEmpty)
    }

    func testCatalogFiltering() {
        let catalog = ModelCatalog()

        let smallHW = HardwareCapability(
            chipFamily: .m1,
            chipName: "Apple M1",
            totalRAMGB: 8.0,
            gpuCoreCount: 8,
            memoryBandwidthGBs: 68.0,
            tier: .tier2
        )
        let smallModels = catalog.availableModels(for: smallHW)
        XCTAssertTrue(smallModels.allSatisfy { $0.requiredRAMGB <= smallHW.availableRAMForModelsGB })

        let bigHW = HardwareCapability(
            chipFamily: .m2Max,
            chipName: "Apple M2 Max",
            totalRAMGB: 64.0,
            gpuCoreCount: 38,
            memoryBandwidthGBs: 400.0,
            tier: .tier1
        )
        let bigModels = catalog.availableModels(for: bigHW)
        XCTAssertGreaterThan(bigModels.count, smallModels.count)
    }

    func testAllCatalogModelsValid() {
        for model in ModelCatalog.allModels {
            XCTAssertFalse(model.id.isEmpty)
            XCTAssertFalse(model.name.isEmpty)
            XCTAssertFalse(model.huggingFaceRepo.isEmpty)
            XCTAssertGreaterThan(model.estimatedSizeGB, 0)
            XCTAssertGreaterThan(model.requiredRAMGB, 0)
            XCTAssertGreaterThanOrEqual(model.requiredRAMGB, model.estimatedSizeGB)
        }
    }
}
