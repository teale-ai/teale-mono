import SwiftUI
import TealeSDK
import CreditKit
import SharedTypes

// MARK: - Earnings Dashboard View

/// Shows contribution stats, earnings, and device status.
struct EarningsDashboardView: View {
    @Bindable var contributor: TealeContributor

    var body: some View {
        VStack(spacing: 20) {
            // Status indicator
            statusSection

            // Earnings
            earningsSection

            // Stats
            statsSection

            Spacer()

            // Opt-out
            Button("Stop Contributing") {
                Task { await contributor.revokeConsent() }
            }
            .buttonStyle(.plain)
            .foregroundStyle(.red)
            .font(.footnote)
        }
        .padding(20)
    }

    // MARK: - Status

    @ViewBuilder
    private var statusSection: some View {
        HStack {
            Circle()
                .fill(statusColor)
                .frame(width: 10, height: 10)
            Text(statusText)
                .font(.subheadline)
                .fontWeight(.medium)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 8))
    }

    private var statusColor: Color {
        switch contributor.state {
        case .contributing: return .green
        case .paused: return .orange
        case .connecting: return .blue
        case .error: return .red
        default: return .gray
        }
    }

    private var statusText: String {
        switch contributor.state {
        case .contributing(let info):
            if let model = info.currentModel {
                return "Contributing (\(model))"
            }
            return "Contributing"
        case .paused(let reason):
            return "Paused: \(reasonText(reason))"
        case .connecting:
            return "Connecting..."
        case .error(let msg):
            return "Error: \(msg)"
        default:
            return "Idle"
        }
    }

    private func reasonText(_ reason: PauseReason) -> String {
        switch reason {
        case .thermal: return "Device is warm"
        case .battery: return "Low battery"
        case .lowPowerMode: return "Low Power Mode"
        case .userActive: return "Device in use"
        case .networkUnavailable: return "No network"
        case .scheduledOff: return "Outside schedule"
        case .notPluggedIn: return "Not plugged in"
        case .notOnWiFi: return "Not on Wi-Fi"
        }
    }

    // MARK: - Earnings

    @ViewBuilder
    private var earningsSection: some View {
        VStack(spacing: 8) {
            Text(contributor.earnings.totalCredits.description)
                .font(.system(size: 36, weight: .bold, design: .rounded))
            Text("USDC Earned")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
        .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Stats

    @ViewBuilder
    private var statsSection: some View {
        HStack(spacing: 16) {
            StatCard(title: "Requests", value: "\(contributor.earnings.requestsServed)")
            StatCard(title: "Tokens", value: formatTokens(contributor.earnings.tokensGenerated))
        }
    }

    private func formatTokens(_ count: Int) -> String {
        if count >= 1_000_000 { return String(format: "%.1fM", Double(count) / 1_000_000) }
        if count >= 1_000 { return String(format: "%.1fK", Double(count) / 1_000) }
        return "\(count)"
    }
}

// MARK: - Stat Card

private struct StatCard: View {
    let title: String
    let value: String

    var body: some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.title3)
                .fontWeight(.semibold)
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 8))
    }
}
