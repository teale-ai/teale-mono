import ArgumentParser
import Foundation
import LocalAPI

struct Models: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Manage models on the Teale node",
        subcommands: [List.self, Load.self, Download.self, Unload.self]
    )

    @Option(name: .long, help: "Port of the running node")
    var port: Int = 11435

    @Option(name: .long, help: "API key for authenticated access")
    var apiKey: String?
}

extension Models {
    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List available models")

        @OptionGroup var parent: Models

        @Flag(name: .long, help: "Output as JSON")
        var json: Bool = false

        func run() async throws {
            let client = TealeClient(port: parent.port, apiKey: parent.apiKey)
            let snapshot = try await client.snapshot()

            if json {
                let data = try JSONEncoder.prettyPrinting.encode(snapshot.models)
                print(String(data: data, encoding: .utf8) ?? "[]")
                return
            }

            let sorted = snapshot.models.sorted { a, b in
                if a.loaded != b.loaded { return a.loaded }
                if a.downloaded != b.downloaded { return a.downloaded }
                return a.name < b.name
            }

            for model in sorted {
                var status = ""
                if model.loaded {
                    status = " [loaded]"
                } else if model.downloaded {
                    status = " [downloaded]"
                } else if let progress = model.downloadingProgress {
                    status = " [downloading \(Int(progress * 100))%]"
                }
                print("  \(model.id)\(status)")
                print("    \(model.huggingFaceRepo)")
            }

            let downloaded = sorted.filter(\.downloaded).count
            print("\n\(downloaded)/\(sorted.count) models downloaded")
        }
    }

    struct Load: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Load a model into GPU memory")

        @OptionGroup var parent: Models

        @Argument(help: "Model ID or HuggingFace repo")
        var model: String

        @Flag(name: .long, help: "Download the model first if not already downloaded")
        var download: Bool = false

        func run() async throws {
            let client = TealeClient(port: parent.port, apiKey: parent.apiKey)
            let snapshot = try await client.loadModel(model, downloadIfNeeded: download)
            if let loaded = snapshot.loadedModelRepo {
                print("Loaded: \(loaded)")
            } else {
                print("Model load requested. Status: \(snapshot.engineStatus)")
            }
        }
    }

    struct Download: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Download a model")

        @OptionGroup var parent: Models

        @Argument(help: "Model ID or HuggingFace repo")
        var model: String

        func run() async throws {
            let client = TealeClient(port: parent.port, apiKey: parent.apiKey)
            print("Downloading \(model)...")
            let snapshot = try await client.downloadModel(model)
            let downloaded = snapshot.models.first(where: { $0.id == model || $0.huggingFaceRepo == model })
            if downloaded?.downloaded == true {
                print("Download complete.")
            } else {
                print("Download started. Use `teale status` to check progress.")
            }
        }
    }

    struct Unload: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Unload the current model from GPU memory")

        @OptionGroup var parent: Models

        func run() async throws {
            let client = TealeClient(port: parent.port, apiKey: parent.apiKey)
            _ = try await client.unloadModel()
            print("Model unloaded.")
        }
    }
}

private extension JSONEncoder {
    static var prettyPrinting: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}
