import SwiftUI
import ChatKit

struct MembersSheet: View {
    let conversation: Conversation
    let chatService: ChatService
    let currentUserID: UUID

    @Environment(\.dismiss) private var dismiss
    @State private var showInvite = false

    private var participants: [ParticipantInfo] {
        // activeParticipants is only populated when a conversation is open;
        // derive a best-effort member list from current message senders + creator.
        var seen: Set<UUID> = []
        var result: [ParticipantInfo] = []

        func add(_ userID: UUID, role: ParticipantRole) {
            guard !seen.contains(userID) else { return }
            seen.insert(userID)
            let displayName = userID == currentUserID ? "You" : "User \(userID.uuidString.prefix(6))"
            let p = Participant(conversationID: conversation.id, userID: userID, role: role)
            result.append(ParticipantInfo(participant: p, displayName: displayName))
        }

        add(conversation.createdBy, role: .owner)
        for msg in chatService.activeMessages {
            if let senderID = msg.senderID {
                add(senderID, role: .member)
            }
        }
        return result
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image(systemName: "person.3.fill")
                    .foregroundStyle(Color(red: 0.0, green: 0.6, blue: 0.6))
                    .font(.title)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Members")
                        .font(.title2.weight(.semibold))
                    Text(conversation.displayTitle())
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    showInvite = true
                } label: {
                    Label("Invite", systemImage: "person.badge.plus")
                }
                .buttonStyle(.borderedProminent)
            }

            Form {
                Section("Participants (\(participants.count))") {
                    ForEach(participants) { info in
                        HStack {
                            Image(systemName: info.participant.role == .owner ? "crown.fill" : "person.fill")
                                .foregroundStyle(info.participant.role == .owner ? .orange : .secondary)
                                .frame(width: 18)
                            Text(info.displayName)
                                .font(.callout)
                            Spacer()
                            Text(info.participant.role.rawValue.capitalized)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Section {
                    Text("Participants are derived from message senders for this session. Ownership (create / remove members) is being wired next — for now, use invite links to add people.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 500, height: 520)
        .sheet(isPresented: $showInvite) {
            PhoneInviteSheet(
                conversation: conversation,
                inviterID: currentUserID
            )
        }
    }
}

// MARK: - Phone Invite Sheet

struct PhoneInviteSheet: View {
    let conversation: Conversation
    let inviterID: UUID

    @Environment(\.dismiss) private var dismiss
    @State private var phone: String = ""
    @State private var inviterName: String = ""
    @State private var generatedLink: URL?
    @State private var copied = false

    private var service: InvitationService { InvitationService(currentUserID: inviterID) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image(systemName: "person.badge.plus")
                    .foregroundStyle(Color(red: 0.0, green: 0.6, blue: 0.6))
                    .font(.title)
                Text("Invite to \(conversation.displayTitle())")
                    .font(.title3.weight(.semibold))
                Spacer()
            }

            Form {
                Section("Your name (shown to invitee)") {
                    TextField("e.g. Taylor", text: $inviterName)
                }

                Section("Invitee phone number (optional hint)") {
                    TextField("+1 (415) 555-1212", text: $phone)
                        .textContentType(.telephoneNumber)
                    Text("The phone number is a hint. Anyone with the link can accept.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section {
                    Button("Generate invite link") { generate() }
                        .buttonStyle(.borderedProminent)
                        .disabled(inviterName.trimmingCharacters(in: .whitespaces).isEmpty)
                }

                if let generatedLink {
                    Section("Link") {
                        Text(generatedLink.absoluteString)
                            .font(.callout.monospaced())
                            .textSelection(.enabled)
                            .lineLimit(3)
                        HStack {
                            Button {
                                copy(generatedLink)
                            } label: {
                                Label(copied ? "Copied!" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                            }
                            #if os(macOS)
                            Button {
                                share(generatedLink)
                            } label: {
                                Label("Share", systemImage: "square.and.arrow.up")
                            }
                            #endif
                        }
                        Text("Paste the link into iMessage, SMS, or any messenger. The recipient taps it to join.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button("Close") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 500, height: 520)
    }

    private func generate() {
        let token = service.createPhoneInvite(
            groupID: conversation.id,
            groupTitle: conversation.displayTitle(),
            inviterName: inviterName.trimmingCharacters(in: .whitespaces),
            inviteePhone: phone.trimmingCharacters(in: .whitespaces).isEmpty ? nil : phone
        )
        generatedLink = service.deepLink(for: token)
        copied = false
    }

    private func copy(_ url: URL) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
        #endif
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copied = false }
    }

    #if os(macOS)
    private func share(_ url: URL) {
        let picker = NSSharingServicePicker(items: [url])
        if let window = NSApp.keyWindow,
           let contentView = window.contentView {
            picker.show(relativeTo: .zero, of: contentView, preferredEdge: .minY)
        }
    }
    #endif
}
