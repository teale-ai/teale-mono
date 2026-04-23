import SwiftUI
import AppCore
import AuthKit

struct CompanionHomeView: View {
    @Environment(AppState.self) private var appState
    let onNavigate: (CompanionTab) -> Void

    var body: some View {
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

                HStack(spacing: 10) {
                    TealeActionButton(title: "Open supply", primary: true) {
                        onNavigate(.supply)
                    }
                    TealeActionButton(title: "Open demand") {
                        onNavigate(.demand)
                    }
                    TealeActionButton(title: "Open wallet") {
                        onNavigate(.wallet)
                    }
                    TealeActionButton(title: "Open account") {
                        onNavigate(.account)
                    }
                }
                .padding(.top, 4)
            }
        }
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
