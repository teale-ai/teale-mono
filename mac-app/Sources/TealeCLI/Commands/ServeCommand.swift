import ArgumentParser
import Foundation
import AppCore

struct Serve: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Start the Teale inference node (headless daemon)"
    )

    @Option(name: .long, help: "HTTP server port")
    var port: Int = 11435

    @Flag(name: .long, help: "Enable LAN cluster")
    var cluster: Bool = false

    @Flag(name: .long, help: "Enable WAN P2P networking")
    var wan: Bool = false

    @Option(name: .long, help: "Model to auto-load on startup (ID or HuggingFace repo)")
    var model: String?

    func run() async throws {
        // Suppress Hub library's offline mode detection
        setenv("CI_DISABLE_NETWORK_MONITOR", "1", 1)

        printErr("Starting Teale node...")

        let appState = await MainActor.run { AppState(autoStart: false) }

        // Apply CLI flags
        await MainActor.run {
            appState.serverPort = port
            if cluster { appState.clusterEnabled = true }
        }

        // Start server and initialize
        await appState.startServer()
        await appState.initializeAsync()

        // Enable WAN after initialization (needs identity)
        if wan {
            await MainActor.run { appState.wanEnabled = true }
        }

        // Auto-load model if specified
        if let modelID = model {
            await autoLoadModel(modelID, appState: appState)
        }

        printErr("Teale node running on port \(port)")
        printErr("API: http://127.0.0.1:\(port)/v1/chat/completions")
        if cluster { printErr("LAN cluster: enabled") }
        if wan { printErr("WAN P2P: enabled") }
        printErr("Press Ctrl+C to stop")

        await awaitShutdownSignal()
        printErr("\nShutting down...")
    }

    private func autoLoadModel(_ modelID: String, appState: AppState) async {
        let models = await appState.modelManager.compatibleModels
        guard let descriptor = models.first(where: { $0.id == modelID || $0.huggingFaceRepo == modelID }) else {
            printErr("Warning: Model '\(modelID)' not found in catalog. Skipping auto-load.")
            return
        }

        let isDownloaded = await appState.modelManager.isDownloaded(descriptor)
        if !isDownloaded {
            printErr("Downloading \(descriptor.name)...")
            await appState.downloadModel(descriptor)
        }

        printErr("Loading \(descriptor.name)...")
        await appState.loadModel(descriptor)
        printErr("Model loaded: \(descriptor.name)")
    }
}
