import SwiftUI
import ChatKit

struct NewGroupSheet: View {
    let chatService: ChatService
    let onCreated: (UUID) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New Group")
                .font(.title2.weight(.semibold))

            Text("Groups are end-to-end encrypted. Teale AI will be available in the group — just @teale to ask it anything.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            TextField("Group name (e.g. Trip to Tokyo)", text: $name)
                .textFieldStyle(.roundedBorder)

            Text("Invite participants after creation using the group's toolbar.")
                .font(.caption)
                .foregroundStyle(.tertiary)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Create") {
                    create()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    private func create() {
        let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }

        Task {
            let created = await chatService.createGroup(
                title: title,
                memberIDs: [],
                agentConfig: AgentConfig(
                    autoRespond: false,
                    mentionOnly: true,
                    persona: "assistant"
                )
            )
            if let created {
                onCreated(created.id)
            }
            dismiss()
        }
    }
}
