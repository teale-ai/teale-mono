import XCTest
import Foundation
@testable import SharedTypes

final class SafePathComponentTests: XCTestCase {

    func testAcceptsOrdinaryNames() {
        for name in ["config.json", "model-00001-of-00002.safetensors", "qwen3-8b-4bit", "tokenizer.model", "a"] {
            XCTAssertTrue(SafePathComponent.isValid(name), name)
        }
    }

    func testRejectsTraversalAndSeparators() {
        let bad = [
            "", ".", "..", "../x", "../../Library", "a/b", "/etc/passwd",
            "a\\b", "..\\x", "x..y", "a\u{0}b", "line\nbreak",
        ]
        for name in bad {
            XCTAssertFalse(SafePathComponent.isValid(name), name.debugDescription)
        }
    }

    func testResolveStaysInsideDirectory() {
        let root = URL(fileURLWithPath: "/tmp/teale-test-root", isDirectory: true)
        XCTAssertEqual(
            SafePathComponent.resolve("config.json", in: root)?.path,
            "/tmp/teale-test-root/config.json"
        )
        XCTAssertNil(SafePathComponent.resolve("..", in: root))
        XCTAssertNil(SafePathComponent.resolve("../escape", in: root))
        XCTAssertNil(SafePathComponent.resolve("sub/file", in: root))
    }

    func testContainment() {
        let root = URL(fileURLWithPath: "/tmp/teale-root", isDirectory: true)
        XCTAssertTrue(SafePathComponent.isContained(URL(fileURLWithPath: "/tmp/teale-root/a/b"), in: root))
        XCTAssertFalse(SafePathComponent.isContained(URL(fileURLWithPath: "/tmp/teale-root"), in: root))
        XCTAssertFalse(SafePathComponent.isContained(URL(fileURLWithPath: "/tmp/teale-root-other/x"), in: root))
        XCTAssertFalse(SafePathComponent.isContained(URL(fileURLWithPath: "/tmp/teale-root/../x"), in: root))
    }

    func testModelDirectoriesRejectUnsafeIdentifiers() {
        XCTAssertNil(ModelStorageLayout.ggufModelDirectory(modelID: "../.."))
        XCTAssertNil(ModelStorageLayout.mlxModelDirectory(repo: "../../Library"))
        XCTAssertNil(ModelStorageLayout.mlxModelDirectory(repo: "a/b/c"))
        let dir = ModelStorageLayout.mlxModelDirectory(repo: "mlx-community/Qwen3-8B-4bit")
        XCTAssertEqual(dir?.lastPathComponent, "Qwen3-8B-4bit")
        XCTAssertTrue(SafePathComponent.isContained(dir!, in: ModelStorageLayout.huggingFaceModelsDirectory()))
    }

    func testRegistryOnlyResolvesKnownSafeIDs() {
        let registry = ModelDirectoryRegistry()
        registry.register([
            ModelDescriptor(
                id: "known-model",
                name: "Known",
                huggingFaceRepo: "org/known",
                parameterCount: "1B",
                quantization: .q4,
                estimatedSizeGB: 1,
                requiredRAMGB: 2,
                family: "Test",
                description: ""
            ),
        ])
        XCTAssertNotNil(registry.descriptor(forModelID: "known-model"))
        XCTAssertNil(registry.descriptor(forModelID: "unknown-model"))
        XCTAssertNil(registry.descriptor(forModelID: "../known-model"))
    }

    func testGGUFFilesMatchRepoRelativePatterns() {
        let fm = FileManager.default
        let modelDir = fm.temporaryDirectory.appendingPathComponent("teale-gguf-\(UUID().uuidString)")
        let quantDir = modelDir.appendingPathComponent("models/unsloth/GLM-5.1-GGUF/UD-Q4_K_XL")
        try? fm.createDirectory(at: quantDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: modelDir) }
        for name in ["GLM-5.1-UD-Q4_K_XL-00002-of-00011.gguf", "GLM-5.1-UD-Q4_K_XL-00001-of-00011.gguf"] {
            fm.createFile(atPath: quantDir.appendingPathComponent(name).path, contents: Data([0]))
        }
        let files = ModelStorageLayout.ggufFiles(
            in: modelDir,
            matching: ["UD-Q4_K_XL/GLM-5.1-UD-Q4_K_XL-*.gguf"]
        ).sorted()
        XCTAssertEqual(files.count, 2)
        XCTAssertTrue(files[0].hasSuffix("GLM-5.1-UD-Q4_K_XL-00001-of-00011.gguf"))
        XCTAssertTrue(ModelStorageLayout.ggufFiles(in: modelDir, matching: ["UD-Q8_K_XL/*.gguf"]).isEmpty)
    }
}

