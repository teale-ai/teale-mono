import SwiftUI
import TealeSDK

// MARK: - Consent Prompt View

/// Pre-built opt-in UI for user consent. Shows a clear explanation of what
/// resource contribution means and lets the user enable or decline.
struct ConsentPromptView: View {
    @Bindable var contributor: TealeContributor

    var body: some View {
        VStack(spacing: 24) {
            // Icon
            Image(systemName: "bolt.shield.fill")
                .font(.system(size: 48))
                .foregroundStyle(.tint)

            // Headline
            Text("Power AI with your idle device")
                .font(.title2)
                .fontWeight(.semibold)
                .multilineTextAlignment(.center)

            // Explanation
            VStack(alignment: .leading, spacing: 12) {
                BulletPoint(
                    icon: "cpu",
                    text: "When your device is idle, it can help run AI inference for the Teale network"
                )
                BulletPoint(
                    icon: "lock.shield",
                    text: "Your personal data is never accessed or shared"
                )
                BulletPoint(
                    icon: "arrow.counterclockwise",
                    text: "You can opt out at any time from this screen"
                )
                BulletPoint(
                    icon: "battery.100.bolt",
                    text: "Only runs when plugged in and on Wi-Fi (configurable)"
                )
            }
            .padding(.horizontal)

            Spacer()

            // Action buttons
            VStack(spacing: 12) {
                Button {
                    Task { await contributor.grantConsent() }
                } label: {
                    Text("Enable")
                        .frame(maxWidth: .infinity)
                        .fontWeight(.semibold)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                Button("Not Now") {
                    // Dismiss — consent stays revoked, SDK stays dormant
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
        }
        .padding(24)
    }
}

// MARK: - Bullet Point

private struct BulletPoint: View {
    let icon: String
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .frame(width: 24)
                .foregroundStyle(.secondary)
            Text(text)
                .font(.subheadline)
                .foregroundStyle(.primary)
        }
    }
}
