import SwiftUI
import ChatKit

// MARK: - Bubble Role

/// Visual role of a bubble. Drives color + alignment + corner shape.
enum BubbleRole {
    /// Sent by the local user — right-aligned, Teal filled, white text.
    case me
    /// Sent by another human participant — left-aligned, gray filled.
    case them
    /// Sent by the AI (orchestrator) — left-aligned, teal-light filled.
    case ai
}

// MARK: - Chat Bubble

/// A single message bubble rendered in iMessage/Signal-style with Teale
/// branding. Callers decide whether to show the sender label / timestamp
/// (typically only on the first/last bubble of a run).
struct ChatBubble: View {
    let content: String
    let role: BubbleRole
    let senderLabel: String?
    let timestamp: Date?
    let isFirstInRun: Bool
    let isLastInRun: Bool

    var body: some View {
        switch role {
        case .ai:
            aiCenteredCard
        case .me:
            sideBubble
        case .them:
            sideBubble
        }
    }

    // MARK: - Side-aligned bubble (me right, them left)

    private var sideBubble: some View {
        HStack(alignment: .bottom, spacing: 6) {
            if role == .me { Spacer(minLength: 56) }

            VStack(alignment: role == .me ? .trailing : .leading, spacing: 2) {
                if let senderLabel, isFirstInRun, role == .them {
                    Text(senderLabel)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.leading, 10)
                }

                Text(content)
                    .textSelection(.enabled)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(background)
                    .clipShape(bubbleShape)
                    .foregroundStyle(foreground)

                if let timestamp, isLastInRun {
                    Text(timestamp, style: .time)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 6)
                }
            }

            if role != .me { Spacer(minLength: 56) }
        }
        .padding(.horizontal, 10)
        .padding(.top, isFirstInRun ? 6 : 1)
        .padding(.bottom, isLastInRun ? 4 : 0)
    }

    // MARK: - AI centered card

    private var aiCenteredCard: some View {
        HStack {
            Spacer(minLength: 0)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 4) {
                    Image(systemName: "sparkles")
                        .font(.caption2)
                        .foregroundStyle(Color.teale)
                    Text("Teale")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Color.teale)
                    Spacer(minLength: 0)
                }
                Text(content)
                    .textSelection(.enabled)
                    .font(.body)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(12)
            .frame(maxWidth: 320, alignment: .leading)
            .background(
                LinearGradient(
                    colors: [Color.teale.opacity(0.12), Color.teale.opacity(0.04)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                in: RoundedRectangle(cornerRadius: 14)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(Color.teale.opacity(0.25), lineWidth: 0.8)
            )
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.top, isFirstInRun ? 6 : 1)
        .padding(.bottom, isLastInRun ? 4 : 0)
        .overlay(alignment: .bottomTrailing) {
            if let timestamp, isLastInRun {
                Text(timestamp, style: .time)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .padding(.trailing, 22)
                    .padding(.bottom, -2)
            }
        }
    }

    // MARK: - Side-bubble styling

    @ViewBuilder private var background: some View {
        switch role {
        case .me:
            Color.teale
        case .them:
            Color.gray.opacity(0.18)
        case .ai:
            Color.tealeLight
        }
    }

    private var foreground: Color {
        switch role {
        case .me: return .white
        case .them, .ai: return .primary
        }
    }

    private var bubbleShape: some Shape {
        let big: CGFloat = 18
        let small: CGFloat = isLastInRun ? 4 : big
        switch role {
        case .me:
            return UnevenRoundedRectangle(cornerRadii: RectangleCornerRadii(
                topLeading: big,
                bottomLeading: big,
                bottomTrailing: small,
                topTrailing: big
            ))
        case .them, .ai:
            return UnevenRoundedRectangle(cornerRadii: RectangleCornerRadii(
                topLeading: big,
                bottomLeading: small,
                bottomTrailing: big,
                topTrailing: big
            ))
        }
    }
}

// MARK: - Tool call / result inline rows

struct ToolCallInlineRow: View {
    let content: String

    private var call: ToolCall? {
        guard let data = content.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(ToolCall.self, from: data)
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "wrench.and.screwdriver.fill")
                .foregroundStyle(.orange)
                .font(.caption)
            Text("Calling \(call?.tool ?? "tool")…")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
    }
}

struct ToolResultInlineRow: View {
    let content: String

    private var outcome: ToolOutcome? {
        guard let data = content.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(ToolOutcome.self, from: data)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: outcome?.success == false ? "exclamationmark.triangle.fill" : "checkmark.seal.fill")
                .foregroundStyle(outcome?.success == false ? .red : .green)
                .font(.caption)
            Text(outcome?.content ?? content)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
    }
}

