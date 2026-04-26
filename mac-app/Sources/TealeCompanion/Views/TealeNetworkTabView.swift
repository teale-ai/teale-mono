#if os(iOS)
import SwiftUI
import UIKit

// MARK: - Bubble shapes (iMessage-style tail)

private struct BubbleShape: Shape {
    let isMine: Bool
    let isGrouped: Bool
    func path(in rect: CGRect) -> Path {
        let r: CGFloat = 18
        let tail: CGFloat = isGrouped ? r : 4
        return Path(roundedRect: rect, cornerRadii: isMine
            ? .init(topLeading: r,    bottomLeading: r, bottomTrailing: r, topTrailing: tail)
            : .init(topLeading: tail, bottomLeading: r, bottomTrailing: r, topTrailing: r))
    }
}

// MARK: - Root

struct TealeNetworkTabView: View {

    @State private var state = TealeNetState()
    @State private var showingCreate = false
    @State private var showingWallet = false
    @State private var showingShareID = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    IdentityCard(
                        deviceID: state.deviceID,
                        balance: state.balance,
                        onCopy: { state.copyDeviceIDToClipboard() },
                        onShare: { showingShareID = true },
                        onWallet: { showingWallet = true; Haptics.tap() }
                    )
                    .padding(.horizontal, 16)

                    GroupsSection(
                        state: state,
                        onCreate: { showingCreate = true; Haptics.tap() }
                    )
                }
                .padding(.top, 8)
                .padding(.bottom, 24)
            }
            .background(Color.tealeBackground.ignoresSafeArea())
            .navigationTitle("Teale")
            .navigationBarTitleDisplayMode(.large)
            .refreshable { await state.refreshAll() }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showingCreate = true; Haptics.tap()
                    } label: {
                        Image(systemName: "plus.circle.fill")
                            .imageScale(.large)
                            .foregroundStyle(Color.teale)
                    }
                }
            }
            .navigationDestination(for: String.self) { id in
                GatewayGroupChatView(groupID: id, state: state)
            }
            .sheet(isPresented: $showingCreate) {
                CreateGroupSheet(state: state, isPresented: $showingCreate)
            }
            .sheet(isPresented: $showingWallet) {
                WalletSheet(state: state, isPresented: $showingWallet)
            }
            .sheet(isPresented: $showingShareID) {
                ShareSheet(items: [
                    "Join me on Teale — multiplayer chat with AI that pitches in. Paste my device ID into Add member:\n\n\(state.deviceID)"
                ])
            }
            .alert(
                "Something went wrong",
                isPresented: Binding(
                    get: { state.lastError != nil },
                    set: { if !$0 { state.lastError = nil } }
                )
            ) {
                Button("OK", role: .cancel) { state.lastError = nil }
            } message: {
                Text(state.lastError ?? "")
            }
        }
        .onAppear { state.bootstrap() }
        .tint(Color.teale)
    }
}

// MARK: - Identity hero card

private struct IdentityCard: View {
    let deviceID: String
    let balance: GwBalance?
    let onCopy: () -> Void
    let onShare: () -> Void
    let onWallet: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            HStack(alignment: .center, spacing: 14) {
                AvatarCircle(deviceID: deviceID, size: 56)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Your Teale identity")
                        .font(.caption).foregroundStyle(.secondary)
                    Text(deviceShort(deviceID))
                        .font(.system(.body, design: .monospaced).weight(.semibold))
                    Text("Paired across iOS + Android over gateway.teale.com")
                        .font(.caption2).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.tail)
                }
                Spacer()
            }
            HStack(spacing: 8) {
                Button(action: {
                    Haptics.click(); onCopy()
                }) {
                    Label("Copy ID", systemImage: "doc.on.doc")
                        .labelStyle(.titleAndIcon)
                        .font(.footnote.weight(.medium))
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .background(Color.teale.opacity(0.12), in: Capsule())
                        .foregroundStyle(Color.teale)
                }
                Button(action: onShare) {
                    Label("Invite", systemImage: "square.and.arrow.up")
                        .labelStyle(.titleAndIcon)
                        .font(.footnote.weight(.medium))
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .background(Color.teale.opacity(0.12), in: Capsule())
                        .foregroundStyle(Color.teale)
                }
                Spacer()
                Button(action: onWallet) {
                    HStack(spacing: 6) {
                        Image(systemName: "bolt.fill").font(.footnote)
                        Text(creditsLabel)
                            .font(.footnote.weight(.semibold))
                            .monospacedDigit()
                    }
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(Color.teale, in: Capsule())
                    .foregroundStyle(.white)
                }
            }
        }
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(.background)
                .shadow(color: Color.black.opacity(0.04), radius: 8, y: 2)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(Color.teale.opacity(0.12), lineWidth: 1)
        )
    }

    private var creditsLabel: String {
        if let b = balance { return "\(formatCredits(b.balance_credits)) credits" }
        return "— credits"
    }
}

