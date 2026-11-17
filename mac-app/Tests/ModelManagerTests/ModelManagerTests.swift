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

    func testPopularityRanksAndIDsAreUnique() {
        let ranks = ModelCatalog.allModels.map(\.popularityRank)
        XCTAssertEqual(Set(ranks).count, ranks.count, "duplicate popularityRank")
        let ids = ModelCatalog.allModels.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count, "duplicate id")
    }

    /// Catalog slugs come from the single resolver and are gateway slugs.
    func testCatalogSlugsMatchResolver() {
        for model in ModelCatalog.allModels {
            let resolved = OpenRouterIdResolver.resolve(identifier: model.huggingFaceRepo)
                ?? OpenRouterIdResolver.resolve(identifier: model.id)
            XCTAssertEqual(model.openrouterId, resolved, model.id)
            if let slug = model.openrouterId {
                XCTAssertTrue(OpenRouterIdResolver.isGatewaySlug(slug), "\(model.id): \(slug)")
                XCTAssertEqual(model.advertisedId, slug)
            }
        }
    }

    func testGGUFEntriesDeclareFilesAndBackend() {
        for model in ModelCatalog.allModels where model.format == .gguf {
            XCTAssertFalse(model.ggufFiles?.isEmpty ?? true, model.id)
            XCTAssertTrue([.llamaCpp, .ds4].contains(model.servingBackend), model.id)
        }
        // Flash and Pro share one HF repo but must not share a cache dir.
        let flash = ModelCatalog.allModels.first { $0.id == "deepseek-v4-flash" }!
        let pro = ModelCatalog.allModels.first { $0.id == "deepseek-v4-pro" }!
        XCTAssertEqual(flash.huggingFaceRepo, pro.huggingFaceRepo)
        XCTAssertNotEqual(
            ModelStorageLayout.modelDirectory(for: flash),
            ModelStorageLayout.modelDirectory(for: pro)
        )
        XCTAssertEqual(ModelCatalog.allModels.first { $0.id == "kimi-k2.6" }?.servingBackend, .exo)
    }

    func testFitRuleMatchesDeviceMatrix() {
        let catalog = ModelCatalog()
        func hw(_ ram: Double) -> HardwareCapability {
            HardwareCapability(chipFamily: .m2Pro, chipName: "Apple M2 Pro", totalRAMGB: ram,
                               gpuCoreCount: 19, memoryBandwidthGBs: 204.8, tier: .tier1)
        }
        // docs/device-model-matrix.md config G (32 GB): gemma-3-27b S, qwen3-32b —.
        let ids32 = Set(catalog.availableModels(for: hw(32)).map(\.id))
        XCTAssertTrue(ids32.contains("gemma-3-27b-it-4bit"))
        XCTAssertFalse(ids32.contains("qwen3-32b-4bit"))
        // 16 GB: the recommended Qwen3.5-9B starter fits.
        XCTAssertTrue(catalog.availableModels(for: hw(16)).contains { $0.id == "qwen3.5-9b-4bit" })
        // Every offered model obeys the one rule.
        for ram in [8.0, 16, 24, 32, 64, 128, 512] {
            for model in catalog.availableModels(for: hw(ram)) {
                XCTAssertLessThanOrEqual(model.requiredRAMGB, ModelFit.budgetGB(totalRAMGB: ram))
            }
        }
    }

    func testLocalSnapshotSizeFromIndex() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("teale-snap-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        let index = #"{"metadata":{"total_size":2147483648},"weight_map":{}}"#
        try index.write(to: dir.appendingPathComponent("model.safetensors.index.json"), atomically: true, encoding: .utf8)
        XCTAssertEqual(LocalModelScanner.snapshotWeightsSizeGB(dir), 2.0, accuracy: 0.001)
    }

    func testLocalSnapshotSizeFromFiles() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("teale-snap-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        fm.createFile(atPath: dir.appendingPathComponent("model.safetensors").path, contents: Data(count: 1024 * 1024))
        XCTAssertGreaterThan(LocalModelScanner.snapshotWeightsSizeGB(dir), 0)
    }

    func testGGUFTreeParsing() {
        let json = """
        [{"type":"directory","path":"UD-Q4_K_XL"},
         {"type":"file","path":"UD-Q4_K_XL/a-00001-of-00002.gguf","size":135,
          "lfs":{"oid":"259b0362111685b325a03c6d78e85857d665adeac1c7d13edbb8a43645543791","size":49433942336}}]
        """.data(using: .utf8)!
        let files = GGUFDownloader.parseTree(json)
        XCTAssertEqual(files.count, 1)
        XCTAssertEqual(files[0].size, 49_433_942_336)
        XCTAssertEqual(files[0].sha256?.count, 64)
    }

    func testSHA256Streaming() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("teale-sha-\(UUID().uuidString)")
        try Data("abc".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertEqual(
            try GGUFDownloader.sha256Hex(of: url),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        )
    }
}
