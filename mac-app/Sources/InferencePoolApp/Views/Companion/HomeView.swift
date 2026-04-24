import SwiftUI
import AppCore
import AuthKit

struct CompanionHomeView: View {
    @Environment(AppState.self) private var appState
    let onNavigate: (CompanionTab) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            overviewSection
            networkSection
            threadSection
        }
    }

    private var overviewSection: some View {
        TealeSection(prompt: "overview") {
            VStack(alignment: .leading, spacing: 14) {
                Text("Teale turns this machine into a supply node and a demand client at the same time.")
                    .font(TealeDesign.mono)
                    .foregroundStyle(TealeDesign.text)
                    .fixedSize(horizontal: false, vertical: true)

                TealeStats {
                    TealeStatRow(
                        label: "State",
                        value: appState.companionState.displayText,
                        valueColor: appState.companionState.chipColor
                    )
                    TealeStatRow(
                        label: "Model",
                        value: currentModelLabel
                    )
                    TealeStatRow(
                        label: "Wallet",
                        value: walletLabel
                    )
                    TealeStatRow(
                        label: "Account",
                        value: accountLabel
                    )
                }

            }
        }
    }

    private var networkSection: some View {
        TealeSection(prompt: "network") {
            TealeStats {
                TealeStatRow(label: "Total devices", value: appState.companionTotalDevicesLabel)
                TealeStatRow(label: "Total RAM", value: appState.companionTotalRAMLabel)
                TealeStatRow(label: "Total models", value: appState.companionTotalModelsLabel)
                TealeStatRow(label: "Avg TTFT", value: appState.companionAverageTTFTLabel)
                TealeStatRow(
                    label: "Avg TPS",
                    value: appState.companionAverageTPSLabel,
                    note: "Estimated from the hardware that is currently online."
                )
                TealeStatRow(label: "Total credits earned", value: appState.companionTotalCreditsEarnedLabel)
                TealeStatRow(label: "Total credits spent", value: appState.companionTotalCreditsSpentLabel)
                TealeStatRow(
                    label: "Total USDC distributed",
                    value: appState.companionTotalUSDCDistributedLabel,
                    note: "Gateway-wide settlement totals still are not surfaced on mac."
                )
            }

            Text(appState.companionHomeNetworkNote)
                .font(TealeDesign.monoSmall)
                .foregroundStyle(TealeDesign.muted)
                .padding(.top, 10)
        }
    }

    private var threadSection: some View {
        CompanionHomeChatSection()
    }

    private var currentModelLabel: String {
        appState.engineStatus.currentModel?.name ?? "No model loaded"
    }

    private var walletLabel: String {
        let balance = appState.wallet.balance
        return "\(balance.description) credits"
    }

    private var accountLabel: String {
        let authState = appState.authManager?.authState
        guard let authState, authState.isAuthenticated else {
            return "Not signed in"
        }
        if let email = appState.authManager?.currentUser?.email {
            return "Signed in · \(email)"
        }
        return "Signed in"
    }
}