// MARK: - Groups section

private struct GroupsSection: View {
    @Bindable var state: TealeNetState
    let onCreate: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Groups")
                    .font(.title3.weight(.semibold))
                Spacer()
                if state.isLoadingGroups {
                    ProgressView().controlSize(.small)
                }
            }
            .padding(.horizontal, 16)

            if state.groups.isEmpty {
                EmptyGroupsCard(onCreate: onCreate)
                    .padding(.horizontal, 16)
            } else {
                VStack(spacing: 8) {
                    ForEach(state.groups) { group in
                        NavigationLink(value: group.groupID) {
                            GroupRow(
                                group: group,
                                latest: state.groupLatestMessage[group.groupID],
                                myDeviceID: state.deviceID
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
            }
        }
    }
}

private struct EmptyGroupsCard: View {
    let onCreate: () -> Void
    var body: some View {
        VStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(Color.teale.opacity(0.14))
                    .frame(width: 72, height: 72)
                Image(systemName: "sparkles")
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(Color.teale)
            }
            Text("Start a group. Teale will help run it.")
                .font(.headline)
                .multilineTextAlignment(.center)
            Text("Invite iOS or Android teammates with their device ID. Mention @teale or ask a question and Teale will pitch in with a concrete suggestion.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 4)
            Button(action: onCreate) {
                Label("Create a group", systemImage: "plus")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(Color.teale, in: Capsule())
                    .foregroundStyle(.white)
            }
            .padding(.top, 2)
        }
        .padding(24)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(.background)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(Color.teale.opacity(0.12), lineWidth: 1)
        )
    }
}

private struct GroupRow: View {
    let group: GwGroupSummary
    let latest: GwGroupMessage?
    let myDeviceID: String

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            GroupAvatar(seed: group.groupID, title: group.title)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(group.title)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Spacer()
                    if let ts = latest?.timestamp {
                        Text(relativeTime(ts))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                HStack(spacing: 6) {
                    if latest?.type == "ai" {
                        Image(systemName: "sparkles")
                            .font(.caption2)
                            .foregroundStyle(Color.teale)
                    }
                    Text(previewText(for: latest, myDeviceID: myDeviceID))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    MembersPill(count: Int(group.memberCount))
                }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.background)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.teale.opacity(0.08), lineWidth: 1)
        )
    }

    private func previewText(for m: GwGroupMessage?, myDeviceID: String) -> String {
        guard let m else { return "New group · tap to start" }
        let prefix: String = {
            if m.type == "ai" { return "Teale: " }
            if m.senderDeviceID.lowercased() == myDeviceID.lowercased() { return "You: " }
            return "@\(m.senderDeviceID.prefix(4)): "
        }()
        return prefix + m.content
    }
}

private struct MembersPill: View {
    let count: Int
    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "person.2.fill").font(.system(size: 9))
            Text("\(count)").font(.caption2.monospacedDigit())
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 6).padding(.vertical, 3)
        .background(Color.secondary.opacity(0.12), in: Capsule())
    }
}

// MARK: - Create group sheet

private struct CreateGroupSheet: View {
    @Bindable var state: TealeNetState
    @Binding var isPresented: Bool
    @State private var title: String = ""
    @State private var peerDeviceID: String = ""
    @FocusState private var titleFocused: Bool