// MARK: - Date Separator

struct DateSeparator: View {
    let date: Date

    private var text: String {
        let cal = Calendar.current
        if cal.isDateInToday(date) { return "Today" }
        if cal.isDateInYesterday(date) { return "Yesterday" }
        let f = DateFormatter()
        f.dateStyle = .medium
        return f.string(from: date)
    }

    var body: some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .foregroundStyle(.tertiary)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity)
    }
}

// MARK: - Agent Exchange Chip

struct AgentExchangeChip: View {
    let content: String
    let incoming: Bool

    private var exchange: AgentExchange? {
        guard let data = content.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(AgentExchange.self, from: data)
    }

    var body: some View {
        if let exchange {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Image(systemName: "antenna.radiowaves.left.and.right")
                        .foregroundStyle(.white)
                        .frame(width: 30, height: 30)
                        .background(Color.teale, in: Circle())
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 4) {
                            if incoming {
                                Text(exchange.counterpartyName)
                                Image(systemName: "arrow.right")
                                Text("Teale")
                            } else {
                                Text("Teale")
                                Image(systemName: "arrow.right")
                                Text(exchange.counterpartyName)
                            }
                        }
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        Text(exchange.headline)
                            .font(.callout.weight(.medium))
                    }
                    Spacer()
                }

                if !exchange.payload.isEmpty {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(exchange.payload.sorted(by: { $0.key < $1.key }), id: \.key) { kv in
                            HStack(alignment: .top, spacing: 6) {
                                Text(kv.key.replacingOccurrences(of: "_", with: " "))
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(.tertiary)
                                    .frame(width: 110, alignment: .leading)
                                Text(kv.value)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Spacer(minLength: 0)
                            }
                        }
                    }
                    .padding(.leading, 4)
                }
            }
            .padding(12)
            .background(
                LinearGradient(
                    colors: [Color.teale.opacity(0.12), Color.teale.opacity(0.04)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                in: RoundedRectangle(cornerRadius: 14)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(Color.teale.opacity(0.3), lineWidth: 0.8)
            )
            .padding(.horizontal, 14)
            .padding(.vertical, 4)
        }
    }
}

// MARK: - Disclosure Consent Chip

struct DisclosureConsentChip: View {
    let content: String

    private var consent: DisclosureConsent? {
        guard let data = content.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(DisclosureConsent.self, from: data)
    }

    var body: some View {
        if let consent {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "lock.shield.fill")
                        .foregroundStyle(.white)
                        .frame(width: 30, height: 30)
                        .background(Color.orange, in: Circle())
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Share with \(consent.counterpartyName)?")
                            .font(.callout.weight(.semibold))
                        Text("Your agent will share only these items — nothing more.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(consent.disclosures, id: \.self) { item in
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: "checkmark")
                                .foregroundStyle(.green)
                                .font(.caption2)
                            Text(item)
                                .font(.caption)
                        }
                    }
                }
                .padding(.leading, 4)
            }
            .padding(12)
            .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(Color.orange.opacity(0.3), lineWidth: 0.8)
            )
            .padding(.horizontal, 14)
            .padding(.vertical, 4)
        }
    }
}

// MARK: - Wallet Entry Chip

struct WalletEntryChip: View {
    let content: String
    let currentUserID: UUID

    private var entry: WalletLedgerEntry? {
        guard let data = content.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(WalletLedgerEntry.self, from: data)
    }

    var body: some View {
        if let entry {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .foregroundStyle(color)
                    .font(.caption)
                Text(label(for: entry))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("$\(String(format: "%.2f", entry.amount))")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(color)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(color.opacity(0.08), in: Capsule())
            .padding(.horizontal, 16)
            .padding(.vertical, 4)
        }
    }

    private var icon: String {
        guard let entry else { return "creditcard" }
        switch entry.kind {
        case .contribution: return "arrow.down.circle.fill"
        case .debit: return "arrow.up.circle.fill"
        case .withdrawal: return "arrow.uturn.up.circle.fill"
        }
    }

    private var color: Color {
        guard let entry else { return .secondary }
        switch entry.kind {
        case .contribution: return .green
        case .debit: return .orange
        case .withdrawal: return .secondary
        }
    }

    private func label(for entry: WalletLedgerEntry) -> String {
        let who = entry.authorID == currentUserID ? "You" : "Someone"
        switch entry.kind {
        case .contribution: return "\(who) contributed" + (entry.memo.map { " — \($0)" } ?? "")
        case .debit: return entry.memo ?? "Group paid for inference"
        case .withdrawal: return "\(who) withdrew"
        }
    }
}