final class ModelFitTests: XCTestCase {

    private func model(required: Double, weights: Double = 1) -> ModelDescriptor {
        ModelDescriptor(
            id: "m", name: "m", huggingFaceRepo: "o/m", parameterCount: "1B",
            quantization: .q4, estimatedSizeGB: weights, requiredRAMGB: required,
            family: "T", description: ""
        )
    }

    func testBudget() {
        XCTAssertEqual(ModelFit.budgetGB(totalRAMGB: 8), 4)      // RAM - 4 binds
        XCTAssertEqual(ModelFit.budgetGB(totalRAMGB: 16), 12)
        XCTAssertEqual(ModelFit.budgetGB(totalRAMGB: 32), 24)    // 0.75 x RAM binds
        XCTAssertEqual(ModelFit.budgetGB(totalRAMGB: 512), 384)
        XCTAssertEqual(ModelFit.budgetGB(totalRAMGB: 2), 1)      // floor
    }

    func testFitsUsesRequiredRAMOrWeightEstimate() {
        XCTAssertTrue(ModelFit.fits(model(required: 24), totalRAMGB: 32))
        XCTAssertFalse(ModelFit.fits(model(required: 28), totalRAMGB: 32))
        // Unknown footprint: 1.25 x weights, never 0.
        XCTAssertEqual(ModelFit.footprintGB(for: model(required: 0, weights: 20)), 25)
        XCTAssertFalse(ModelFit.fits(model(required: 0, weights: 20), totalRAMGB: 32))
    }

    func testHardwareBudgetDelegatesToModelFit() {
        let hw = HardwareCapability(
            chipFamily: .m4Pro, chipName: "Apple M4 Pro", totalRAMGB: 64,
            gpuCoreCount: 20, memoryBandwidthGBs: 273, tier: .tier1
        )
        XCTAssertEqual(hw.availableRAMForModelsGB, ModelFit.budgetGB(totalRAMGB: 64))
    }
}

final class ModelDescriptorFormatTests: XCTestCase {