    private var normalizedPeer: String {
        peerDeviceID.lowercased().filter { $0.isHexDigit }
    }
    private var peerValid: Bool { normalizedPeer.count == 64 }
    private var titleValid: Bool {
        !title.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("e.g. Thursday dinner, launch plan…", text: $title)
                        .focused($titleFocused)
                } header: {
                    Text("Name your group")
                }
                Section {
                    TextField("Paste a device ID (optional)",
                              text: $peerDeviceID, axis: .vertical)
                        .autocapitalization(.none)
                        .autocorrectionDisabled(true)
                        .font(.system(.footnote, design: .monospaced))
                        .lineLimit(2)
                } header: {
                    Text("Add someone now (optional)")
                } footer: {
                    Text(peerDeviceID.isEmpty
                         ? "You can always invite people later from inside the group."
                         : peerValid
                           ? "Valid device ID — they'll be added immediately."
                           : "Device IDs are 64 hex characters. Keep pasting.")
                }
            }
            .navigationTitle("New group")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { isPresented = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        guard titleValid else { return }
                        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
                        state.createGroup(title: t, then: true)
                        if peerValid {
                            // Fire-and-forget; the group-create closure will
                            // open the new group, and addMember runs async.
                            Task {
                                try? await Task.sleep(nanoseconds: 400_000_000)
                                if let gid = state.groups.first?.groupID {
                                    state.addMember(groupID: gid, deviceID: normalizedPeer)
                                }
                            }
                        }
                        isPresented = false
                    }
                    .disabled(!titleValid)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .onAppear { titleFocused = true }
    }
}

// MARK: - Wallet sheet

private struct WalletSheet: View {
    @Bindable var state: TealeNetState
    @Binding var isPresented: Bool
    @State private var copiedDeviceID = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        state.copyDeviceIDToClipboard()
                    } label: {
                        HStack {
                            Text("Device ID").foregroundStyle(.secondary)
                            Spacer()
                            Text(deviceShort(state.deviceID))
                                .font(.system(.body, design: .monospaced).weight(.semibold))
                                .foregroundStyle(Color.teale)
                        }
                    }
                    .buttonStyle(.plain)

                    HStack {
                        Text("Device ID").foregroundStyle(.secondary)
                        Spacer()
                        Button(action: copyDeviceID) {
                            Text(shortDeviceID(state.deviceID))
                                .font(.body.monospaced())
                        }
                        .buttonStyle(.plain)
                    }
                    Text(
                        copiedDeviceID
                            ? "Device ID copied."
                            : "Share this public device ID when someone wants to send credits to this wallet."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    HStack {
                        Text("Balance").foregroundStyle(.secondary)
                        Spacer()
                        Text(state.balance.map { formatCredits($0.balance_credits) } ?? "—")
                            .font(.title3.weight(.semibold).monospacedDigit())
                    }
                    if let b = state.balance {
                        HStack {
                            Text("Earned").foregroundStyle(.secondary)
                            Spacer()
                            Text(formatCredits(b.total_earned_credits)).monospacedDigit()
                        }
                        HStack {
                            Text("Spent").foregroundStyle(.secondary)
                            Spacer()
                            Text(formatCredits(b.total_spent_credits)).monospacedDigit()
                        }
                        HStack {
                            Text("USDC").foregroundStyle(.secondary)
                            Spacer()
                            Text("$\(String(format: "%.2f", Double(b.usdc_cents)/100.0))")
                                .monospacedDigit()
                        }
                    }
                } header: { Text("Teale Credits") }

                Section {
                    if state.transactions.isEmpty {
                        Text("No activity yet.").foregroundStyle(.secondary)
                    } else {
                        ForEach(state.transactions) { tx in
                            TxRow(tx: tx)
                        }
                    }
                } header: { Text("Recent activity") }
            }
            .navigationTitle("Wallet")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { isPresented = false }
                }
            }
            .refreshable { await state.refreshWallet() }
        }
    }

    private func copyDeviceID() {
        UIPasteboard.general.string = state.deviceID
        copiedDeviceID = true
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            copiedDeviceID = false
        }
    }
}

private struct TxRow: View {
    let tx: GwLedgerEntry
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(tx.type.replacingOccurrences(of: "_", with: " ").capitalized)
                    .font(.subheadline.weight(.medium))
                Text(tx.note ?? "—")
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Text(formatCreditsSigned(tx.amount))
                .font(.subheadline.weight(.semibold).monospacedDigit())
                .foregroundStyle(tx.amount >= 0 ? Color.positive : Color.negative)
        }
    }
}

private func shortDeviceID(_ deviceID: String) -> String {
    guard deviceID.count > 16 else { return deviceID }
    return "\(deviceID.prefix(8))...\(deviceID.suffix(8))"
}

// MARK: - Group chat view

struct GatewayGroupChatView: View {

    let groupID: String
    @Bindable var state: TealeNetState

