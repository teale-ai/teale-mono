import Foundation
import SharedTypes
import HardwareProfile
import InferenceEngine
import MLXInference
import WANKit
import CreditKit

// MARK: - Teale Contributor

/// The single entry point for third-party developers to integrate Teale resource contribution.
///
/// Usage:
/// ```swift
/// let teale = TealeContributor(
///     appID: "com.example.mygame",
///     developerWalletID: "wallet_abc123",
///     options: .init(maxRAMContribution: .percent(50), schedule: .afterHours)
/// )
/// // In your Settings view:
/// TealeContributionView(contributor: teale)
/// ```
@MainActor
@Observable
public final class TealeContributor {
    // MARK: - Public Configuration

    public let appID: String
    public let developerWalletID: String
    public let options: ContributionOptions

    // MARK: - Public Observable State

    public private(set) var state: ContributorState = .idle
    public private(set) var isContributing: Bool = false
    public private(set) var hasUserConsent: Bool = false
    public private(set) var earnings: ContributionEarnings = ContributionEarnings()

    // MARK: - Internal Components

    private let consentManager: ConsentManager
    private var hardware: HardwareCapability?
    private var throttler: AdaptiveThrottler?
    private var resourceGovernor: ResourceGovernor?
    private var wanManager: WANManager?
    private var wallet: USDCWallet?
    private var inferenceProvider: MLXProvider?
    private var wanBridge: SDKWANBridge?
    private var earningsReporter: EarningsReporter?
    private var backgroundScheduler: BackgroundScheduler?
    private var contributionTask: Task<Void, Never>?
    private var startTime: Date?

    // MARK: - Init

    public init(
        appID: String,
        developerWalletID: String,
        options: ContributionOptions = ContributionOptions()
    ) {
        self.appID = appID
        self.developerWalletID = developerWalletID
        self.options = options
        self.consentManager = ConsentManager(appID: appID)

        // Check persisted consent (sync read from UserDefaults)
        Task { @MainActor [weak self] in
            guard let self = self else { return }
            let consented = await self.consentManager.hasConsent()
            self.hasUserConsent = consented
            if !consented {
                self.state = .waitingForConsent
            }
        }
    }

    // MARK: - Public Control

    /// Grant user consent and start contributing.
    public func grantConsent() async {
        await consentManager.grantConsent()
        hasUserConsent = true
        try? await start()
    }

    /// Revoke user consent and stop all activity.
    public func revokeConsent() async {
        await consentManager.revokeConsent()
        hasUserConsent = false
        await stop()
        state = .waitingForConsent
    }

    /// Begin contributing resources to the Teale network.
    /// Requires consent to have been granted.
    public func start() async throws {
        guard hasUserConsent else {
            state = .waitingForConsent
            return
        }

        state = .connecting

        do {
            // 1. Detect hardware
            let hw = HardwareDetector().detect()
            self.hardware = hw

            // 2. Set up throttler with developer's schedule
            let throttler = AdaptiveThrottler()
            throttler.updateSchedule(options.toContributionSchedule())
            self.throttler = throttler

            // 3. Set up resource governor
            let governor = ResourceGovernor(options: options, hardware: hw, throttler: throttler)
            self.resourceGovernor = governor

            // 4. Select and load a model
            guard let model = SDKModelSelector.selectModel(
                hardware: hw,
                maxRAMGB: await governor.maxRAMGB,
                allowedFamilies: options.allowedModelFamilies
            ) else {
                state = .error("No suitable model for this device")
                return
            }

            let provider = MLXProvider()
            try await provider.loadModel(model)
            self.inferenceProvider = provider

            // 5. Set up credit wallet
            let ledger = await USDCLedger()
            let wallet = USDCWallet(ledger: ledger)
            await wallet.refreshBalance()
            self.wallet = wallet

            // 6. Set up earnings reporter
            let deviceID = UUID()  // Stable device ID would come from Keychain in production
            let reporter = EarningsReporter(
                appID: appID,
                developerWalletID: developerWalletID,
                deviceID: deviceID
            )
            self.earningsReporter = reporter

            // 7. Set up WAN
            let identity = WANNodeIdentity()
            let wanConfig = WANConfig(identity: identity, displayName: "\(appID)-contributor")
            let wan = WANManager()

            let deviceInfo = DeviceInfo(
                id: deviceID,
                name: "\(appID)-contributor",
                hardware: hw,
                loadedModels: [model.id]
            )
            try await wan.enable(config: wanConfig, localDeviceInfo: deviceInfo)
            self.wanManager = wan

            // 8. Wire up the bridge
            let bridge = SDKWANBridge(
                wanManager: wan,
                inferenceProvider: provider,
                wallet: wallet,
                resourceGovernor: governor,
                earningsReporter: reporter
            )
            await bridge.setCurrentModel(model)
            await bridge.start()
            self.wanBridge = bridge

            // 9. Set up background scheduler
            let scheduler = BackgroundScheduler(appID: appID) { [weak self] in
                guard let self = self else { return }
                // Re-evaluate conditions and serve if possible
                await self.updateContributionState()
            }
            scheduler.registerBackgroundTasks()
            self.backgroundScheduler = scheduler

            // 10. Start contribution monitoring loop
            startTime = Date()
            startContributionLoop()

            isContributing = true
            state = .contributing(ContributionInfo(currentModel: model.name))
        } catch {
            state = .error(error.localizedDescription)
            throw error
        }
    }

    /// Stop contributing and release all resources.
    public func stop() async {
        contributionTask?.cancel()
        contributionTask = nil

        await wanBridge?.stop()
        await wanManager?.disable()
        await inferenceProvider?.unloadModel()

        wanBridge = nil
        wanManager = nil
        inferenceProvider = nil
        throttler = nil
        resourceGovernor = nil
        wallet = nil
        earningsReporter = nil
        backgroundScheduler = nil
        startTime = nil

        isContributing = false
        if hasUserConsent {
            state = .idle
        }
    }

    // MARK: - Contribution Loop

    private func startContributionLoop() {
        contributionTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 30 * 1_000_000_000)
                guard let self = self else { return }
                await self.updateContributionState()
            }
        }
    }

    private func updateContributionState() async {
        guard let throttler = throttler, let wallet = wallet else { return }

        // Check if we should pause
        if !throttler.shouldAllowNetworkContribution {
            if let reason = throttler.networkPauseReason {
                state = .paused(reason)
                isContributing = false
            }
            return
        }

        // We're good to contribute
        isContributing = true
        await wallet.refreshBalance()

        let bridgeStats = await wanBridge?.stats ?? (requests: 0, tokens: 0)
        let uptime = startTime.map { Date().timeIntervalSince($0) } ?? 0

        earnings = ContributionEarnings(
            totalCredits: wallet.totalEarned,
            todayCredits: wallet.totalEarned,  // TODO: filter by today
            requestsServed: bridgeStats.requests,
            tokensGenerated: bridgeStats.tokens
        )

        state = .contributing(ContributionInfo(
            connectedPeers: wanManager?.state.connectedPeers.count ?? 0,
            requestsServed: bridgeStats.requests,
            tokensGenerated: bridgeStats.tokens,
            creditsEarned: wallet.totalEarned,
            currentModel: await inferenceProvider?.loadedModel?.name,
            uptime: uptime
        ))
    }
}
