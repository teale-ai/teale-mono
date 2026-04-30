import ArgumentParser
import Foundation
import AppCore
import ModelManager

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
        let originalPersistedWAN = UserDefaults.standard.bool(forKey: "teale.wanEnabled")

        // Apply CLI flags
        await MainActor.run {
            appState.serverPort = port
            if cluster { appState.clusterEnabled = true }
        }

        if wan {
            UserDefaults.standard.set(false, forKey: "teale.wanEnabled")
        }

        // Start server and initialize
        await appState.startServer()
        await appState.initializeAsync()

        // Auto-load the local model before WAN bootstrap so the first relay
        // registration advertises the canonical slug instead of an empty
        // loaded-model set during MLX warmup.
        if let modelID = model {
            await autoLoadModel(modelID, appState: appState)
        }

        // Enable WAN after initialization and any requested auto-load
        // (needs identity). Only set if not already enabled from persisted
        // defaults to avoid double toggleWAN.
        if wan {
            UserDefaults.standard.set(true, forKey: "teale.wanEnabled")
            let alreadyEnabled = await MainActor.run { appState.wanEnabled }
            if !alreadyEnabled {
                await MainActor.run { appState.wanEnabled = true }
            }
        } else if originalPersistedWAN {
            UserDefaults.standard.set(true, forKey: "teale.wanEnabled")
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
        let localModel = await MainActor.run { () -> LocalModelInfo? in
            appState.scanLocalModels()
            return appState.scannedLocalModels.first(where: {
                let descriptor = $0.toDescriptor()
                return descriptor.id == modelID
                    || descriptor.huggingFaceRepo == modelID
                    || $0.path.path == modelID
                    || $0.path.lastPathComponent == modelID
                    || $0.name == modelID
            })
        }
        if let localModel {
            printErr("Loading local MLX model \(localModel.name)...")
            await appState.loadLocalModel(localModel)
            let status = await MainActor.run { appState.engineStatus }
            if case .ready = status {
                printErr("Local model loaded: \(localModel.name)")
            } else if case .error(let message) = status {
                printErr("Local model failed to load: \(message)")
            }
            return
        }

        let models = await appState.modelManager.compatibleModels
        guard let descriptor = models.first(where: { $0.id == modelID || $0.huggingFaceRepo == modelID }) else {
            printErr("Warning: Model '\(modelID)' not found in catalog or scanned local models. Skipping auto-load.")
            return
        }

        let isDownloaded = await appState.modelManager.isDownloaded(descriptor)
        if !isDownloaded {
            printErr("Downloading \(descriptor.name)...")
            await appState.downloadModel(descriptor)
        }

        printErr("Loading \(descriptor.name)...")
        await appState.loadModel(descriptor)
        let status = await MainActor.run { appState.engineStatus }
        if case .ready = status {
            printErr("Model loaded: \(descriptor.name)")
        } else if case .error(let message) = status {
            printErr("Model failed to load: \(message)")
        }
    }
}