    @State private var composer: String = ""
    @State private var showInvite = false
    @FocusState private var composerFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            Color.tealeBackground.frame(height: 0) // anchor
            MessageList(
                messages: state.messages,
                myDeviceID: state.deviceID,
                isAITyping: state.isAITyping
            )
            Divider().opacity(0.3)
            Composer(
                text: $composer,
                enabled: !state.isSending,
                focused: $composerFocused,
                onSend: {
                    state.send(groupID: groupID, text: composer)
                    composer = ""
                },
                onNudge: {
                    Haptics.tap()
                    state.nudgeAI(groupID: groupID)
                }
            )
        }
        .background(Color.tealeBackground.ignoresSafeArea(edges: .bottom))
        .navigationTitle(currentGroupTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                ChatHeader(
                    title: currentGroupTitle,
                    memberCount: Int(state.groups.first{$0.groupID==groupID}?.memberCount ?? 0),
                    aiTyping: state.isAITyping
                )
            }
            ToolbarItem(placement: .primaryAction) {
                Button { showInvite = true; Haptics.tap() } label: {
                    Image(systemName: "person.crop.circle.badge.plus")
                }
            }
        }
        .sheet(isPresented: $showInvite) {
            InviteSheet(state: state, groupID: groupID, isPresented: $showInvite)
        }
        .onAppear { state.openGroup(groupID) }
        .onDisappear { state.leaveGroup() }
    }

    private var currentGroupTitle: String {
        state.groups.first { $0.groupID == groupID }?.title ?? "Group"
    }
}

private struct ChatHeader: View {
    let title: String
    let memberCount: Int
    let aiTyping: Bool
    var body: some View {
        VStack(spacing: 1) {
            Text(title).font(.subheadline.weight(.semibold)).lineLimit(1)
            HStack(spacing: 5) {
                Image(systemName: "sparkles")
                    .font(.system(size: 9))
                    .foregroundStyle(Color.teale)
                Text(aiTyping ? "Teale is typing…" : "\(memberCount) members · Teale on")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Messages

private struct MessageList: View {
    let messages: [GwGroupMessage]
    let myDeviceID: String
    let isAITyping: Bool

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(messages.enumerated()), id: \.element.id) { pair in
                        let i = pair.offset
                        let m = pair.element
                        let prev = i > 0 ? messages[i-1] : nil
                        let grouped = prev.map {
                            $0.type == m.type &&
                            $0.senderDeviceID == m.senderDeviceID &&
                            (m.timestamp - $0.timestamp) < 120
                        } ?? false
                        let isLast = (i == messages.count - 1)
                        Bubble(
                            message: m,
                            myDeviceID: myDeviceID,
                            isGroupedWithPrev: grouped,
                            showTimestamp: isLast || !grouped
                        )
                        .id(m.id)
                        .transition(.asymmetric(
                            insertion: .scale(scale: 0.94).combined(with: .opacity),
                            removal: .opacity
                        ))
                    }
                    if isAITyping {
                        TypingRow().id("__typing__")
                    }
                    Color.clear.frame(height: 1).id("__bottom__")
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .animation(.spring(response: 0.3, dampingFraction: 0.85), value: messages.count)
            }
            .onChange(of: messages.count) {
                withAnimation(.spring()) { proxy.scrollTo("__bottom__", anchor: .bottom) }
            }
            .onChange(of: isAITyping) {
                withAnimation(.spring()) { proxy.scrollTo("__bottom__", anchor: .bottom) }
            }
        }
    }
}

private struct Bubble: View {
    let message: GwGroupMessage
    let myDeviceID: String
    let isGroupedWithPrev: Bool
    let showTimestamp: Bool