    func testDecodesLegacyDescriptorWithoutFormatFields() throws {
        let json = """
        {"id":"x","name":"X","huggingFaceRepo":"org/x","parameterCount":"8B","quantization":"4bit",
         "estimatedSizeGB":4,"requiredRAMGB":10,"family":"Llama","description":"d","popularityRank":3,
         "openrouterId":"meta-llama/llama-3.1-8b-instruct"}
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(ModelDescriptor.self, from: json)
        XCTAssertEqual(decoded.format, .mlx)
        XCTAssertEqual(decoded.servingBackend, .mlx)
        XCTAssertNil(decoded.ggufFiles)
    }

    func testGGUFRoundTripAndDefaultBackend() throws {
        let model = ModelDescriptor(
            id: "g", name: "G", huggingFaceRepo: "org/g-GGUF", parameterCount: "8B",
            quantization: .q4, estimatedSizeGB: 4, requiredRAMGB: 6, family: "T",
            description: "", format: .gguf, ggufFiles: ["*.gguf"]
        )
        XCTAssertEqual(model.servingBackend, .llamaCpp)
        let decoded = try JSONDecoder().decode(ModelDescriptor.self, from: JSONEncoder().encode(model))
        XCTAssertEqual(decoded.format, .gguf)
        XCTAssertEqual(decoded.servingBackend, .llamaCpp)
        XCTAssertEqual(decoded.ggufFiles, ["*.gguf"])
    }

    func testAdvertisedIdOnlyForGatewaySlugs() {
        var model = ModelDescriptor(
            id: "p", name: "P", huggingFaceRepo: "mlx-community/phi-4-4bit", parameterCount: "14B",
            quantization: .q4, estimatedSizeGB: 8, requiredRAMGB: 14, family: "Phi",
            description: "", openrouterId: "microsoft/phi-4"
        )
        XCTAssertNil(model.advertisedId)
        model.openrouterId = "qwen/qwen3-8b"
        XCTAssertEqual(model.advertisedId, "qwen/qwen3-8b")
    }
}

final class OpenRouterIdResolverTests: XCTestCase {

    /// ids and aliases parsed from gateway/models.yaml (repo root).
    static func gatewayCatalogIdentifiers() throws -> Set<String> {
        let yamlURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // SharedTypesTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // mac-app
            .deletingLastPathComponent()  // repo root
            .appendingPathComponent("gateway/models.yaml")
        let text = try String(contentsOf: yamlURL, encoding: .utf8)
        var identifiers = Set<String>()
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("- id:") {
                let value = line.dropFirst("- id:".count)
                    .trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
                identifiers.insert(value.lowercased())
            } else if line.hasPrefix("aliases:"),
                      let open = line.firstIndex(of: "["),
                      let close = line.lastIndex(of: "]") {
                let list = line[line.index(after: open)..<close]
                for alias in list.split(separator: ",") {
                    let value = alias.trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
                    if !value.isEmpty { identifiers.insert(value.lowercased()) }
                }
            }
        }
        return identifiers
    }

    func testGatewayCatalogParses() throws {
        let identifiers = try Self.gatewayCatalogIdentifiers()
        XCTAssertTrue(identifiers.contains("meta-llama/llama-3.1-8b-instruct"))
        XCTAssertGreaterThan(identifiers.count, 20)
    }

    /// Every slug the resolver can emit for network advertising must be an
    /// id or alias the gateway knows.
    func testEverySlugExistsInGatewayCatalog() throws {
        let identifiers = try Self.gatewayCatalogIdentifiers()
        for slug in OpenRouterIdResolver.gatewaySlugs {
            XCTAssertTrue(identifiers.contains(slug), "\(slug) is not in gateway/models.yaml")
        }
        for (needle, slug) in OpenRouterIdResolver.heuristics {
            XCTAssertTrue(OpenRouterIdResolver.gatewaySlugs.contains(slug), "\(needle) -> \(slug) not in gatewaySlugs")
            XCTAssertTrue(identifiers.contains(slug), "\(needle) -> \(slug) is not in gateway/models.yaml")
        }
    }

    func testResolvesKnownNames() {
        XCTAssertEqual(OpenRouterIdResolver.resolve(filename: "Qwen3-32B-Q4_K_M.gguf"), "qwen/qwen3-32b")
        XCTAssertEqual(OpenRouterIdResolver.resolve(filename: "Meta-Llama-3.1-8B-Instruct-Q4_K_M.gguf"), "meta-llama/llama-3.1-8b-instruct")
        XCTAssertEqual(OpenRouterIdResolver.resolve(filename: "Hermes-3-Llama-3.1-8B.Q5_K_M.gguf"), "nousresearch/hermes-3-llama-3.1-8b")
        XCTAssertEqual(OpenRouterIdResolver.resolve(identifier: "mlx-community/gemma-3-27b-it-qat-4bit"), "google/gemma-3-27b-it")
        XCTAssertEqual(OpenRouterIdResolver.resolve(identifier: "deepseek-v4-flash"), "deepseek-ai/deepseek-v4-flash")
        XCTAssertEqual(OpenRouterIdResolver.resolve(identifier: "qwen3.6-35b"), "qwen/qwen3.6-35b-a3b")
        XCTAssertEqual(OpenRouterIdResolver.resolve(identifier: "qwen/qwen3.5-9b"), "qwen/qwen3.5-9b")
    }

    func testDoesNotAdvertiseModelsOutsideGatewayCatalog() {
        XCTAssertNil(OpenRouterIdResolver.resolve(identifier: "phi4-14b"))
        XCTAssertNil(OpenRouterIdResolver.resolve(identifier: "mistral-24b"))
        XCTAssertNil(OpenRouterIdResolver.resolve(identifier: "gpt-oss-20b"))
        XCTAssertNil(OpenRouterIdResolver.resolve(identifier: "DeepSeek-V4-Pro-IQ2XXS-w2Q2K-AProjQ8-SExpQ8-OutQ8-Instruct-imatrix.gguf"))
        XCTAssertNil(OpenRouterIdResolver.resolve(identifier: "/Users/x/models/unknown-model.gguf"))
    }
}
