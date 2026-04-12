import ArgumentParser
import Foundation
import AppCore
import SharedTypes

struct Up: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Start the Teale node and join the inference network"
    )

    @Option(name: .long, help: "HTTP server port")
    var port: Int = 11435

    @Flag(name: .long, help: "Maximize earnings: keep awake, auto-manage models, more storage")
    var maximizeEarnings: Bool = false

    @Option(name: .long, help: "Override auto-selected model (ID or HuggingFace repo)")
    var model: String?

    @Flag(name: .long, help: "Re-run the first-time setup")
    var setup: Bool = false

    func run() async throws {
        setenv("CI_DISABLE_NETWORK_MONITOR", "1", 1)

        var config = NodeConfig.load()

        // First-run setup (or --setup flag)
        if !config.setupComplete || setup {
            config = runSetup(existing: config)
        }

        // CLI flag overrides saved config
        let useMaxEarnings = maximizeEarnings || config.maximizeEarnings

        printErr("Starting Teale node...")

        let appState = await MainActor.run { AppState(autoStart: false) }

        // Apply settings
        await MainActor.run {
            appState.serverPort = port

            if useMaxEarnings {
                appState.keepAwake = true
                appState.autoManageModels = true
                if appState.maxStorageGB < 100 {
                    appState.maxStorageGB = 100
                }
            }
        }

        // Start core services
        await appState.startServer()
        await appState.initializeAsync()

        // Enable networking
        await MainActor.run {
            appState.clusterEnabled = true
            appState.wanEnabled = true
        }

        // Select and load model
        let modelID = model
        let chosenModel = await selectAndLoadModel(appState: appState, override: modelID)

        // Wait briefly for WAN to connect
        await waitForWAN(appState: appState)

        // Write PID file for `teale down`
        PIDFile.write()

        // Start credit forwarding if configured
        let forwardAddress = config.forwardEarningsTo
        var forwardingTask: Task<Void, Never>?
        if let address = forwardAddress {
            forwardingTask = startCreditForwarding(appState: appState, toAddress: address)
        }

        // Print status
        let hw = await MainActor.run { appState.hardware }
        let wanErr = await MainActor.run { appState.wanLastError }
        let wanBusy = await MainActor.run { appState.isWANBusy }
        let wanDiag = await MainActor.run { appState.wanManager.enableDiagnostics }

        printErr("")
        printErr("Teale node is up.")
        printErr("  API:     http://127.0.0.1:\(port)/v1/chat/completions")
        if let m = chosenModel {
            printErr("  Model:   \(m.name) (\(m.parameterCount), \(m.quantization.rawValue))")
        } else {
            printErr("  Model:   (none)")
        }
        if let err = wanErr {
            printErr("  WAN:     error - \(err)")
        } else if wanBusy {
            printErr("  WAN:     connecting...")
        } else {
            printErr("  WAN:     connected")
        }
        // Show WAN diagnostics if there were issues
        if !wanDiag.isEmpty && (wanErr != nil || wanBusy) {
            for line in wanDiag {
                printErr("           \(line)")
            }
        }
        printErr("  Cluster: enabled")
        printErr("  Chip:    \(hw.chipName) (\(Int(hw.totalRAMGB)) GB)")
        if useMaxEarnings {
            let storage = await MainActor.run { appState.maxStorageGB }
            printErr("  Mode:    maximize earnings (keep-awake, auto-manage, \(Int(storage)) GB storage)")
        }
        if let address = forwardAddress {
            printErr("  Wallet:  forwarding earnings to \(address)")
        } else {
            printErr("  Wallet:  local (earnings stay on this device)")
        }
        printErr("")
        printErr("Press Ctrl+C to stop")

        await awaitShutdownSignal()

        printErr("\nShutting down...")
        forwardingTask?.cancel()
        PIDFile.remove()
    }

    // MARK: - First-Run Setup

    private func runSetup(existing: NodeConfig) -> NodeConfig {
        var config = existing

        print("")
        print("Welcome to Teale! Let's set up your inference node.")
        print("")

        // Earnings mode
        print("How should this node run?")
        print("  1) Standard (default)")
        print("  2) Maximize earnings (keep awake, auto-manage models, more storage)")
        print("")
        print("Choice [1]: ", terminator: "")
        let earningsChoice = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        config.maximizeEarnings = (earningsChoice == "2")

        if config.maximizeEarnings {
            print("  -> Maximize earnings mode enabled.")
        } else {
            print("  -> Standard mode. You can switch later with --maximize-earnings.")
        }
        print("")

        // Wallet forwarding
        print("Where should this node's earnings go?")
        print("  1) Keep on this device (default)")
        print("  2) Forward to another wallet address")
        print("")
        print("Choice [1]: ", terminator: "")
        let walletChoice = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        if walletChoice == "2" {
            print("Wallet address to forward earnings to: ", terminator: "")
            let address = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !address.isEmpty {
                config.forwardEarningsTo = address
                print("  -> Earnings will be forwarded to \(address).")
            } else {
                config.forwardEarningsTo = nil
                print("  -> No address entered. Earnings will stay on this device.")
            }
        } else {
            config.forwardEarningsTo = nil
            print("  -> Earnings will stay on this device's local wallet.")
        }

        print("")
        print("Setup complete! Starting your node...")
        print("")

        config.setupComplete = true
        config.save()
        return config
    }

    // MARK: - Credit Forwarding

    /// Periodically checks wallet balance and forwards earnings to the configured address.
    private func startCreditForwarding(appState: AppState, toAddress: String) -> Task<Void, Never> {
        Task {
            // Check every 60 seconds for new earnings to forward
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                guard !Task.isCancelled else { break }

                let balance = await appState.wallet.currentBalance()
                // Forward if balance exceeds a minimum threshold (avoid dust transfers)
                let threshold = 1.0
                if balance.value > threshold {
                    let amount = balance.value - 0.01 // keep a tiny reserve
                    guard amount > 0 else { continue }

                    let success = await appState.wallet.sendTransfer(
                        amount: amount,
                        toPeer: toAddress,
                        memo: "Auto-forward to \(toAddress)"
                    )
                    if success {
                        printErr("Forwarded \(String(format: "%.2f", amount)) credits to \(toAddress)")
                    }
                }
            }
        }
    }

    // MARK: - Model Selection

    private func selectAndLoadModel(appState: AppState, override: String?) async -> ModelDescriptor? {
        let compatible = await appState.modelManager.compatibleModels

        if let override {
            if let descriptor = compatible.first(where: { $0.id == override || $0.huggingFaceRepo == override }) {
                await downloadAndLoad(appState: appState, model: descriptor)
                return descriptor
            }
            printErr("Warning: Model '\(override)' not found in catalog.")
            return nil
        }

        // Auto-select: prefer already-downloaded, then top by popularity
        var downloaded: [ModelDescriptor] = []
        for model in compatible {
            if await appState.modelManager.isDownloaded(model) {
                downloaded.append(model)
            }
        }

        let best: ModelDescriptor?
        if let top = downloaded.sorted(by: { $0.popularityRank < $1.popularityRank }).first {
            best = top
        } else {
            best = compatible.sorted(by: { $0.popularityRank < $1.popularityRank }).first
        }

        guard let model = best else {
            printErr("No compatible models found for this hardware.")
            return nil
        }

        await downloadAndLoad(appState: appState, model: model)
        return model
    }

    private func downloadAndLoad(appState: AppState, model: ModelDescriptor) async {
        let isDownloaded = await appState.modelManager.isDownloaded(model)

        if !isDownloaded {
            printErr("Downloading \(model.name) (\(String(format: "%.1f", model.estimatedSizeGB)) GB)...")
            await appState.downloadModel(model)
            printErr("Download complete.")
        }

        printErr("Loading \(model.name)...")
        await appState.loadModel(model)
    }

    // MARK: - WAN Wait

    private func waitForWAN(appState: AppState, timeout: TimeInterval = 8) async {
        let start = Date()
        while Date().timeIntervalSince(start) < timeout {
            let busy = await MainActor.run { appState.isWANBusy }
            if !busy { return }
            try? await Task.sleep(for: .milliseconds(200))
        }
    }
}
