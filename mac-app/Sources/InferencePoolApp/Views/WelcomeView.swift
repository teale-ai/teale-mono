import SwiftUI
import AppCore
import SharedTypes

/// First-launch welcome flow. Shown as a non-dismissible sheet over the main
/// window until the user picks a UserMode. Three cards → one click → done.
struct WelcomeView: View {
    @Environment(AppState.self) private var appState
    @State private var selected: UserMode?
    @State private var didConfirm = false

    var body: some View {
        VStack(spacing: 24) {
            header

            VStack(alignment: .leading, spacing: 12) {
                modeCard(
                    mode: .supplyOnly,
                    title: "Supply compute & earn",
                    subtitle: "Rent your idle Mac to the network. No chat UI — just the dashboard and your wallet.",
                    icon: "dollarsign.circle",
                    recommended: hardwareRecommendation == .supplyOnly
                )
                modeCard(
                    mode: .supplyAndAPI,
                    title: "Supply + local API",
                    subtitle: "Supply to the network and use your Mac as a local OpenAI-compatible endpoint on port 11435.",
                    icon: "terminal",
                    recommended: hardwareRecommendation == .supplyAndAPI
                )
                modeCard(
                    mode: .full,
                    title: "Full experience",
                    subtitle: "Everything above, plus the built-in chat window.",
                    icon: "bubble.left.and.bubble.right",
                    recommended: hardwareRecommendation == .full
                )
            }

            Spacer(minLength: 0)

            footer
        }
        .padding(32)
        .frame(width: 560, height: 620)
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 10) {
            Image(systemName: "brain.head.profile")
                .font(.system(size: 48, weight: .regular))
                .foregroundStyle(Color(red: 0.0, green: 0.6, blue: 0.6))

            Text("Welcome to Teale")
                .font(.largeTitle.weight(.semibold))

            Text(ramTagline)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    private var ramTagline: String {
        let ram = Int(appState.hardware.totalRAMGB.rounded())
        return "Your Mac has \(ram) GB unified memory. Pick how you'd like to use it."
    }

    // MARK: - Mode card

    @ViewBuilder
    private func modeCard(
        mode: UserMode,
        title: String,
        subtitle: String,
        icon: String,
        recommended: Bool
    ) -> some View {
        Button {
            selected = mode
        } label: {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: icon)
                    .font(.system(size: 22))
                    .foregroundStyle(selected == mode ? Color.white : Color.accentColor)
                    .frame(width: 36, height: 36)
                    .background(
                        Circle()
                            .fill(selected == mode ? Color.accentColor : Color.accentColor.opacity(0.12))
                    )

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(title).font(.headline)
                        if recommended {
                            Text("Recommended")
                                .font(.caption.weight(.semibold))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(Color.green.opacity(0.18)))
                                .foregroundStyle(Color.green)
                        }
                    }
                    Text(subtitle)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)

                Image(systemName: selected == mode ? "checkmark.circle.fill" : "circle")
                    .font(.title2)
                    .foregroundStyle(selected == mode ? Color.accentColor : Color.secondary.opacity(0.4))
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(selected == mode ? Color.accentColor.opacity(0.08) : Color.secondary.opacity(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(selected == mode ? Color.accentColor : Color.clear, lineWidth: 1.5)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 2) {
                if let starter = starterDownloadNote {
                    Text(starter)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text("You can change this any time in Settings.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            Button {
                confirm()
            } label: {
                Text("Continue")
                    .frame(minWidth: 120)
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
            .disabled(selected == nil || didConfirm)
        }
    }

    private var starterDownloadNote: String? {
        guard appState.downloadedModelIDs.isEmpty,
              appState.activeDownloads.isEmpty,
              appState.scannedGGUFModels.isEmpty,
              let starter = appState.modelManager.catalog
                .topModels(for: appState.hardware, limit: 1).first
        else { return nil }
        return "We'll start downloading \(starter.name) (\(Int(starter.requiredRAMGB.rounded())) GB) in the background."
    }

    private func confirm() {
        guard let mode = selected else { return }
        didConfirm = true
        appState.userMode = mode
        appState.contributeCompute = mode.suppliesCompute
        appState.currentView = mode.chatEnabled ? .chat : .dashboard
        appState.onboardingCompleted = true
        autoDownloadStarterModelIfNeeded()
    }

    /// Kick off a background download of the top catalog model for this Mac's
    /// RAM. No-op if the user already has a model downloaded, scanned locally,
    /// or in progress — those are all signals they're not a brand-new install.
    /// The download progresses in the Dashboard while the sheet dismisses, and
    /// auto-loads on completion (see AppState.downloadModel).
    private func autoDownloadStarterModelIfNeeded() {
        guard appState.downloadedModelIDs.isEmpty,
              appState.activeDownloads.isEmpty,
              appState.scannedGGUFModels.isEmpty,
              let starter = appState.modelManager.catalog
                .topModels(for: appState.hardware, limit: 1).first
        else { return }
        Task { await appState.downloadModel(starter) }
    }

    // MARK: - Hardware-aware recommendation

    /// Pick a sensible default to bias toward based on RAM. Small-RAM Macs
    /// (8 / 16 GB) tend to be laptops where supply-only is the most common
    /// use; Ultras have the headroom to run a local agent AND chat.
    private var hardwareRecommendation: UserMode {
        let ram = appState.hardware.totalRAMGB
        if ram >= 64 { return .full }
        if ram >= 24 { return .supplyAndAPI }
        return .supplyOnly
    }
}
