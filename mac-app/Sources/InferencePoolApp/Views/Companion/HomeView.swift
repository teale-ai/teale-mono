import SwiftUI
import AppCore
import AuthKit

struct CompanionHomeView: View {
    @Environment(AppState.self) private var appState
    @Environment(CompanionGatewayState.self) private var gatewayState
    let onNavigate: (CompanionTab) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            overviewSection
            networkSection
            threadSection
        }
    }

    private var overviewSection: some View {
        TealeSection(prompt: appState.companionText("home.overview", fallback: "overview")) {
            VStack(alignment: .leading, spacing: 14) {
                Text(appState.companionText("home.lede", fallback: "Teale turns this machine into a supply node and a demand client at the same time."))
                    .font(TealeDesign.mono)
                    .foregroundStyle(TealeDesign.text)
                    .fixedSize(horizontal: false, vertical: true)

                TealeStats {
                    TealeStatRow(
                        label: appState.companionText("common.state", fallback: "State"),
                        value: appState.companionState.displayText,
                        valueColor: appState.companionState.chipColor
                    )
                    TealeStatRow(
                        label: appState.companionText("common.model", fallback: "Model"),
                        value: currentModelLabel
                    )
                    TealeStatRow(
                        label: appState.companionText("common.wallet", fallback: "Wallet"),
                        value: walletLabel
                    )
                    TealeStatRow(
                        label: appState.companionText("common.account", fallback: "Account"),
                        value: accountLabel
                    )
                }

            }
        }
    }

    private var networkSection: some View {
        TealeSection(prompt: appState.companionText("home.network", fallback: "network")) {
            TealeStats {
                TealeStatRow(label: appState.companionText("common.totalDevices", fallback: "Total devices"), value: totalDevicesLabel)
                TealeStatRow(label: appState.companionText("common.totalRAM", fallback: "Total RAM"), value: totalRAMLabel)
                TealeStatRow(label: appState.companionText("common.totalModels", fallback: "Total models"), value: totalModelsLabel)
                TealeStatRow(label: appState.companionText("common.avgTTFT", fallback: "Avg TTFT"), value: averageTTFTLabel)
                TealeStatRow(
                    label: appState.companionText("common.avgTPS", fallback: "Avg TPS"),
                    value: averageTPSLabel,
                    note: appState.companionText("home.avgTPS.note", fallback: "Estimated from the hardware that is currently online.")
                )
                TealeStatRow(label: appState.companionEarnedTitle, value: totalCreditsEarnedLabel)
                TealeStatRow(label: appState.companionSpentTitle, value: totalCreditsSpentLabel)
                TealeStatRow(
                    label: appState.companionText("common.totalUSDCDistributed", fallback: "Total USDC distributed"),
                    value: totalUSDCDistributedLabel,
                    note: gatewayState.networkStats == nil
                        ? appState.companionText("home.waitingGatewayStats", fallback: "Waiting for live gateway stats.")
                        : nil
                )
            }
        }
    }

    private var threadSection: some View {
        CompanionHomeChatSection()
    }

    private var currentModelLabel: String {
        appState.engineStatus.currentModel?.name
            ?? appState.companionText("common.noModelLoaded", fallback: "No model loaded")
    }

    private var walletLabel: String {
        if let balanceCredits = gatewayState.walletBalance?.balanceCredits {
            return appState.companionDisplayAmountString(credits: balanceCredits)
        }
        return appState.companionText("wallet.loadingGateway", fallback: "Loading gateway wallet...")
    }

    private var accountLabel: String {
        guard let authManager = appState.authManager else {
            return appState.companionText("account.authUnavailable", fallback: "Auth unavailable")
        }
        let authState = authManager.authState
        guard authState.isAuthenticated else {
            return appState.companionText("account.notSignedIn", fallback: "Not signed in")
        }
        if let email = authManager.currentUser?.email {
            return "\(appState.companionText("account.signedIn", fallback: "Signed in")) · \(email)"
        }
        return appState.companionText("account.signedIn", fallback: "Signed in")
    }

    private var totalDevicesLabel: String {
        if let stats = gatewayState.networkStats {
            return "\(stats.totalDevices)"
        }
        return appState.companionTotalDevicesLabel
    }

    private var totalRAMLabel: String {
        if let stats = gatewayState.networkStats {
            return "\(Int(stats.totalRamGB.rounded())) GB"
        }
        return appState.companionTotalRAMLabel
    }

    private var totalModelsLabel: String {
        if let stats = gatewayState.networkStats {
            return "\(stats.totalModels)"
        }
        return appState.companionTotalModelsLabel
    }

    private var averageTTFTLabel: String {
        if let ttft = gatewayState.networkStats?.avgTtftMs {
            return "\(Int(ttft.rounded())) ms"
        }
        return appState.companionAverageTTFTLabel
    }

    private var averageTPSLabel: String {
        if let tps = gatewayState.networkStats?.avgTps {
            return String(format: "%.1f tok/s", tps)
        }
        return appState.companionAverageTPSLabel
    }

    private var totalUSDCDistributedLabel: String {
        if let cents = gatewayState.networkStats?.totalUsdcDistributedCents {
            let usd = Double(cents) / 100.0
            if appState.companionDisplayUnit == .usd {
                return String(format: "$%.2f", usd)
            }
            let credits = Int64((usd * CompanionDisplayUnit.creditsPerUSD).rounded())
            return appState.companionDisplayAmountString(credits: credits)
        }
        return "-"
    }

    private var totalCreditsEarnedLabel: String {
        if let earned = gatewayState.networkStats?.totalCreditsEarned {
            return appState.companionDisplayAmountString(credits: earned)
        }
        return appState.companionTotalCreditsEarnedLabel
    }

    private var totalCreditsSpentLabel: String {
        if let spent = gatewayState.networkStats?.totalCreditsSpent {
            return appState.companionDisplayAmountString(credits: spent)
        }
        return appState.companionTotalCreditsSpentLabel
    }
}