    var body: some View {
        let isAi = message.type == "ai"
        let isMine = !isAi && message.senderDeviceID.lowercased() == myDeviceID.lowercased()
        let bg: Color = isAi  ? Color.teale.opacity(0.12)
                       : isMine ? Color.teale
                       : Color.inbound
        let fg: Color = isAi  ? Color.primary
                       : isMine ? .white
                       : Color.primary

        VStack(alignment: isMine ? .trailing : .leading, spacing: 2) {
            if !isGroupedWithPrev {
                if isAi {
                    Label {
                        Text("Teale").font(.caption.weight(.semibold))
                    } icon: {
                        Image(systemName: "sparkles")
                    }
                    .foregroundStyle(Color.teale)
                    .padding(.leading, 8)
                    .padding(.bottom, 1)
                } else if !isMine {
                    Text("@\(message.senderDeviceID.prefix(6))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.leading, 8)
                        .padding(.bottom, 1)
                }
            }
            Text(message.content)
                .foregroundStyle(fg)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(bg, in: BubbleShape(isMine: isMine, isGrouped: isGroupedWithPrev))
                .contextMenu {
                    Button {
                        UIPasteboard.general.string = message.content
                        Haptics.click()
                    } label: { Label("Copy", systemImage: "doc.on.doc") }
                }
            if showTimestamp {
                Text(shortTime(message.timestamp))
                    .font(.caption2).foregroundStyle(.secondary)
                    .padding(.horizontal, 8).padding(.top, 1)
            }
        }
        .frame(maxWidth: .infinity, alignment: isMine ? .trailing : .leading)
        .padding(.leading,  isMine ? 60 : 0)
        .padding(.trailing, isMine ? 0  : 60)
        .padding(.top, isGroupedWithPrev ? 0 : 6)
    }
}

private struct TypingRow: View {
    @State private var phase = 0
    private let timer = Timer.publish(every: 0.35, on: .main, in: .common).autoconnect()
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "sparkles").foregroundStyle(Color.teale)
            HStack(spacing: 4) {
                ForEach(0..<3) { i in
                    Circle()
                        .fill(Color.teale)
                        .frame(width: 6, height: 6)
                        .opacity(phase == i ? 1.0 : 0.35)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(Color.teale.opacity(0.12), in: Capsule())
        }
        .padding(.leading, 6).padding(.top, 4)
        .onReceive(timer) { _ in phase = (phase + 1) % 3 }
    }
}

// MARK: - Composer

private struct Composer: View {
    @Binding var text: String
    let enabled: Bool
    var focused: FocusState<Bool>.Binding
    let onSend: () -> Void
    let onNudge: () -> Void

    private var canSend: Bool {
        enabled && !text.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            Button(action: onNudge) {
                Image(systemName: "sparkles")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Color.teale)
                    .frame(width: 36, height: 36)
                    .background(Color.teale.opacity(0.12), in: Circle())
            }
            .accessibilityLabel("Ask Teale")

            HStack(alignment: .center) {
                TextField("Message · try @teale …", text: $text, axis: .vertical)
                    .focused(focused)
                    .lineLimit(1...5)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 14).padding(.vertical, 10)
            }
            .background(
                Capsule()
                    .fill(Color.inbound)
            )

            Button(action: {
                guard canSend else { return }
                onSend()
            }) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(canSend ? Color.teale : Color.teale.opacity(0.35),
                                in: Circle())
                    .scaleEffect(canSend ? 1 : 0.92)
                    .animation(.spring(response: 0.25, dampingFraction: 0.7), value: canSend)
            }
            .disabled(!canSend)
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(Color(uiColor: .systemBackground))
    }
}

// MARK: - Invite sheet

private struct InviteSheet: View {
    @Bindable var state: TealeNetState
    let groupID: String
    @Binding var isPresented: Bool
    @State private var pasted: String = ""

    private var normalized: String { pasted.lowercased().filter { $0.isHexDigit } }
    private var valid: Bool { normalized.count == 64 }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Paste device ID (64 hex)", text: $pasted, axis: .vertical)
                        .autocapitalization(.none)
                        .autocorrectionDisabled(true)
                        .font(.system(.footnote, design: .monospaced))
                        .lineLimit(2...4)
                } header: {
                    Text("Add someone")
                } footer: {
                    Text(valid ? "Looks good — tap Add." :
                         "Ask them to open Teale → tap their device ID to copy it, then paste here.")
                }
                Section {
                    Button {
                        let items: [Any] = [
                            "Join my Teale group. Paste this into Teale → Add member:\n\n\(state.deviceID)"
                        ]
                        shareViaActivity(items: items)
                    } label: {
                        Label("Share my device ID", systemImage: "square.and.arrow.up")
                    }
                }
            }
            .navigationTitle("Invite")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { isPresented = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        guard valid else { return }
                        state.addMember(groupID: groupID, deviceID: normalized) {
                            isPresented = false
                        }
                    }
                    .disabled(!valid)
                }
            }
        }
        .presentationDetents([.medium])
    }
}

