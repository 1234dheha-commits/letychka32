import SwiftUI

/// The "Chats" tab: a list of conversations from this session. Chats are
/// ephemeral (in memory only) and anonymous, matching the app's design.
/// Long-press a row to pin it (favourites stay on top) or delete it.
struct ChatsListView: View {
    @ObservedObject var ble: BLEMessenger
    @Environment(\.colorScheme) private var scheme
    var onOpen: (Peer) -> Void

    private static let timeFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    private func preview(_ m: ChatMessage) -> String {
        switch m.kind {
        case .text:  return m.text
        case .image: return "Photo"
        case .audio: return "Voice message"
        }
    }

    private func peer(for c: BLEMessenger.Convo) -> Peer {
        ble.peers.first(where: { $0.id == c.id })
            ?? Peer(id: c.id, nick: c.nick, rssi: 0, lastSeen: c.last.date)
    }

    var body: some View {
        let convos = ble.conversations()
        Group {
            if convos.isEmpty {
                empty
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(convos) { c in
                            Button { onOpen(peer(for: c)) } label: { row(c) }
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
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var empty: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 46, weight: .light))
                .foregroundStyle(Theme.accent)
            Text("No chats yet")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Theme.text(scheme))
            Text("Find people on the radar and say hi. Chats are saved on this phone so they are still here next time.")
                .font(.system(size: 13))
                .foregroundStyle(Theme.muted(scheme))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 44)
            Spacer()
            Spacer()
        }
    }

    private func row(_ c: BLEMessenger.Convo) -> some View {
        let isPinned = ble.pinned.contains(c.id)
        return HStack(spacing: 12) {
            ZStack {
                Circle().fill(Theme.accent.opacity(0.18))
                    .frame(width: 46, height: 46)
                Text(String(c.nick.prefix(1)).uppercased())
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(Theme.accent)
                if c.online {
                    Circle().fill(Theme.accent)
                        .frame(width: 12, height: 12)
                        .overlay(Circle().stroke(Theme.bg(scheme), lineWidth: 2))
                        .offset(x: 17, y: 17)
                }
            }
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    if isPinned {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(Theme.muted(scheme))
                    }
                    Text(c.nick)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Theme.text(scheme))
                        .lineLimit(1)
                    Spacer(minLength: 6)
                    Text(Self.timeFmt.string(from: c.last.date))
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.muted(scheme))
                }
                Text((c.last.mine ? "You: " : "") + preview(c.last))
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.muted(scheme))
                    .lineLimit(1)
            }
            let n = ble.unread[c.id] ?? 0
            if n > 0 {
                Text("\(n)")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(minWidth: 20, minHeight: 20)
                    .padding(.horizontal, 5)
                    .background(Theme.accent, in: Capsule())
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .contentShape(Rectangle())
        .contextMenu {
            Button { ble.togglePin(c.id) } label: {
                Label(isPinned ? "Unpin" : "Pin to top",
                      systemImage: isPinned ? "pin.slash" : "pin")
            }
            Button(role: .destructive) { ble.deleteConversation(c.id) } label: {
                Label("Delete chat", systemImage: "trash")
            }
            Button(role: .destructive) { ble.block(c.id) } label: {
                Label("Block", systemImage: "hand.raised")
            }
        }
    }
}
