import SwiftUI

/// The "Global" tab body: a list of online chats plus a button to find new
/// people by username. Mirrors the visual style of ChatsListView so the two
/// modes feel like one app.
struct GlobalChatsView: View {
    @ObservedObject var g = Global.shared
    @Environment(\.colorScheme) private var scheme
    @State private var openChatID: UUID?
    @State private var showSearch = false
    @State private var showCreateGroup = false
    /// When a sheet wants to open a chat, it stashes the id here and
    /// dismisses itself. We only actually navigate from onDismiss, so the
    /// push is not racing the sheet's dismissal animation (which on iOS
    /// silently swallows the navigation request and looks like the sheet
    /// just closed and nothing happened).
    @State private var pendingChatID: UUID?

    private static let timeFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    var body: some View {
        ZStack {
            Theme.bg(scheme).ignoresSafeArea()
            VStack(spacing: 0) {
                if g.chats.isEmpty {
                    empty
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(g.chats) { row in
                                Button { openChatID = row.id } label: {
                                    chatRow(row)
                                }
                                .buttonStyle(.plain)
                                Divider()
                                    .overlay(Theme.line(scheme))
                                    .padding(.leading, 74)
                            }
                        }
                        .padding(.top, 6)
                    }
                }
            }
        }
        .navigationTitle(L("Global"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        showSearch = true
                    } label: {
                        Label(L("New direct chat"),
                              systemImage: "person.crop.circle.badge.plus")
                    }
                    Button {
                        showCreateGroup = true
                    } label: {
                        Label(L("New group"),
                              systemImage: "person.3.fill")
                    }
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .navigationDestination(item: $openChatID) { cid in
            if let row = g.chats.first(where: { $0.id == cid }) {
                GlobalChatView(row: row)
            }
        }
        .sheet(isPresented: $showSearch, onDismiss: navigateToPending) {
            NavigationStack { UserSearchView { user in
                Task {
                    if let id = await g.openDirectChat(with: user) {
                        await MainActor.run {
                            pendingChatID = id
                            showSearch = false
                        }
                    }
                }
            } }
        }
        .sheet(isPresented: $showCreateGroup,
               onDismiss: navigateToPending) {
            NavigationStack {
                CreateGroupView { newID in
                    pendingChatID = newID
                    showCreateGroup = false
                }
            }
        }
        .task { await g.refresh() }
        .refreshable { await g.refresh() }
    }

    /// Fires after a sheet has finished its dismiss animation; only then is
    /// it safe to push a NavigationStack destination on top.
    private func navigateToPending() {
        guard let id = pendingChatID else { return }
        pendingChatID = nil
        openChatID = id
    }

    @ViewBuilder
    private var empty: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "globe")
                .font(.system(size: 46, weight: .light))
                .foregroundStyle(Theme.accent)
            Text(L("No global chats yet"))
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Theme.text(scheme))
            Text(L("Tap + to find someone by username or start a new group."))
                .font(.system(size: 13))
                .foregroundStyle(Theme.muted(scheme))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 44)
            Spacer()
            Spacer()
        }
    }

    @ViewBuilder
    private func chatRow(_ row: Global.ChatRow) -> some View {
        let myID = g.me?.id ?? UUID()
        let other = row.otherParty(me: myID)
        let title = other?.display_name
            ?? other?.username
            ?? row.chat.name
            ?? L("Group chat")
        let preview = row.lastMessage?.body ?? ""
        let date = row.lastMessage?.created_at ?? row.chat.created_at
        HStack(spacing: 12) {
            Circle().fill(Theme.accent.opacity(0.18))
                .frame(width: 46, height: 46)
                .overlay(
                    Text(String(title.prefix(1)).uppercased())
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(Theme.accent)
                )
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(title)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Theme.text(scheme))
                        .lineLimit(1)
                    Spacer(minLength: 6)
                    Text(Self.timeFmt.string(from: date))
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.muted(scheme))
                }
                Text(preview.isEmpty ? L("No messages yet") : preview)
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.muted(scheme))
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .contentShape(Rectangle())
    }
}
