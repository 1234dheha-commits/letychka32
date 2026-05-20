import SwiftUI

/// Minimal chat surface for the Global mode. Plain text only in v1; media
/// and read receipts come later. Subscribes to Realtime for live updates.
struct GlobalChatView: View {
    @Environment(\.colorScheme) private var scheme
    @ObservedObject var g = Global.shared
    let row: Global.ChatRow

    @State private var input: String = ""
    @State private var showInfo = false

    private static let timeFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    private var msgs: [Global.Message] { g.messages[row.chat.id] ?? [] }

    private var title: String {
        let myID = g.me?.id ?? UUID()
        if let other = row.otherParty(me: myID) {
            return other.display_name?.isEmpty == false
                ? (other.display_name ?? "")
                : other.username
        }
        return row.chat.name ?? L("Group chat")
    }

    var body: some View {
        ZStack {
            Theme.bg(scheme).ignoresSafeArea()
            VStack(spacing: 0) {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 6) {
                            ForEach(msgs) { m in
                                bubble(m).id(m.id)
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                    }
                    .onChange(of: msgs.count) { _, _ in
                        if let last = msgs.last {
                            withAnimation {
                                proxy.scrollTo(last.id, anchor: .bottom)
                            }
                        }
                    }
                }
                composer
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if row.chat.kind == .group {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showInfo = true } label: {
                        Image(systemName: "info.circle")
                    }
                }
            }
        }
        .navigationDestination(isPresented: $showInfo) {
            GroupSettingsView(row: row)
        }
        .task { await g.openChat(row.chat.id) }
        .onDisappear { Task { await g.closeChat() } }
    }

    @ViewBuilder
    private func bubble(_ m: Global.Message) -> some View {
        let mine = m.sender_id == g.me?.id
        HStack {
            if mine { Spacer(minLength: 50) }
            VStack(alignment: mine ? .trailing : .leading, spacing: 2) {
                Text(m.body ?? "")
                    .font(.system(size: 15))
                    .foregroundStyle(mine ? .white : Theme.text(scheme))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(
                        mine ? Theme.accent : Theme.surface(scheme),
                        in: RoundedRectangle(cornerRadius: 16)
                    )
                Text(Self.timeFmt.string(from: m.created_at))
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.muted(scheme))
                    .padding(.horizontal, 4)
            }
            if !mine { Spacer(minLength: 50) }
        }
    }

    private var composer: some View {
        HStack(spacing: 8) {
            TextField(L("Message"), text: $input, axis: .vertical)
                .lineLimit(1...4)
                .padding(10)
                .background(Theme.surface(scheme),
                            in: RoundedRectangle(cornerRadius: 18))
            Button {
                let t = input
                input = ""
                Task { await g.sendText(t, to: row.chat.id) }
            } label: {
                Image(systemName: "paperplane.fill")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(Theme.accent, in: Circle())
            }
            .disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .opacity(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                     ? 0.5 : 1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Theme.bg(scheme))
    }
}
