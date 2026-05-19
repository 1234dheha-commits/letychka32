import SwiftUI

/// The shared "nearby room": one common chat for everyone in Bluetooth
/// range. Text only, no servers, broadcast to every reachable phone.
/// Supports replies, emoji reactions and @nick mentions.
struct RoomView: View {
    @ObservedObject var ble: BLEMessenger
    @AppStorage("hideHints") private var hideHints = false
    @Environment(\.colorScheme) private var scheme
    @State private var draft = ""
    @State private var replyingTo: ChatMessage?
    private let emojis = ["👍", "❤️", "😂", "🔥", "😮", "😢"]

    private func nickOf(_ m: ChatMessage) -> String {
        m.mine ? ble.nick : (ble.names[m.peerID] ?? L("Anon"))
    }

    private func snippet(_ m: ChatMessage) -> String {
        String(m.text.prefix(50))
    }

    /// True when this message names me (@myNick), so it stands out.
    private func mentionsMe(_ m: ChatMessage) -> Bool {
        guard !m.mine else { return false }
        let n = ble.nick.trimmingCharacters(in: .whitespaces)
        guard n.count >= 2, n != "Anon" else { return false }
        return m.text.range(of: "@" + n, options: .caseInsensitive) != nil
    }

    var body: some View {
        VStack(spacing: 0) {
            if ble.roomMessages.isEmpty {
                emptyState
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 8) {
                            ForEach(ble.roomMessages) { m in
                                HStack {
                                    if m.mine { Spacer(minLength: 40) }
                                    row(m).contextMenu { menu(m) }
                                    if !m.mine { Spacer(minLength: 40) }
                                }
                                .id(m.id)
                            }
                        }
                        .padding(16)
                    }
                    .onChange(of: ble.roomMessages.count) { _, _ in
                        if let last = ble.roomMessages.last {
                            withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                        }
                    }
                }
            }

            if let r = replyingTo {
                HStack(spacing: 8) {
                    Image(systemName: "arrowshape.turn.up.left")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.accent)
                    Text(L("Reply: %@", snippet(r)))
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.muted(scheme))
                        .lineLimit(1)
                    Spacer()
                    Button(L("Cancel")) { replyingTo = nil }
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                }
                .padding(.horizontal, 18).padding(.top, 6)
            }

            HStack(spacing: 10) {
                TextField(L("Message everyone nearby"), text: $draft)
                    .textFieldStyle(.plain)
                    .padding(.vertical, 11).padding(.horizontal, 14)
                    .background(Theme.surface(scheme))
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                Button {
                    ble.sendRoom(draft, replyTo: replyingTo?.wireID ?? 0)
                    draft = ""
                    replyingTo = nil
                } label: {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 42, height: 42)
                        .background(Theme.accent)
                        .clipShape(Circle())
                }
                .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "person.3")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(Theme.accent)
            Text(L("Nobody has spoken yet"))
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Theme.text(scheme))
            if !hideHints {
                Text(L("This is a shared room: everyone near you over Bluetooth sees it. Say something."))
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.muted(scheme))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 44)
            }
            Spacer()
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func row(_ m: ChatMessage) -> some View {
        VStack(alignment: m.mine ? .trailing : .leading, spacing: 2) {
            if !m.mine {
                Button {
                    let tag = "@" + nickOf(m) + " "
                    if !draft.contains(tag) { draft += tag }
                } label: {
                    Text(nickOf(m))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                }
                .buttonStyle(.plain)
            }
            if let rid = m.replyTo,
               let orig = ble.roomMessages.first(where: { $0.wireID == rid }) {
                HStack(spacing: 5) {
                    Rectangle().fill(Theme.accent).frame(width: 2, height: 14)
                    Text(snippet(orig))
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.muted(scheme))
                        .lineLimit(1)
                }
                .padding(.horizontal, 6)
            }
            Text(ChatView.linkified(m.text))
                .font(.system(size: 15))
                .foregroundStyle(m.mine ? .white : Theme.text(scheme))
                .tint(m.mine ? .white : Theme.accent)
                .padding(.vertical, 9)
                .padding(.horizontal, 13)
                .background(m.mine ? Theme.accent : Theme.surface(scheme))
                .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 15, style: .continuous)
                        .stroke(Theme.accent,
                                lineWidth: mentionsMe(m) ? 1.5 : 0))
            if let r = m.reaction {
                Text(r)
                    .font(.system(size: 13))
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(Theme.surface(scheme), in: Capsule())
                    .overlay(Capsule().stroke(Theme.line(scheme), lineWidth: 0.5))
                    .padding(m.mine ? .trailing : .leading, 6)
            }
        }
    }

    @ViewBuilder
    private func menu(_ m: ChatMessage) -> some View {
        Menu {
            ForEach(emojis, id: \.self) { e in
                Button(e) { ble.sendRoomReaction(m, m.reaction == e ? "" : e) }
            }
            if m.reaction != nil {
                Button(role: .destructive) {
                    ble.sendRoomReaction(m, "")
                } label: {
                    Label(L("Remove reaction"), systemImage: "xmark")
                }
            }
        } label: { Label(L("React"), systemImage: "face.smiling") }
        Button { replyingTo = m } label: {
            Label(L("Reply"), systemImage: "arrowshape.turn.up.left")
        }
        if !m.mine {
            Button {
                let tag = "@" + nickOf(m) + " "
                if !draft.contains(tag) { draft += tag }
            } label: {
                Label(L("Mention"), systemImage: "at")
            }
        }
    }
}
