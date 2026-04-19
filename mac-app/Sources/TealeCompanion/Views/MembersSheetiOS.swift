import SwiftUI
import ChatKit

struct MembersSheetiOS: View {
    let conversation: Conversation
    let chatService: ChatService
    let currentUserID: UUID

    @Environment(\.dismiss) private var dismiss
    @State private var showInvite = false

    private var participants: [ParticipantInfo] {
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
        NavigationStack {
            List {
                Section {
                    Button {
                        showInvite = true
                    } label: {
                        HStack {
                            Image(systemName: "person.badge.plus")
                                .foregroundStyle(.white)
                                .frame(width: 36, height: 36)
                                .background(Color.teale, in: Circle())
                            Text("Invite by phone")
                                .font(.body.weight(.medium))
                            Spacer()
                        }
                    }
                }

                Section("Members (\(participants.count))") {
                    ForEach(participants) { info in
                        HStack(spacing: 12) {
                            ZStack {
                                Circle()
                                    .fill(info.participant.role == .owner ? Color.teale.opacity(0.2) : Color.gray.opacity(0.15))
                                    .frame(width: 40, height: 40)
                                Image(systemName: info.participant.role == .owner ? "crown.fill" : "person.fill")
                                    .foregroundStyle(info.participant.role == .owner ? Color.teale : .secondary)
                            }
                            VStack(alignment: .leading, spacing: 2) {
                                Text(info.displayName)
                                Text(info.participant.role.rawValue.capitalized)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                    }
                }

                Section {
                    Text("Anyone with the invite link can join. Members are shown from this device's view of the group — full member management syncs via P2P.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle(conversation.displayTitle())
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(isPresented: $showInvite) {
                PhoneInviteSheetiOS(
                    conversation: conversation,
                    inviterID: currentUserID
                )
            }
        }
    }
}

// MARK: - iOS Phone Invite Sheet

struct PhoneInviteSheetiOS: View {
    let conversation: Conversation
    let inviterID: UUID

    @Environment(\.dismiss) private var dismiss
    @State private var phone: String = ""
    @State private var inviterName: String = ""
    @State private var generatedLink: URL?
    @State private var showShare = false

    private var service: InvitationService { InvitationService(currentUserID: inviterID) }

    var body: some View {
        NavigationStack {
            Form {
                Section("Your name (shown to invitee)") {
                    TextField("e.g. Taylor", text: $inviterName)
                }

                Section {
                    TextField("+1 (415) 555-1212", text: $phone)
                        #if os(iOS)
                        .keyboardType(.phonePad)
                        .textContentType(.telephoneNumber)
                        #endif
                } header: {
                    Text("Invitee phone (optional)")
                } footer: {
                    Text("Phone is a hint. Anyone with the invite link can accept.")
                }

                Section {
                    Button {
                        generate()
                    } label: {
                        Text("Generate invite link")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Color.teale)
                    .disabled(inviterName.trimmingCharacters(in: .whitespaces).isEmpty)
                }

                if let generatedLink {
                    Section("Link") {
                        Text(generatedLink.absoluteString)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                            .lineLimit(3)
                        Button {
                            showShare = true
                        } label: {
                            Label("Share link", systemImage: "square.and.arrow.up")
                        }
                    }
                }
            }
            .navigationTitle("Invite")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
            #if os(iOS)
            .sheet(isPresented: $showShare) {
                if let generatedLink {
                    ActivityView(items: [shareMessage(generatedLink)])
                        .presentationDetents([.medium])
                }
            }
            #endif
        }
    }

    private func generate() {
        let token = service.createPhoneInvite(
            groupID: conversation.id,
            groupTitle: conversation.displayTitle(),
            inviterName: inviterName.trimmingCharacters(in: .whitespaces),
            inviteePhone: phone.trimmingCharacters(in: .whitespaces).isEmpty ? nil : phone
        )
        generatedLink = service.deepLink(for: token)
    }

    private func shareMessage(_ link: URL) -> String {
        "\(inviterName) invited you to join \"\(conversation.displayTitle())\" on Teale: \(link.absoluteString)"
    }
}

#if os(iOS)
import UIKit

struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
#endif
