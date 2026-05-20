import SwiftUI

/// "Info" page for a group chat: shows the name, members, lets the owner
/// rename and add people, lets anyone leave. v1 is intentionally small.
struct GroupSettingsView: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var g = Global.shared
    let chatID: UUID

    @State private var name: String = ""
    @State private var showAdd = false
    @State private var leaveConfirm = false

    init(row: Global.ChatRow) {
        self.chatID = row.chat.id
        _name = State(initialValue: row.chat.name ?? "")
    }

    /// Always pull the fresh row out of the live chats list so a rename or
    /// member change updates the view immediately.
    private var row: Global.ChatRow? {
        g.chats.first(where: { $0.chat.id == chatID })
    }

    var body: some View {
        ZStack {
            Theme.bg(scheme).ignoresSafeArea()
            Form {
                Section(L("Name")) {
                    HStack {
                        TextField(L("Group name"), text: $name)
                        if name != (row?.chat.name ?? "") {
                            Button(L("Save")) {
                                Task {
                                    await g.renameGroup(chatID, name: name)
                                }
                            }
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Theme.accent)
                        }
                    }
                }
                Section(L("Members")) {
                    ForEach(row?.members ?? []) { p in
                        HStack(spacing: 10) {
                            Circle().fill(Theme.accent.opacity(0.18))
                                .frame(width: 28, height: 28)
                                .overlay(
                                    Text(String(p.username.prefix(1))
                                        .uppercased())
                                        .font(.system(size: 12,
                                                      weight: .bold))
                                        .foregroundStyle(Theme.accent)
                                )
                            VStack(alignment: .leading, spacing: 2) {
                                Text(p.display_name?.isEmpty == false
                                     ? (p.display_name ?? "")
                                     : p.username)
                                    .font(.system(size: 14, weight: .semibold))
                                Text("@\(p.username)")
                                    .font(.system(size: 11))
                                    .foregroundStyle(Theme.muted(scheme))
                            }
                            Spacer()
                            if p.id == g.me?.id {
                                Text(L("you"))
                                    .font(.system(size: 11))
                                    .foregroundStyle(Theme.muted(scheme))
                            }
                        }
                    }
                    Button {
                        showAdd = true
                    } label: {
                        Label(L("Add member"), systemImage: "person.badge.plus")
                    }
                }
                Section {
                    Button(role: .destructive) {
                        leaveConfirm = true
                    } label: {
                        Label(L("Leave group"),
                              systemImage: "rectangle.portrait.and.arrow.right")
                    }
                }
            }
        }
        .navigationTitle(L("Group info"))
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: row?.chat.name) { _, newName in
            // Server confirmed a rename, mirror it into the editor field.
            if let newName, name != newName { name = newName }
        }
        .sheet(isPresented: $showAdd) {
            NavigationStack {
                UserSearchView { user in
                    showAdd = false
                    Task { await g.addMember(chatID, user: user) }
                }
            }
        }
        .alert(L("Leave this group?"), isPresented: $leaveConfirm) {
            Button(L("Cancel"), role: .cancel) {}
            Button(L("Leave"), role: .destructive) {
                Task {
                    await g.leave(chatID)
                    dismiss()
                }
            }
        } message: {
            Text(L("You will stop receiving messages. You can be added back by an admin."))
        }
    }
}