// MARK: - Share sheet bridge + activity helper

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}

private func shareViaActivity(items: [Any]) {
    guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
          let root = scene.keyWindow?.rootViewController else { return }
    let vc = UIActivityViewController(activityItems: items, applicationActivities: nil)
    root.topmost.present(vc, animated: true)
}

private extension UIViewController {
    var topmost: UIViewController {
        if let presented = presentedViewController { return presented.topmost }
        if let nav = self as? UINavigationController,
           let v = nav.visibleViewController { return v.topmost }
        if let tab = self as? UITabBarController,
           let s = tab.selectedViewController { return s.topmost }
        return self
    }
}

// MARK: - Avatars + small utilities

private struct AvatarCircle: View {
    let deviceID: String
    let size: CGFloat
    var body: some View {
        let (c1, c2) = avatarGradient(seed: deviceID)
        ZStack {
            LinearGradient(
                colors: [c1, c2],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
            .frame(width: size, height: size)
            .clipShape(Circle())
            Text(initials(from: deviceID))
                .font(.system(size: size * 0.38, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
        }
        .shadow(color: c1.opacity(0.25), radius: 6, y: 3)
    }
}

private struct GroupAvatar: View {
    let seed: String
    let title: String
    var body: some View {
        let (c1, c2) = avatarGradient(seed: seed)
        ZStack {
            LinearGradient(
                colors: [c1, c2],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
            .frame(width: 44, height: 44)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            Text(initialsFromTitle(title))
                .font(.system(size: 16, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
        }
    }
}

private func initials(from deviceID: String) -> String {
    let hex = deviceID.uppercased()
    return String(hex.prefix(2))
}

private func initialsFromTitle(_ title: String) -> String {
    let words = title.split(separator: " ")
    if let first = words.first, let f = first.first {
        if words.count > 1, let s = words[1].first {
            return String(f) + String(s)
        }
        return String(f).uppercased()
    }
    return "•"
}

private func deviceShort(_ id: String) -> String {
    // 1234abcd · ef567890
    let a = id.prefix(8)
    let b = id.dropFirst(8).prefix(8)
    return "\(a) · \(b)"
}

private func relativeTime(_ ts: Int64) -> String {
    let date = Date(timeIntervalSince1970: TimeInterval(ts))
    let diff = Date().timeIntervalSince(date)
    if diff < 60 { return "now" }
    if diff < 3600 { return "\(Int(diff/60))m" }
    if diff < 86400 { return "\(Int(diff/3600))h" }
    let fmt = DateFormatter(); fmt.dateFormat = "MMM d"
    return fmt.string(from: date)
}

private func shortTime(_ ts: Int64) -> String {
    let date = Date(timeIntervalSince1970: TimeInterval(ts))
    let fmt = DateFormatter(); fmt.dateStyle = .none; fmt.timeStyle = .short
    return fmt.string(from: date)
}

private func formatCredits(_ n: Int64) -> String {
    let fmt = NumberFormatter()
    fmt.numberStyle = .decimal
    return fmt.string(from: NSNumber(value: n)) ?? "\(n)"
}

private func formatCreditsSigned(_ n: Int64) -> String {
    (n >= 0 ? "+" : "") + formatCredits(n)
}

// Deterministic pastel-teal-ish gradient seeded from hex/text.
private func avatarGradient(seed: String) -> (Color, Color) {
    var h: UInt64 = 0xcbf29ce484222325
    for b in seed.utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
    let hue1 = Double((h >> 0) & 0xff) / 255.0
    let hue2 = fmod(hue1 + 0.08, 1.0)
    return (
        Color(hue: hue1, saturation: 0.55, brightness: 0.72),
        Color(hue: hue2, saturation: 0.75, brightness: 0.55)
    )
}

// MARK: - Brand colors

extension Color {
    static var tealeBackground: Color { Color(uiColor: .systemGroupedBackground) }
    static var inbound: Color { Color(uiColor: .tertiarySystemFill) }
    static var positive: Color { Color(red: 0.0, green: 0.58, blue: 0.45) }
    static var negative: Color { Color(red: 0.84, green: 0.22, blue: 0.22) }
}

// UIWindowScene.keyWindow helper for iOS 13+
private extension UIWindowScene {
    var keyWindow: UIWindow? { windows.first(where: { $0.isKeyWindow }) ?? windows.first }
}

#endif
